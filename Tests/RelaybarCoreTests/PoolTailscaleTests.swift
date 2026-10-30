import Foundation
import Testing

@testable import RelaybarCore

final class Stages: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(PoolTailscaleStage, PoolStageState)] = []

    func add(_ stage: PoolTailscaleStage, _ state: PoolStageState) { lock.withLock { log.append((stage, state)) } }

    func last(_ stage: PoolTailscaleStage) -> PoolStageState? {
        lock.withLock { log.last { $0.0 == stage }?.1 }
    }
}

let signedPackage = """
    Package "Tailscale.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Notarization: trusted by the Apple notary service
       Signed with a trusted timestamp on: 2026-10-28 00:56:35 +0000
       Certificate Chain:
        1. Developer ID Installer: Tailscale Inc. (W5364U7YZB)
           Expires: 2028-12-12 15:02:21 +0000
           SHA256 Fingerprint:
               1E 77 DE 6F E4 7D 42 69 84 C5 AA 18 0D 58 1F 32 46 19 7F 73 C0 C7
               13 27 7B 84 40 08 B9 36 E0 93
           ------------------------------------------------------------------------
        2. Developer ID Certification Authority
           Expires: 2031-09-17 00:00:00 +0000
           ------------------------------------------------------------------------
        3. Apple Root CA
           Expires: 2035-02-09 21:40:36 +0000

    """

let signInOutput = "\nTo authenticate, visit:\n\n\thttps://login.tailscale.com/a/1a2b3c4d5e6f\n\n"

func tailscaleStatus(_ backend: String, own: [String] = ["100.64.0.2", "fd7a:115c:a1e0::1"], peers: [String] = []) -> String {
    let peerList = Dictionary(
        uniqueKeysWithValues: peers.enumerated().map { index, address in
            ("nodekey:\(index)", ["TailscaleIPs": [address, "fd7a:115c:a1e0::\(index + 9)"], "Online": true] as [String: Any])
        })
    let object: [String: Any] = [
        "Version": "1.90.0", "BackendState": backend, "TailscaleIPs": own, "Self": ["TailscaleIPs": own, "Online": true],
        "Peer": peerList,
    ]
    return String(decoding: json(object), as: UTF8.self)
}

struct PoolTailscaleTests {
    private let homeAddress = "100.64.0.7"
    private let oldDestination = "homebox"

    private func seeded(_ harness: Harness, tailscale: String? = nil) throws {
        var state = PoolState(ssh: oldDestination)
        state.tailscale = tailscale
        state.record(.tunnelAgent)
        try state.save(harness.paths)
        try PoolFile.write(
            Data(PoolTunnel.plist(paths: harness.paths, destination: oldDestination).utf8), to: harness.paths.agent(Pool.tunnelLabel))
    }

    private func homeReply(_ backend: String = "Running", address: String? = "100.64.0.7") -> String {
        "\(PoolTailscale.addressMark)\n\(address.map { $0 + "\n" } ?? "")\(PoolTailscale.statusMark)\n\(tailscaleStatus(backend))\n"
    }

    private struct World {
        var mac = tailscaleStatus("Running", peers: ["100.64.0.7"])
        var macInstalled = true
        var home: String?
        var probeWorks = true
        var tunnelAnswersOn = "sam@100.64.0.7"
        var signature = signedPackage
        var passwordNeeded = false
    }

    private func answer(_ harness: Harness, _ world: World) -> Flag {
        let tunnel = Flag()
        let paths = harness.paths
        harness.recorder.respond = { command in
            let text = remoteScript(command)
            switch command.executable {
            case PoolTailscale.macCLI:
                return world.macInstalled ? CommandResult(output: world.mac) : CommandResult(status: 127)
            case "/usr/sbin/pkgutil": return CommandResult(output: world.signature)
            case "/bin/launchctl":
                if command.arguments.first == "bootstrap" {
                    let plist = (try? String(contentsOf: paths.agent(Pool.tunnelLabel), encoding: .utf8)) ?? ""
                    tunnel.on = plist.contains("<string>\(world.tunnelAnswersOn)</string>")
                } else {
                    tunnel.on = false
                }
                return CommandResult()
            case "/usr/bin/ssh":
                if text.contains("command -v tailscale"), let home = world.home { return CommandResult(output: home) }
                if text.contains("id -un") { return CommandResult(output: "sam\n") }
                if command.arguments.last == "true" { return world.probeWorks ? CommandResult() : CommandResult(status: 255) }
                if text.contains("sudo -n"), world.passwordNeeded {
                    return CommandResult(status: 1, error: "sudo: a password is required\n")
                }
                if text.contains("tailscale up") { return CommandResult(output: signInOutput) }
                return CommandResult()
            default: return CommandResult()
            }
        }
        harness.http.handler = { request in
            request.url.path == "/v1/models" && tunnel.on ? HTTPResponse(status: 401) : nil
        }
        return tunnel
    }

    private func tailscale(_ harness: Harness, opened: Opened = Opened()) -> PoolTailscale {
        PoolTailscale(env: harness.env(openURL: { opened.urls.append($0) }), work: harness.home.root.appendingPathComponent("work"))
    }

    private func hooks(_ stages: Stages = Stages(), install: Flag = Flag(), password: String? = nil) -> PoolTailscaleHooks {
        PoolTailscaleHooks(
            install: { _ in
                install.on = true
                return true
            }, password: { _ in password }, report: { stages.add($0, $1) })
    }

    @Test func switchesWhenBothHaveIt() async throws {
        let harness = try Harness()
        try seeded(harness)
        _ = answer(harness, World(home: homeReply()))
        let outcome = await tailscale(harness).automaticSwitch()
        #expect(outcome == .switched("sam@\(homeAddress)"))
        let plist = try String(contentsOf: harness.paths.agent(Pool.tunnelLabel), encoding: .utf8)
        #expect(plist.contains("<string>sam@\(homeAddress)</string>"))
        #expect(!plist.contains("<string>\(oldDestination)</string>"))
        let state = try #require(PoolState.load(harness.paths))
        #expect(state.tailscale == "sam@\(homeAddress)")
        #expect(state.ssh == oldDestination)
        let probe = try #require(harness.recorder.commands.first { $0.arguments.last == "true" })
        #expect(probe.arguments.contains("ConnectTimeout=5") && probe.arguments.contains("BatchMode=yes"))
        #expect(harness.recorder.ran("/bin/launchctl", containing: "bootstrap gui/501 "))
        #expect(await tailscale(harness).automaticSwitch() == .notApplicable)
    }

    @Test func switchesOnlyWhenItAnswers() async throws {
        let harness = try Harness()
        try seeded(harness)
        let before = try Data(contentsOf: harness.paths.agent(Pool.tunnelLabel))
        _ = answer(harness, World(home: homeReply(), probeWorks: false))
        #expect(await tailscale(harness).automaticSwitch() == .stayed(.notAnswering))
        #expect(!harness.recorder.ran("/bin/launchctl", containing: "bootout"))
        #expect(try Data(contentsOf: harness.paths.agent(Pool.tunnelLabel)) == before)
        #expect(PoolState.load(harness.paths)?.tailscale == nil)

        var elsewhere = World(home: homeReply(), probeWorks: false)
        elsewhere.mac = tailscaleStatus("Running", peers: ["100.64.9.9"])
        _ = answer(harness, elsewhere)
        #expect(await tailscale(harness).automaticSwitch() == .stayed(.differentTailnet))

        _ = answer(harness, World(home: homeReply(), tunnelAnswersOn: "never"))
        #expect(await tailscale(harness).automaticSwitch() == .stayed(.notAnswering))
        #expect(try Data(contentsOf: harness.paths.agent(Pool.tunnelLabel)) == before)
        #expect(PoolState.load(harness.paths)?.tailscale == nil)
        #expect(PoolState.load(harness.paths)?.ssh == oldDestination)
    }

    @Test func leavesAnExistingSetupAlone() async throws {
        let harness = try Harness()
        try seeded(harness)
        _ = answer(harness, World(home: homeReply()))
        let stages = Stages()
        let outcome = try await tailscale(harness).setUp(host: oldDestination, hooks: hooks(stages))
        #expect(outcome == .switched("sam@\(homeAddress)"))
        let all = harness.recorder.commands.map { ($0.executable + " " + $0.arguments.joined(separator: " ")) }
        for banned in ["tailscale up", "install.sh", "sudo", "curl", "pkgutil", "installer"] {
            #expect(!all.contains { $0.contains(banned) }, "ran \(banned)")
        }
        #expect(PoolTailscaleStage.allCases.allSatisfy { stages.last($0) == .done })

        var stopped = World(home: homeReply("Stopped"))
        stopped.home = homeReply("Stopped", address: nil)
        _ = answer(harness, stopped)
        _ = try? await tailscale(harness).setUp(host: oldDestination, hooks: hooks())
        let scripts = harness.recorder.commands.map(remoteScript).filter { $0.contains("tailscale up") }
        #expect(!scripts.isEmpty)
        for script in scripts {
            for flag in ["--ssh", "--reset", "--exit-node", "--advertise", "--authkey", "--accept-routes", "--force"] {
                #expect(!script.contains(flag))
            }
        }
    }

    @Test func setsUpAnAddedComputer() async throws {
        let installed = Flag()
        let recorder = Recorder()
        let running = "RB-IP\n100.64.0.9\nRB-STATUS\n" + tailscaleStatus("Running") + "\n"
        recorder.respond = { command in
            guard remoteScript(command).hasPrefix("if ! command -v tailscale") else { return CommandResult() }
            return CommandResult(output: installed.on ? running : PoolTailscale.missing + "\n")
        }
        let computer = PoolTailscaleComputer(host: "linuxpc", run: recorder.runner, pause: { _ in })
        let opened = Opens()
        var ran: [String] = []
        let fresh = try await computer.bringUp(
            found: try computer.facts(),
            privileged: { command, _ in
                ran.append(command)
                if command.contains("tailscale up") {
                    installed.on = true
                    return signInOutput
                }
                return ""
            }, onLink: { opened.add($0) })
        #expect(fresh.address == "100.64.0.9" && fresh.installed)
        #expect(ran.first == "curl -fsSL 'https://tailscale.com/install.sh' | sh")
        #expect(ran.count == 2 && ran[1].contains("nohup tailscale up"))
        for flag in ["--ssh", "--reset", "--exit-node", "--advertise", "--authkey", "--accept-routes", "--force"] {
            #expect(!ran.joined().contains(flag))
        }
        #expect(opened.urls.map(\.absoluteString) == ["https://login.tailscale.com/a/1a2b3c4d5e6f"])

        var again: [String] = []
        let signedOut = try await computer.bringUp(
            found: PoolTailscaleHome(installed: true, running: false, address: nil),
            privileged: { command, _ in
                again.append(command)
                return signInOutput
            }, onLink: { _ in })
        #expect(again.count == 1 && again[0].contains("tailscale up") && !signedOut.installed)

        let there = Recorder()
        let host = FakeClientHost()
        there.respond = { command in
            remoteScript(command).hasPrefix("if ! command -v tailscale")
                ? CommandResult(output: running) : host.answer(command) ?? CommandResult()
        }
        let log = AddLog()
        _ = try await PoolJoin.linuxClient(
            host: "laptop", hub: "homebox", accessKey: String(repeating: "c3", count: 32), options: PoolAddOptions(tailscale: true),
            hooks: log.hooks, run: there.runner)
        #expect(log.last(.tailscale) == .done)
        #expect(!there.commands.contains { plainScript($0).hasPrefix("sudo") || plainScript($0).contains("tailscale up") })
        #expect(
            PoolTailscaleComputer(host: "x", run: there.runner, pause: { _ in }).user() == "sam")
    }

    @Test func startsAStoppedTailscaleServiceBeforeSigningIn() async throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let started = bin.appendingPathComponent("started").path
        let fakes = [
            "systemctl": "case \"$1\" in is-active) test -e '\(started)';; enable) touch '\(started)';; esac",
            "tailscale": """
            [ "$1" = up ] || exit 1
            if [ -e '\(started)' ]; then printf '\(signInOutput.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t"))'; sleep 5
            else echo "failed to connect to local tailscaled; it doesn't appear to be running (sudo systemctl start tailscaled ?)"; exit 1; fi
            """,
        ]
        for (name, body) in fakes {
            let file = bin.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let running = "RB-IP\n100.64.0.9\nRB-STATUS\n" + tailscaleStatus("Running") + "\n"
        let recorder = Recorder()
        recorder.respond = { _ in CommandResult(output: running) }
        let computer = PoolTailscaleComputer(host: "linuxpc", run: recorder.runner, pause: { _ in })
        let opened = Opens()
        let result = try await computer.bringUp(
            found: PoolTailscaleHome(installed: true, running: false, address: nil),
            privileged: { command, _ in
                let shell = Process()
                shell.executableURL = URL(fileURLWithPath: "/bin/sh")
                shell.arguments = ["-c", command]
                shell.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
                let out = Pipe()
                shell.standardOutput = out
                try shell.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                shell.waitUntilExit()
                return String(decoding: data, as: UTF8.self)
            }, onLink: { opened.add($0) })
        #expect(opened.urls.map(\.absoluteString) == ["https://login.tailscale.com/a/1a2b3c4d5e6f"])
        #expect(result.address == "100.64.0.9")
    }

    @Test func readsTheSignInLink() async throws {
        #expect(PoolTailscale.signInLink(in: signInOutput)?.absoluteString == "https://login.tailscale.com/a/1a2b3c4d5e6f")
        #expect(PoolTailscale.signInLink(in: "visit https://login.tailscale.com.evil.example/a/x now") == nil)
        #expect(PoolTailscale.signInLink(in: "https://evil.example/?u=https://login.tailscale.com/a/x") == nil)
        #expect(PoolTailscale.signInLink(in: "http://login.tailscale.com/a/x") == nil)
        #expect(PoolTailscale.signInLink(in: "Success.") == nil)

        let harness = try Harness()
        try seeded(harness)
        let tunnel = Flag()
        let polls = Flag()
        let paths = harness.paths
        harness.recorder.respond = { command in
            let text = remoteScript(command)
            switch command.executable {
            case PoolTailscale.macCLI: return CommandResult(output: tailscaleStatus("Running", peers: ["100.64.0.7"]))
            case "/bin/launchctl":
                let plist = (try? String(contentsOf: paths.agent(Pool.tunnelLabel), encoding: .utf8)) ?? ""
                tunnel.on = command.arguments.first == "bootstrap" && plist.contains("sam@100.64.0.7")
                return CommandResult()
            case "/usr/bin/ssh":
                if text.contains("command -v tailscale") {
                    return CommandResult(output: polls.on ? self.homeReply() : self.homeReply("NeedsLogin", address: nil))
                }
                if text.contains("id -un") { return CommandResult(output: "sam\n") }
                if text.contains("tailscale up") {
                    polls.on = true
                    return CommandResult(output: signInOutput)
                }
                return CommandResult()
            default: return CommandResult()
            }
        }
        harness.http.handler = { request in tunnel.on && request.url.path == "/v1/models" ? HTTPResponse(status: 401) : nil }
        let opened = Opened()
        let outcome = try await tailscale(harness, opened: opened).setUp(host: oldDestination, hooks: hooks())
        #expect(outcome == .switched("sam@\(homeAddress)"))
        #expect(opened.urls.map(\.absoluteString) == ["https://login.tailscale.com/a/1a2b3c4d5e6f"])
        let up = try #require(harness.recorder.commands.first { remoteScript($0).contains("tailscale up") })
        #expect(remoteScript(up).hasPrefix("sudo -n sh -c "))
        #expect(!up.arguments.joined(separator: " ").contains("authkey"))
    }

    @Test func asksForThePasswordOnStdinOnly() async throws {
        let harness = try Harness()
        try seeded(harness)
        var world = World(home: PoolTailscale.missing + "\n")
        world.passwordNeeded = true
        let tunnel = answer(harness, world)
        let respond = harness.recorder.respond
        let installed = Flag()
        harness.recorder.respond = { command in
            let text = remoteScript(command)
            if command.executable == "/usr/bin/ssh", text.contains("install.sh"), command.stdin != nil { installed.on = true }
            if command.executable == "/usr/bin/ssh", text.contains("command -v tailscale"), installed.on {
                return CommandResult(output: self.homeReply())
            }
            return respond(command)
        }
        _ = tunnel
        let outcome = try await tailscale(harness).setUp(host: oldDestination, hooks: hooks(password: "hunter2"))
        #expect(outcome == .switched("sam@\(homeAddress)"))
        let withPassword = harness.recorder.commands.filter { $0.stdin != nil }
        #expect(!withPassword.isEmpty)
        for command in withPassword {
            #expect(String(decoding: command.stdin ?? Data(), as: UTF8.self) == "hunter2\n")
            #expect(!(command.executable + command.arguments.joined()).contains("hunter2"))
            #expect(remoteScript(command).contains("sudo -S -p"))
        }
        harness.recorder.respond = { command in
            if command.executable == PoolTailscale.macCLI {
                return CommandResult(output: tailscaleStatus("Running", peers: [self.homeAddress]))
            }
            return command.executable == "/usr/bin/ssh" && remoteScript(command).contains("command -v tailscale")
                ? CommandResult(output: PoolTailscale.missing + "\n") : CommandResult(status: 1, error: "sudo: a password is required\n")
        }
        await #expect(throws: PoolTailscaleError.needsPassword) {
            _ = try await tailscale(harness).setUp(host: oldDestination, hooks: hooks(password: nil))
        }
    }

    @Test func checksTheInstallerSignature() async throws {
        #expect(PoolTailscale.installerIsTailscales(signedPackage))
        let other = signedPackage.replacingOccurrences(of: "W5364U7YZB", with: "A1B2C3D4E5")
        #expect(!PoolTailscale.installerIsTailscales(other))
        #expect(!PoolTailscale.installerIsTailscales("Package \"x.pkg\":\n   Status: no signature\n"))
        let named = "Package \"1. Developer ID Installer: Evil (W5364U7YZB)\":\n   Status: signed by a certificate untrusted by Apple\n"
        #expect(!PoolTailscale.installerIsTailscales(named))
        let adhoc = signedPackage.replacingOccurrences(
            of: "signed by a developer certificate issued by Apple", with: "signed by a certificate")
        #expect(!PoolTailscale.installerIsTailscales(adhoc))

        let harness = try Harness()
        try seeded(harness)
        var world = World(home: homeReply())
        world.macInstalled = false
        world.signature = other
        _ = answer(harness, world)
        let installed = Flag()
        await #expect(throws: PoolTailscaleError.notTailscales) {
            _ = try await tailscale(harness).setUp(host: oldDestination, hooks: hooks(install: installed))
        }
        #expect(!installed.on)
        let download = try #require(harness.recorder.commands.first { $0.executable == "/usr/bin/curl" })
        #expect(download.arguments.last == "https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg")
        #expect(download.arguments.contains("--proto") && download.arguments.contains("=https"))
        #expect(!FileManager.default.fileExists(atPath: harness.home.root.appendingPathComponent("work").path))

        let status = Flag()
        world.signature = signedPackage
        _ = answer(harness, world)
        let respond = harness.recorder.respond
        harness.recorder.respond = { command in
            if command.executable == PoolTailscale.macCLI, status.on {
                return CommandResult(output: tailscaleStatus("Running", peers: ["100.64.0.7"]))
            }
            return respond(command)
        }
        let opened = Opened()
        let packages = Opened()
        let working = PoolTailscaleHooks(
            install: { url in
                packages.urls.append(url)
                status.on = true
                return true
            }, password: { _ in nil }, report: { _, _ in })
        let outcome = try await tailscale(harness, opened: opened).setUp(host: oldDestination, hooks: working)
        #expect(outcome == .switched("sam@\(homeAddress)"))
        #expect(packages.urls.map(\.lastPathComponent) == ["Tailscale.pkg"])
        #expect(opened.urls.map(\.path) == [PoolTailscale.macApp])
        let script = PoolTailscale.installScript(package: URL(fileURLWithPath: "/tmp/a b/\"x\".pkg"))
        #expect(
            script
                == "do shell script \"/usr/sbin/installer -pkg \" & quoted form of \"/tmp/a b/\\\"x\\\".pkg\" & \" -target /\" with administrator privileges"
        )
        let command = PoolTailscale.installCommand(package: URL(fileURLWithPath: "/tmp/a b/\"x\".pkg"))
        #expect(command == Command("/usr/bin/osascript", ["-e", script], limit: 900))
    }

    @Test func automaticPathSkipsWhatItShouldNot() async throws {
        let harness = try Harness()
        try seeded(harness)
        var signedOut = World(home: homeReply())
        signedOut.mac = tailscaleStatus("NeedsLogin", own: [])
        _ = answer(harness, signedOut)
        #expect(await tailscale(harness).automaticSwitch() == .notApplicable)
        var none = World(home: homeReply())
        none.macInstalled = false
        _ = answer(harness, none)
        #expect(await tailscale(harness).automaticSwitch() == .notApplicable)
        _ = answer(harness, World(home: homeReply("NeedsLogin", address: nil)))
        #expect(await tailscale(harness).automaticSwitch() == .notApplicable)
        var typed = PoolState(ssh: "sam@\(homeAddress)")
        typed.record(.tunnelAgent)
        try typed.save(harness.paths)
        _ = answer(harness, World(home: homeReply()))
        #expect(await tailscale(harness).automaticSwitch() == .notApplicable)
        #expect(!harness.recorder.ran("/bin/launchctl", containing: "bootout"))
        let stages = Stages()
        try seeded(harness)
        _ = answer(harness, World(home: homeReply(), probeWorks: false))
        _ = try await tailscale(harness).setUp(host: oldDestination, hooks: hooks(stages))
        #expect(stages.last(.connection) == .problem("Did not answer"))
    }

    @Test func stopsWhenThePasswordPromptIsCancelled() async throws {
        let harness = try Harness()
        try seeded(harness)
        var world = World(home: homeReply())
        world.macInstalled = false
        _ = answer(harness, world)
        let declined = PoolTailscaleHooks(install: { _ in false }, password: { _ in nil }, report: { _, _ in })
        await #expect(throws: PoolTailscaleError.installDeclined) {
            _ = try await tailscale(harness).setUp(host: oldDestination, hooks: declined)
        }
        #expect(!harness.recorder.ran("/bin/launchctl", containing: "bootout"))
        #expect(PoolState.load(harness.paths)?.tailscale == nil)
    }

    @Test func readsTailscaleOutput() throws {
        let status = try #require(PoolTailscaleStatus.parse(tailscaleStatus("Running", peers: ["100.64.0.7"])))
        #expect(status.running && status.daemonUp)
        #expect(status.ipv4 == "100.64.0.2")
        #expect(status.peers.contains("100.64.0.7"))
        #expect(PoolTailscaleStatus.parse("failed to connect") == nil)
        #expect(PoolTailscaleStatus.parse(tailscaleStatus("NoState"))?.daemonUp == false)
        for yes in ["100.64.0.7", "sam@100.100.1.2", "box.tail1234.ts.net", "sam@fd7a:115c:a1e0::1"] {
            #expect(PoolTailscale.isTailscaleAddress(yes), "\(yes)")
        }
        for no in ["homebox", "192.168.1.5", "100.63.0.1", "100.128.0.1", "sam@example.com"] {
            #expect(!PoolTailscale.isTailscaleAddress(no), "\(no)")
        }
        var state = PoolState(ssh: "homebox")
        #expect(state.needsTailscale)
        state.tailscale = "sam@100.64.0.7"
        #expect(!state.needsTailscale)
        #expect(!PoolState().needsTailscale)
    }

    @Test func stopStillReachesTheHomeComputerOverTailscale() throws {
        let harness = try Harness()
        var state = PoolState(ssh: oldDestination)
        state.tailscale = "sam@\(homeAddress)"
        state.record(.remoteHelper)
        try state.save(harness.paths)
        harness.recorder.respond = { command in
            command.arguments.contains("sam@\(self.homeAddress)")
                ? CommandResult() : CommandResult(status: 255, error: "ssh: connect to host homebox timed out")
        }
        let report = PoolTeardown.run(harness.env())
        #expect(report.finished)
        let hosts = harness.recorder.commands.compactMap { $0.arguments.dropLast().last }
        #expect(hosts == ["sam@\(homeAddress)"])
    }
}
