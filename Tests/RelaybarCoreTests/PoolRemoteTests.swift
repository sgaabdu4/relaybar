import CryptoKit
import Foundation
import Testing

@testable import RelaybarCore

func remoteScript(_ command: Command) -> String {
    guard let last = command.arguments.last else { return "" }
    return last.hasPrefix("sh -c '") ? String(last.dropFirst(7).dropLast()) : last
}

struct PoolRemoteTests {
    private let secrets = PoolSecrets(accessKey: String(repeating: "a1", count: 32), managementSecret: String(repeating: "b2", count: 32))
    private let script = Data("#!/bin/sh\necho installer\n".utf8)

    private func remote(_ recorder: Recorder) -> PoolRemote { PoolRemote(host: "homebox", run: recorder.runner) }

    private func answering(_ recorder: Recorder, hash: String = "") {
        recorder.respond = { command in
            let text = remoteScript(command)
            if text.contains("printf %s \"$HOME\"") { return CommandResult(output: "/home/sam") }
            if text.contains("sha256sum") { return CommandResult(output: hash + "\n") }
            return CommandResult()
        }
    }

    @Test func aFreshComputerIsFree() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let local: CommandRunner = { command in
            PoolProcess.run(
                Command(
                    "/bin/sh", ["-c", (command.arguments.last ?? "").replacingOccurrences(of: ":8317/", with: ":9/")],
                    environment: ["HOME": home.path]))
        }
        #expect(try PoolRemote(host: "homebox", run: local).status() == .free)
    }

    @Test func checksTheDownload() throws {
        let recorder = Recorder()
        answering(recorder)
        try remote(recorder).install(secrets: secrets, script: script, progress: { _ in })
        let scripts = recorder.commands.map(remoteScript)
        let install = try #require(scripts.first { $0.contains(" install ") })
        #expect(
            install
                == "RELAYBAR_MAJOR=\"8\" sh \"$HOME/.local/share/relaybar/relaybar-helper.sh\" install \"$HOME/.local/share/relaybar-helper\""
        )
        let order = [
            "relaybar-helper.sh\"; chmod", "config.yaml", "join.json", "relaybar-helper.service", " install ",
            "enable --now relaybar-helper-update.timer",
        ]
        var cursor = scripts.startIndex
        for fragment in order {
            let found = try #require(scripts[cursor...].firstIndex { $0.contains(fragment) }, "missing step \(fragment)")
            cursor = found
        }
        let config = try #require(recorder.commands.first { remoteScript($0).contains("config.yaml") })
        let text = String(decoding: config.stdin ?? Data(), as: UTF8.self)
        #expect(text.contains("auth-dir: \"/home/sam/.local/share/relaybar-helper/auth\""))
        #expect(text.contains("host: \"127.0.0.1\""))
        #expect(remoteScript(config).hasPrefix("umask 077;"))
        let join = try #require(recorder.commands.first { remoteScript($0).contains("join.json") })
        let parsed = try #require(try JSONSerialization.jsonObject(with: join.stdin ?? Data()) as? [String: String])
        #expect(parsed == ["accessKey": secrets.accessKey, "managementSecret": secrets.managementSecret])
        recorder.respond = { command in
            let text = remoteScript(command)
            if text.contains("printf %s \"$HOME\"") { return CommandResult(output: "/home/sam") }
            if text.contains(" install ") { return CommandResult(status: 1, error: "failed: checksum mismatch for x.tar.gz\n") }
            return CommandResult()
        }
        #expect(throws: PoolInstallError.failed("checksum mismatch for x.tar.gz")) {
            try remote(recorder).install(secrets: secrets, script: script, progress: { _ in })
        }
    }

    @Test func refreshesTheUpdateScript() throws {
        let recorder = Recorder()
        let hash = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        answering(recorder, hash: hash)
        #expect(try !remote(recorder).refreshScript(script))
        #expect(!recorder.commands.contains { $0.stdin == script })
        answering(recorder, hash: "0000")
        #expect(try remote(recorder).refreshScript(script))
        let copy = try #require(recorder.commands.last)
        #expect(copy.stdin == script)
        #expect(remoteScript(copy).contains("chmod 700"))
        answering(recorder, hash: "")
        #expect(try remote(recorder).refreshScript(script))
    }

    @Test func writesTheSystemdUnits() {
        let unit = PoolRemote.helperUnit(dir: "/home/sam/.local/share/relaybar-helper")
        for line in [
            "NoNewPrivileges=yes", "PrivateTmp=yes", "ProtectSystem=strict", "ProtectHome=tmpfs",
            "InaccessiblePaths=/run/user", "RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK",
            "BindPaths=/home/sam/.local/share/relaybar-helper", "Restart=always",
            "ExecStart=/home/sam/.local/share/relaybar-helper/current/cli-proxy-api -config /home/sam/.local/share/relaybar-helper/config.yaml",
        ] {
            #expect(unit.contains(line))
        }
        #expect(PoolRemote.updateTimer.contains("OnCalendar=*-*-* 04:00:00"))
        #expect(PoolRemote.updateTimer.contains("Persistent=true"))
        #expect(PoolRemote.updateTimer.contains("RandomizedDelaySec=30m"))
        #expect(PoolRemote.updateUnit(script: "/s.sh", dir: "/d").contains("ExecStart=/bin/sh /s.sh update /d"))
    }

    @Test func keepsItOnAndAsksForAPasswordOnlyWhenNeeded() {
        let recorder = Recorder()
        #expect(remote(recorder).keepOn().sleep == .off)
        let first = remoteScript(recorder.commands[0])
        #expect(first.contains("loginctl enable-linger \"$u\" 2>/dev/null || sudo -n loginctl enable-linger \"$u\""))
        #expect(first.contains("sudo -n systemctl mask $todo"))
        recorder.respond = { _ in CommandResult(status: 1) }
        #expect(remote(recorder).keepOn().sleep == .needsPassword)
        recorder.respond = { _ in CommandResult() }
        #expect(remote(recorder).keepOn(password: "pw").sleep == .off)
        let command = recorder.commands.last
        #expect(command?.stdin == Data("pw\n".utf8))
        #expect(!(command?.arguments.joined(separator: " ").contains("pw") ?? true))
        recorder.respond = { _ in CommandResult(status: 1) }
        #expect(remote(recorder).keepOn(password: "bad").sleep == nil)
    }

    @Test func recordsOnlyWhatItChanged() {
        let recorder = Recorder()
        recorder.respond = { _ in CommandResult(output: "changed:linger\nchanged:sleep.target\nchanged:suspend.target\nother\n") }
        #expect(remote(recorder).keepOn().changes == PoolKeepOn(linger: true, masked: ["sleep.target", "suspend.target"]))
        recorder.respond = { _ in CommandResult(output: "") }
        #expect(remote(recorder).keepOn().changes.isEmpty)
        recorder.respond = { _ in CommandResult(status: 1, output: "changed:linger\n") }
        let partial = remote(recorder).keepOn()
        #expect(partial.sleep == .needsPassword)
        #expect(partial.changes == PoolKeepOn(linger: true))
        let probe = remoteScript(PoolRemote.restoreSleepCommand(host: "h", keep: PoolKeepOn(), password: nil))
        #expect(probe.hasSuffix("|| exit 7"))
    }

    @Test func spotsSomeoneElsesSetup() throws {
        let recorder = Recorder()
        for (answer, expected) in [
            ("ours\n", PoolRemoteStatus.relaybarHub), ("folder\n", .conflict(.foreignHelperFolder("homebox:.local/share/relaybar-helper"))),
            ("401", .conflict(.portInUse(8317))),
            ("200", .conflict(.portInUse(8317))), ("000", .free),
        ] as [(String, PoolRemoteStatus)] {
            recorder.respond = { _ in CommandResult(output: answer) }
            #expect(try remote(recorder).status() == expected)
        }
    }

    @Test func onlyClaimsAFolderNobodyHas() throws {
        let recorder = Recorder()
        recorder.respond = { _ in CommandResult(output: "claimed\n") }
        try remote(recorder).claim()
        #expect(remoteScript(recorder.commands[0]).contains("mkdir -m 700 \"$HOME/.local/share/relaybar-helper\""))
        recorder.respond = { _ in CommandResult(output: "exists\n") }
        #expect(throws: PoolSetupError.conflict(.foreignHelperFolder("homebox:.local/share/relaybar-helper"))) {
            try remote(recorder).claim()
        }
    }

    @Test func explainsRemoteFailures() {
        let recorder = Recorder()
        recorder.respond = { _ in CommandResult(status: 255, error: "Permission denied (publickey).") }
        #expect(throws: PoolSSHError.failed("SSH asked for a password. Add this Mac's SSH key to that computer, then click Try Again.")) {
            try remote(recorder).remoteHome()
        }
        recorder.respond = { _ in CommandResult(output: "relative") }
        #expect(throws: PoolSSHError.self) { try remote(recorder).remoteHome() }
        #expect(PoolSSHError.failed("x").errorDescription == "x")
    }
}

struct PoolJoinTests {
    private let secrets = PoolSecrets(accessKey: String(repeating: "c3", count: 32), managementSecret: String(repeating: "d4", count: 32))
    private var joinJSON: String { #"{"accessKey":"\#(secrets.accessKey)","managementSecret":"\#(secrets.managementSecret)"}"# }

    @Test func findsThePoolAndItsSSHName() async throws {
        let harness = try Harness()
        harness.recorder.respond = { command in
            command.arguments.contains("homebox") ? CommandResult(output: "pool\n") : CommandResult(status: 1)
        }
        let offers = await PoolJoin.findPools(hosts: ["laptop", "homebox", "-bad"], env: harness.env())
        #expect(offers == [PoolJoinOffer(host: "homebox")])
    }

    @Test func joinsByTypedAddress() async throws {
        let harness = try Harness()
        try harness.home.write(
            ".t3/userdata/settings.json", #"{"defaultModelSelection": {"instanceId": "codex", "model": "m"}, "providerInstances": {}}"#)
        let secrets = secrets
        let joinJSON = joinJSON
        let up = Flag()
        harness.recorder.respond = { command in
            if command.executable == "/usr/bin/ssh" { return CommandResult(output: joinJSON) }
            if command.arguments.first == "bootstrap" { up.on = true }
            return CommandResult()
        }
        harness.http.handler = { request in
            guard request.url.path == "/v1/models" else { return nil }
            guard up.on else { return nil }
            return HTTPResponse(status: request.headers["Authorization"] == "Bearer \(secrets.accessKey)" ? 200 : 401)
        }
        try await PoolSetup(env: harness.env()).join(host: "192.168.1.20")
        let state = try #require(PoolState.load(harness.paths))
        #expect(state.ssh == "192.168.1.20")
        #expect(state.joined)
        #expect(state.steps.contains(.tunnelAgent))
        #expect(state.steps.contains(.t3Entries))
        #expect(state.steps.contains(.t3UsageSource))
        let plist = try String(contentsOf: harness.paths.agent(Pool.tunnelLabel), encoding: .utf8)
        #expect(plist.contains("<string>192.168.1.20</string>"))
        let settings = try harness.home.json(".t3/userdata/settings.json")
        #expect((settings["providerInstances"] as? [String: Any])?.keys.sorted() == ["claudeAgent_all_accounts", "codex_all_accounts"])
        await #expect(throws: PoolInputError.startsWithDash) { try await PoolSetup(env: harness.env()).join(host: "-oBad") }
        up.on = true
        await #expect(throws: PoolSetupError.conflict(.portInUse(8317))) {
            try await PoolSetup(env: harness.env()).join(host: "192.168.1.20")
        }
    }

    @Test func refusesAHostThatIsNotAPool() async throws {
        let harness = try Harness()
        harness.recorder.respond = { _ in CommandResult(output: "not json") }
        await #expect(throws: PoolSSHError.self) { try await PoolSetup(env: harness.env()).join(host: "homebox") }
        harness.recorder.respond = { _ in CommandResult(output: #"{"accessKey":"zz","managementSecret":"zz"}"#) }
        await #expect(throws: PoolSSHError.self) { try await PoolSetup(env: harness.env()).join(host: "homebox") }
        harness.recorder.respond = { _ in CommandResult(status: 255, error: "Connection refused") }
        await #expect(throws: PoolSSHError.self) { try await PoolSetup(env: harness.env()).join(host: "homebox") }
        #expect(PoolState.load(harness.paths) == nil)
    }

    private func clientHost(
        _ recorder: Recorder, probe: String = "new:.claude-hub\nnew:.codex-hub\nnew:.config/relaybar\nlinger:off", tunnel: String = "up\n"
    ) {
        recorder.respond = { command in
            let text = remoteScript(command)
            if text.contains("printf %s \"$HOME\"") { return CommandResult(output: "/home/sam") }
            if text.contains("for d in") { return CommandResult(output: probe) }
            if text.contains("&& echo changed:linger") { return CommandResult(output: "changed:linger\n") }
            if text.contains("http_code") { return CommandResult(output: tunnel) }
            return CommandResult()
        }
    }

    @Test func linuxClientKeyFileIsPrivate() throws {
        let recorder = Recorder()
        clientHost(recorder)
        _ = try PoolJoin.linuxClient(host: "laptop", hub: "homebox", secrets: secrets, run: recorder.runner)
        let key = try #require(
            recorder.commands.first {
                remoteScript($0).contains("access-key\"") && $0.stdin != nil && remoteScript($0).contains("umask 077")
            })
        #expect(key.stdin == Data(secrets.accessKey.utf8))
        #expect(remoteScript(key).hasPrefix("umask 077;"))
        #expect(!key.arguments.joined(separator: " ").contains(secrets.accessKey))
        let config = try #require(recorder.commands.first { remoteScript($0).contains("config.toml") })
        let text = String(decoding: config.stdin ?? Data(), as: UTF8.self)
        #expect(text.contains("command = \"/bin/cat\""))
        #expect(text.contains("/home/sam/.config/relaybar/access-key"))
        #expect(!text.contains(secrets.accessKey))
        let launcher = try #require(recorder.commands.first { remoteScript($0).contains("claude-all") && $0.stdin != nil })
        #expect(String(decoding: launcher.stdin ?? Data(), as: UTF8.self).contains("cat \"$HOME/.config/relaybar/access-key\""))
    }

    @Test func linuxClientGetsATunnel() throws {
        let recorder = Recorder()
        clientHost(recorder)
        _ = try PoolJoin.linuxClient(host: "laptop", hub: "192.168.1.20", secrets: secrets, run: recorder.runner)
        let unit = try #require(recorder.commands.first { remoteScript($0).contains("relaybar-tunnel.service\"") && $0.stdin != nil })
        let text = String(decoding: unit.stdin ?? Data(), as: UTF8.self)
        #expect(text.contains("'-N' '-L' '127.0.0.1:8317:127.0.0.1:8317'"))
        #expect(text.contains("'192.168.1.20'"))
        #expect(recorder.commands.contains { remoteScript($0).contains("enable --now relaybar-tunnel.service") })
        #expect(throws: PoolInputError.startsWithDash) {
            _ = try PoolJoin.linuxClient(host: "laptop", hub: "-bad", secrets: secrets, run: recorder.runner)
        }
    }

    @Test func linuxClientIsUndone() async throws {
        let recorder = Recorder()
        clientHost(recorder, probe: "new:.codex-hub\nnew:.config/relaybar\nlinger:off")
        let client = try PoolJoin.linuxClient(host: "laptop", hub: "homebox", secrets: secrets, run: recorder.runner)
        #expect(client == PoolLinuxClient(host: "laptop", folders: [".codex-hub", ".config/relaybar"], linger: true))
        recorder.respond = { _ in CommandResult() }
        try PoolJoin.removeLinuxClient(client, run: recorder.runner)
        let undo = remoteScript(try #require(recorder.commands.last))
        #expect(undo.contains("systemctl --user disable --now relaybar-tunnel.service"))
        #expect(undo.contains("rm -f \"$HOME/.config/systemd/user/relaybar-tunnel.service\" \"$HOME/.config/relaybar/access-key\""))
        #expect(undo.contains("rmdir \"$HOME/.codex-hub\""))
        #expect(undo.contains("rmdir \"$HOME/.config/relaybar\""))
        #expect(!undo.contains("rmdir \"$HOME/.claude-hub\""))
        #expect(undo.contains("loginctl disable-linger"))
        clientHost(recorder, probe: "new:.claude-hub")
        let kept = try PoolJoin.linuxClient(host: "laptop", hub: "homebox", secrets: secrets, run: recorder.runner)
        #expect(kept == PoolLinuxClient(host: "laptop", folders: [".claude-hub"], linger: false))
        try PoolJoin.removeLinuxClient(kept, run: recorder.runner)
        #expect(!remoteScript(try #require(recorder.commands.last)).contains("disable-linger"))
        recorder.respond = { _ in CommandResult(status: 255, error: "Connection refused") }
        #expect(throws: PoolSSHError.self) { try PoolJoin.removeLinuxClient(kept, run: recorder.runner) }
    }

    @Test func linuxClientStopsWithTheHub() async throws {
        let harness = try Harness()
        let up = Flag()
        harness.recorder.respond = { command in
            let text = command.executable == "/usr/bin/ssh" ? remoteScript(command) : ""
            if text.contains("printf %s \"$HOME\"") { return CommandResult(output: "/home/sam") }
            if text.contains("join.json\" ]") { return CommandResult(output: "000") }
            if text.contains("mkdir -m 700") { return CommandResult(output: "claimed") }
            if text.contains("for d in") { return CommandResult(output: "new:.codex-hub\nlinger:off") }
            if text.contains("http_code") { return CommandResult(output: "up") }
            if text.contains("&& echo changed:linger") { return CommandResult(output: "changed:linger") }
            if command.executable == "/bin/launchctl", command.arguments.first == "bootstrap" { up.on = true }
            return CommandResult()
        }
        harness.http.handler = { request in
            guard request.url.path == "/v1/models", up.on else { return nil }
            return HTTPResponse(status: request.headers["Authorization"] == nil ? 401 : 200)
        }
        let setup = PoolSetup(env: harness.env())
        _ = try await setup.combineOnHome(host: "homebox")
        try setup.useOnLinux(host: "laptop")
        let state = try #require(PoolState.load(harness.paths))
        #expect(state.steps.contains(.linuxClient))
        #expect(state.linuxClients == [PoolLinuxClient(host: "laptop", folders: [".codex-hub"], linger: true)])
        let tunnel = try #require(
            harness.recorder.commands.first { remoteScript($0).contains("relaybar-tunnel.service\"") && $0.stdin != nil })
        #expect(String(decoding: tunnel.stdin ?? Data(), as: UTF8.self).contains("'homebox'"))
        let access = try #require(setup.accessKey())
        let keyWrites = harness.recorder.commands.filter { $0.stdin == Data(access.utf8) }
        #expect(keyWrites.count == 1)
        #expect(setup.stop().finished)
        let removal = harness.recorder.commands.filter { $0.arguments.contains("laptop") }.map(remoteScript)
        #expect(removal.contains { $0.contains("rmdir \"$HOME/.codex-hub\"") && $0.contains("disable-linger") })
        #expect(PoolState.load(harness.paths) == nil)
    }

    @Test func linuxClientRefusesWhatItCannotUndoOrReach() throws {
        let recorder = Recorder()
        clientHost(recorder, probe: "foreign:claude-all")
        #expect(throws: PoolFileError.notRelaybars("laptop:.local/bin/claude-all")) {
            _ = try PoolJoin.linuxClient(host: "laptop", hub: "homebox", secrets: secrets, run: recorder.runner)
        }
        #expect(!recorder.commands.contains { $0.stdin != nil })
        clientHost(recorder, tunnel: "down\n")
        #expect(throws: PoolSSHError.failed("laptop could not reach homebox. Add the SSH key of laptop to homebox, then try again.")) {
            _ = try PoolJoin.linuxClient(host: "laptop", hub: "homebox", secrets: secrets, run: recorder.runner)
        }
        #expect(remoteScript(try #require(recorder.commands.last)).contains("rmdir"))
    }
}

final class Flag: @unchecked Sendable {
    var on = false
}
