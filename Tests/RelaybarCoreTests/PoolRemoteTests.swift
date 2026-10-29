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
    let secrets = PoolSecrets(accessKey: String(repeating: "c3", count: 32), managementSecret: String(repeating: "d4", count: 32))
    private var joinJSON: String { #"{"accessKey":"\#(secrets.accessKey)","managementSecret":"\#(secrets.managementSecret)"}"# }

    @Test func findsThePoolAndItsSSHName() async throws {
        let harness = try Harness()
        harness.recorder.respond = { command in
            command.arguments.contains("homebox") ? CommandResult(output: "pool\n") : CommandResult(status: 1)
        }
        let offers = await PoolJoin.findPools(hosts: ["laptop", "homebox", "-bad"], env: harness.env())
        #expect(offers == [PoolJoinOffer(host: "homebox")])
    }

    @Test func neverProbesAHostThatIsNotAtHome() async throws {
        let harness = try Harness()
        harness.recorder.respond = { command in
            if command.arguments.first == "-G" {
                return CommandResult(
                    output: command.arguments.last == "faraway" ? "user sam\nhostname 203.0.113.9\n" : "hostname 192.168.1.20\n")
            }
            return CommandResult(output: "pool\n")
        }
        let offers = await PoolJoin.findPools(hosts: ["faraway", "homebox"], env: harness.env())
        #expect(offers == [PoolJoinOffer(host: "homebox")])
        let probed = harness.recorder.commands.filter { $0.arguments.first != "-G" }.map { $0.arguments.joined(separator: " ") }
        #expect(probed.count == 1)
        #expect(probed.allSatisfy { !$0.contains("faraway") })
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
        harness.http.handler = joinedHelper(up: up, secrets: secrets)
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

    @Test func aJoinedMacChecksTheHelperWithTheManagementSecret() async throws {
        let harness = try Harness()
        let secrets = secrets
        let joinJSON = joinJSON
        let up = Flag()
        harness.recorder.respond = { command in
            if command.executable == "/usr/bin/ssh" { return CommandResult(output: joinJSON) }
            if command.arguments.first == "bootstrap" { up.on = true }
            return CommandResult()
        }
        let honest = joinedHelper(up: up, secrets: secrets)
        harness.http.handler = { request in
            request.url.path == "/v8/management/credentials" ? HTTPResponse(status: 404) : honest(request)
        }
        await #expect(throws: PoolSetupError.helperNotConfirmed("homebox")) {
            try await PoolSetup(env: harness.env()).join(host: "homebox")
        }
        #expect(
            PoolSetupError.helperNotConfirmed("homebox").errorDescription?.contains("Something other than the helper from homebox answered")
                == true)
        #expect(PoolState.load(harness.paths) == nil)
        let call = try #require(harness.http.requests.first { $0.url.path == "/v8/management/credentials" })
        #expect(call.headers["Authorization"] == "Bearer \(secrets.managementSecret)")
    }

    @Test func refusesAPortSomethingElseHolds() async throws {
        let recorder = Recorder()
        clientHost(recorder, FakeClientHost(probe: FakeClientHost.probe + "\nport:busy"))
        let busy = await #expect(throws: PoolSetupError.self) { _ = try await add(recorder) }
        #expect(busy == .conflict(.portInUse(8317)))
        #expect(!recorder.commands.contains { $0.stdin != nil })
        let probe = try #require(onLaptop(recorder).map(plainScript).first { $0.contains("for d in") })
        #expect(probe.contains("curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8317/v1/models"))
        #expect(probe.contains("systemctl --user is-active --quiet relaybar-tunnel.service"))
        #expect(probe.contains("grep -q relaybar/hub_key \"$HOME/.config/systemd/user/relaybar-tunnel.service\""))
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

    func clientHost(_ recorder: Recorder, _ host: FakeClientHost = FakeClientHost()) {
        recorder.respond = { host.answer($0) ?? CommandResult() }
    }

    func onHub(_ recorder: Recorder) -> [Command] {
        recorder.commands.filter { $0.arguments.contains("homebox") }
    }

    func onLaptop(_ recorder: Recorder) -> [Command] {
        recorder.commands.filter { $0.arguments.contains("laptop") }
    }

    func add(_ recorder: Recorder, hub: String = "homebox", options: PoolAddOptions = PoolAddOptions(), hooks: PoolAddHooks = .none)
        async throws -> PoolLinuxClient
    {
        try await PoolJoin.linuxClient(
            host: "laptop", hub: hub, accessKey: secrets.accessKey, options: options, hooks: hooks, run: recorder.runner
        ).client
    }

    @Test func linuxClientKeyFileIsPrivate() async throws {
        let recorder = Recorder()
        clientHost(recorder)
        _ = try await add(recorder)
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

    @Test func linuxClientGetsATunnel() async throws {
        let recorder = Recorder()
        clientHost(recorder)
        _ = try await add(recorder)
        let unit = try #require(recorder.commands.first { remoteScript($0).contains("relaybar-tunnel.service\"") && $0.stdin != nil })
        let text = String(decoding: unit.stdin ?? Data(), as: UTF8.self)
        #expect(
            text.contains(
                "for a in \"100.64.0.7\" \"192.168.1.20\" \"172.17.0.1\"; do \"/usr/bin/ssh\" \"-N\" \"-L\" \"127.0.0.1:8317:127.0.0.1:8317\""
            ))
        #expect(
            text.contains(
                "\"-i\" \"/home/sam/.config/relaybar/hub_key\" \"-o\" \"IdentitiesOnly=yes\" \"-o\" \"UserKnownHostsFile=/home/sam/.config/relaybar/known_hosts\" \"-o\" \"StrictHostKeyChecking=yes\" \"-p\" \"22\" \"-o\" \"ConnectTimeout=10\" \"--\" \"sam@$$a\""
            ))
        #expect(
            recorder.commands.contains {
                remoteScript($0).contains("enable relaybar-tunnel.service && systemctl --user restart relaybar-tunnel.service")
            })
        let wait = try #require(onLaptop(recorder).map(plainScript).first { $0.contains("sleep 1; i=") })
        #expect(wait.contains("cat \"$HOME/.config/relaybar/access-key\""))
        #expect(wait.contains("-K - http://127.0.0.1:8317/v1/models"))
        #expect(wait.contains("[ \"$c\" = 200 ] && systemctl --user is-active --quiet relaybar-tunnel.service"))
        #expect(!wait.contains(secrets.accessKey))
        await #expect(throws: PoolInputError.startsWithDash) { _ = try await add(recorder, hub: "-bad") }
    }

    @Test func clientKeyOnlyForwardsTheHelperPort() async throws {
        let recorder = Recorder()
        clientHost(recorder, FakeClientHost(hubAdds: "created:ssh\ncreated:keys\n"))
        let client = try await add(recorder)
        let adding = try #require(onHub(recorder).first { remoteScript($0).contains("cat >> ") })
        let line = String(decoding: adding.stdin ?? Data(), as: UTF8.self)
        #expect(
            line
                == "restrict,port-forwarding,permitopen=\"127.0.0.1:8317\",permitlisten=\"127.0.0.1:1\",command=\"/bin/false\" ssh-ed25519 AAAAclientkey relaybar-client:laptop\n"
        )
        let script = plainScript(adding)
        #expect(script.contains("mkdir -m 700"))
        #expect(script.contains("chmod 600"))
        let backup = try #require(script.range(of: "cp -p \"$f\" \"$f.relaybar-backup\""))
        #expect(script.contains("[ -e \"$f.relaybar-backup\" ] ||"))
        let drop = try #require(script.range(of: "awk -v t=' relaybar-client:laptop'"))
        #expect(backup.lowerBound < drop.lowerBound)
        #expect(client.hubKey)
        #expect(client.hubCreated == ["ssh", "keys"])
        let keygen = try #require(onLaptop(recorder).map(plainScript).first { $0.contains("ssh-keygen -q") })
        #expect(keygen.contains("-N ''"))
        #expect(keygen.contains("hub_key"))
        #expect(keygen.contains("rm -f \"$HOME/.config/relaybar/hub_key\""))
        #expect(!onLaptop(recorder).contains { remoteScript($0).contains("authorized_keys") || remoteScript($0).contains("id_ed25519") })
        recorder.respond = { _ in CommandResult() }
        let before = recorder.commands.count
        try PoolJoin.removeLinuxClient(client, hubRoutes: ["homebox"], run: recorder.runner)
        let removal = plainScript(try #require(recorder.commands.dropFirst(before).first { $0.arguments.contains("homebox") }))
        #expect(
            removal.contains(
                "awk -v t=' relaybar-client:laptop' '{ n = length($0); m = length(t); if (n >= m && substr($0, n - m + 1) == t) next; print }'"
            ))
        #expect(removal.contains("[ -s \"$f\" ] || rm -f \"$f\""))
        #expect(removal.contains("rmdir \"$d\""))
        let kept = PoolLinuxClient(host: "laptop")
        var tagged = kept
        tagged.hubKey = true
        try PoolJoin.removeLinuxClient(tagged, hubRoutes: ["homebox"], run: recorder.runner)
        let second = plainScript(try #require(recorder.commands.last { $0.arguments.contains("homebox") }))
        #expect(!second.contains("rm -f \"$f\""))
        #expect(!second.contains("rmdir"))
    }

    @Test func pinsTheHubHostKey() async throws {
        let recorder = Recorder()
        clientHost(recorder)
        _ = try await add(recorder)
        let readKey = try #require(onHub(recorder).first { remoteScript($0).contains("ssh_host_ed25519_key.pub") })
        #expect(remoteScript(readKey).contains("ssh_host_*_key.pub"))
        let pinned = try #require(
            onLaptop(recorder).first { remoteScript($0).contains("known_hosts\"") && $0.stdin != nil })
        #expect(remoteScript(pinned).hasPrefix("umask 077;"))
        #expect(
            String(decoding: pinned.stdin ?? Data(), as: UTF8.self)
                == "192.168.1.20 ssh-ed25519 AAAAhubkey\n172.17.0.1 ssh-ed25519 AAAAhubkey\n100.64.0.7 ssh-ed25519 AAAAhubkey\n")
        #expect(!recorder.commands.contains { $0.arguments.joined(separator: " ").contains("ssh-keyscan") })
        let odd = Recorder()
        clientHost(odd, FakeClientHost(facts: FakeClientHost.hubFacts.replacingOccurrences(of: "port=22", with: "port=2222")))
        _ = try await add(odd)
        let other = try #require(onLaptop(odd).first { remoteScript($0).contains("known_hosts\"") && $0.stdin != nil })
        #expect(String(decoding: other.stdin ?? Data(), as: UTF8.self).hasPrefix("[192.168.1.20]:2222 ssh-ed25519 AAAAhubkey\n"))
        let unit = try #require(odd.commands.first { remoteScript($0).contains("relaybar-tunnel.service\"") && $0.stdin != nil })
        #expect(String(decoding: unit.stdin ?? Data(), as: UTF8.self).contains("\"-p\" \"2222\""))
        clientHost(odd, FakeClientHost(facts: "user=sam\nport=22\naddr=192.168.1.20\n"))
        await #expect(throws: PoolClientError.hubIdentity("homebox")) { _ = try await add(odd) }
        #expect(PoolClientError.hubIdentity("homebox").errorDescription?.contains("SSH identity of homebox") == true)
    }

    @Test func triesEachHubAddress() async throws {
        let recorder = Recorder()
        clientHost(recorder, FakeClientHost(route: "ok:172.17.0.1\n"))
        _ = try await add(recorder)
        let tries = try #require(onLaptop(recorder).map(plainScript).first { $0.contains("echo ok:$a") })
        #expect(tries.hasPrefix("e=''; p=''; for a in 192.168.1.20 172.17.0.1 100.64.0.7; do e=$(ssh "))
        for option in [
            "'-i' '/home/sam/.config/relaybar/hub_key'", "'IdentitiesOnly=yes'",
            "'UserKnownHostsFile=/home/sam/.config/relaybar/known_hosts'",
            "'StrictHostKeyChecking=yes'", "'-p' '22'", "-o BatchMode=yes", "-o ConnectTimeout=5", "\"sam@$a\" true",
            "[ $r -eq 1 ]",
        ] {
            #expect(tries.contains(option), "missing \(option)")
        }
        let unit = try #require(recorder.commands.first { remoteScript($0).contains("relaybar-tunnel.service\"") && $0.stdin != nil })
        #expect(String(decoding: unit.stdin ?? Data(), as: UTF8.self).contains("for a in \"100.64.0.7\" \"172.17.0.1\" \"192.168.1.20\";"))
        clientHost(recorder, FakeClientHost(route: "none\n"))
        let before = recorder.commands.count
        let failure = await #expect(throws: PoolClientError.self) { _ = try await add(recorder) }
        #expect(tries.contains("*'Permission denied'*) p=$e;;"))
        #expect(!tries.contains("-ne 255"))
        #expect(failure == .noRoute(host: "laptop", tried: ["192.168.1.20", "172.17.0.1", "100.64.0.7"], reason: nil))
        let message = failure?.errorDescription ?? ""
        #expect(message.contains("192.168.1.20, 172.17.0.1, 100.64.0.7"))
        #expect(message.contains("Put both computers on the same network or on Tailscale, then try again."))
        let after = Array(recorder.commands.dropFirst(before))
        #expect(after.filter { $0.arguments.contains("homebox") && remoteScript($0).contains("authorized_keys") }.count == 2)
        #expect(plainScript(try #require(after.last)).contains("systemctl --user disable --now relaybar-tunnel.service"))
        let facts = try #require(
            PoolHubFacts.parse(
                "user=sam\nport=22\naddr=100.64.0.7\naddr=10.0.0.5\nts=100.64.0.7\naddr=8.8.8.8\naddr=bad\nhostkey=ssh-ed25519 AAAA\n"))
        #expect(facts.addresses == ["10.0.0.5", "100.64.0.7"])
        #expect(PoolHubFacts.parse("user=-bad\nhostkey=ssh-ed25519 AAAA\n") == nil)
        #expect(PoolHubFacts.parse("user=sam\nhostkey=not a key\n") == nil)
        #expect(PoolClientError.noRoute(host: "laptop", tried: [], reason: nil).errorDescription?.contains("gave no home address") == true)
    }

    @Test func explainsWhyNoAddressWorked() async throws {
        let recorder = Recorder()
        let denied = "err:sam@192.168.1.20: Permission denied (publickey)."
        clientHost(recorder, FakeClientHost(route: "none\n" + denied + "\n"))
        let refused = await #expect(throws: PoolClientError.self) { _ = try await add(recorder) }
        let reason = try #require(refused?.errorDescription)
        #expect(reason.contains("homebox refused the key of laptop. Check that SSH on homebox reads ~/.ssh/authorized_keys"))
        #expect(!reason.contains("Put both computers on the same network"))
        #expect(!reason.hasPrefix(PoolHubPicker.keyProblem))
        #expect(refused?.offersRetry == true)
        clientHost(recorder, FakeClientHost(route: "none\nerr:ssh: connect to host 100.64.0.7 port 22: Connection timed out\n"))
        let timedOut = await #expect(throws: PoolClientError.self) { _ = try await add(recorder) }
        #expect(timedOut?.errorDescription?.contains("homebox did not answer. Check that it is on and on the same network") == true)
        #expect(PoolClientError.mac("laptop").offersRetry == false)
    }

    @Test func saysWhyAComputerCannotBeAdded() async throws {
        let harness = try Harness()
        let setup = PoolSetup(env: harness.env())
        await #expect(throws: PoolSetupError.notCombining) { _ = try await setup.useOnLinux(host: "laptop") }
        try PoolState().save(harness.paths)
        await #expect(throws: PoolSetupError.hubIsThisMac) { _ = try await setup.useOnLinux(host: "laptop") }
        try PoolState(ssh: "homebox").save(harness.paths)
        await #expect(throws: PoolSetupError.accessKeyMissing) { _ = try await setup.useOnLinux(host: "laptop") }
        #expect(harness.recorder.commands.allSatisfy { $0.executable != "/usr/bin/ssh" })
        let said = [PoolSetupError.notCombining, .hubIsThisMac, .accessKeyMissing].compactMap(\.errorDescription)
        #expect(said.count == 3)
        #expect(Set(said).count == 3)
        #expect(said.allSatisfy { $0 != PoolSetupError.notAnswering.errorDescription })
        #expect(said[2].contains("access key from the Keychain"))
    }

    @Test func namesAMissingTool() async throws {
        let recorder = Recorder()
        clientHost(recorder, FakeClientHost(probe: FakeClientHost.probe + "\nmissing:curl\nmissing:systemctl"))
        let missing = await #expect(throws: PoolClientError.self) { _ = try await add(recorder) }
        #expect(missing == .missingTool(host: "laptop", tool: "curl"))
        #expect(missing?.errorDescription == "laptop needs curl. Install it, then try again.")
        #expect(!recorder.commands.contains { $0.stdin != nil })
        let probe = try #require(onLaptop(recorder).map(plainScript).first { $0.contains("for d in") })
        #expect(probe.contains("for t in curl ssh ssh-keygen systemctl; do command -v \"$t\" >/dev/null 2>&1 || echo missing:$t; done"))
    }

    @Test func usesTheSSHProgramTheComputerHas() async throws {
        let recorder = Recorder()
        clientHost(recorder, FakeClientHost(probe: FakeClientHost.probe + "\nssh:/opt/openssh/bin/ssh"))
        _ = try await add(recorder)
        let unit = try #require(recorder.commands.first { remoteScript($0).contains("relaybar-tunnel.service\"") && $0.stdin != nil })
        #expect(String(decoding: unit.stdin ?? Data(), as: UTF8.self).contains("do \"/opt/openssh/bin/ssh\" \"-N\""))
        clientHost(recorder, FakeClientHost(probe: FakeClientHost.probe + "\nssh:"))
        _ = try await add(recorder)
        let fallback = try #require(recorder.commands.last { remoteScript($0).contains("relaybar-tunnel.service\"") && $0.stdin != nil })
        #expect(String(decoding: fallback.stdin ?? Data(), as: UTF8.self).contains("do \"/usr/bin/ssh\" \"-N\""))
    }

    @Test func refusesAComputerAnotherMacAlreadySetUp() async throws {
        let recorder = Recorder()
        clientHost(recorder, FakeClientHost(probe: FakeClientHost.probe + "\nkey:yes"))
        let used = await #expect(throws: PoolClientError.self) { _ = try await add(recorder) }
        #expect(used == .alreadyUsed("laptop"))
        #expect(
            used?.errorDescription
                == "laptop already uses your accounts, set up from another Mac or under another name. Remove it there first.")
        #expect(!recorder.commands.contains { $0.stdin != nil })
        let probe = try #require(onLaptop(recorder).map(plainScript).first { $0.contains("for d in") })
        #expect(probe.contains("test -e \"$HOME/.config/relaybar/hub_key\" && echo key:yes"))
    }

    @Test func neverWritesThroughALinkedKeyFileOnTheHub() async throws {
        let recorder = Recorder()
        clientHost(recorder, FakeClientHost(hubAdds: "link\n"))
        await #expect(throws: PoolFileError.link("homebox:.ssh/authorized_keys")) { _ = try await add(recorder) }
        let adding = try #require(onHub(recorder).map(plainScript).first { $0.contains("cat >> ") })
        let guardAt = try #require(adding.range(of: "if [ -L \"$f\" ]; then echo link; exit 0; fi;"))
        #expect(guardAt.lowerBound < (try #require(adding.range(of: "mkdir -m 700"))).lowerBound)
        #expect(guardAt.lowerBound < (try #require(adding.range(of: "cp -p"))).lowerBound)
        let removal = try #require(onHub(recorder).map(plainScript).last { $0.contains("rmdir") || $0.contains("mktemp") })
        #expect(removal.contains("if [ -e \"$f\" ] && [ ! -L \"$f\" ]; then"))
    }

    @Test func tellsAComputerThatIsNotLinuxFromAnSSHFailure() async throws {
        let recorder = Recorder()
        let windows = FakeClientHost(
            system: "", systemStatus: 1, systemError: "'sh' is not recognized as an internal or external command")
        clientHost(recorder, windows)
        let other = await #expect(throws: PoolClientError.self) { _ = try await add(recorder) }
        #expect(other == .notLinux("laptop"))
        clientHost(recorder, FakeClientHost(system: "", systemStatus: 127))
        await #expect(throws: PoolClientError.notLinux("laptop")) { _ = try await add(recorder) }
        clientHost(recorder, FakeClientHost(system: "", systemStatus: 255, systemError: "Connection refused"))
        await #expect(throws: PoolSSHError.self) { _ = try await add(recorder) }
        clientHost(recorder, FakeClientHost(system: "", systemStatus: CommandResult.timedOut, systemError: "timed out"))
        await #expect(throws: PoolSSHError.self) { _ = try await add(recorder) }
        #expect(!recorder.commands.contains { $0.stdin != nil })
    }

    let t3File = #"{"defaultModelSelection": {"instanceId": "claudeAgent", "model": "m"}, "providerInstances": {}}"#

    @Test func clientGetsT3Entries() async throws {
        let recorder = Recorder()
        var host = FakeClientHost(probe: FakeClientHost.probe + "\nt3:yes\nt3secrets:new", settings: t3File)
        clientHost(recorder, host)
        let client = try await add(recorder)
        let settingsPush = try #require(onLaptop(recorder).last { remoteScript($0).contains("relaybar-new") })
        let pushScript = plainScript(settingsPush)
        let backup = try #require(pushScript.range(of: "[ -e \"$f.relaybar-backup\" ] || cp -p \"$f\" \"$f.relaybar-backup\""))
        #expect(pushScript.hasPrefix("f=\"$HOME/.t3/userdata/settings.json\";"))
        let move = try #require(pushScript.range(of: "mv "))
        #expect(backup.lowerBound < move.lowerBound)
        let pushed = try #require(try JSONSerialization.jsonObject(with: settingsPush.stdin ?? Data()) as? [String: Any])
        let instances = try #require(pushed["providerInstances"] as? [String: [String: Any]])
        #expect(instances.keys.sorted() == ["claudeAgent_all_accounts", "codex_all_accounts"])
        #expect((instances["claudeAgent_all_accounts"]?["config"] as? [String: String])?["homePath"] == "/home/sam/.claude-hub")
        #expect((instances["codex_all_accounts"]?["config"] as? [String: String])?["homePath"] == "/home/sam/.codex-hub")
        #expect((pushed["defaultModelSelection"] as? [String: String])?["instanceId"] == "claudeAgent_all_accounts")
        #expect(pushed["usageLimitSources"] == nil)
        let secretWrite = try #require(onLaptop(recorder).first { remoteScript($0).contains("userdata/secrets/provider-env-") })
        #expect(secretWrite.stdin == Data(secrets.accessKey.utf8))
        #expect(remoteScript(secretWrite).hasPrefix("umask 077; mkdir -p"))
        #expect(!recorder.commands.contains { $0.stdin == Data(secrets.managementSecret.utf8) })
        #expect(client.t3Entries)
        #expect(client.t3DefaultSet)
        #expect(client.previousSelection?.contains("claudeAgent") == true)
        #expect(client.t3Secrets.count == 1)
        #expect(client.t3SecretsFolder)
        host.settings = String(decoding: settingsPush.stdin ?? Data(), as: UTF8.self)
        clientHost(recorder, host)
        let before = recorder.commands.count
        try PoolJoin.removeLinuxClient(client, hubRoutes: ["homebox"], run: recorder.runner)
        let undo = Array(recorder.commands.dropFirst(before)).filter { $0.arguments.contains("laptop") }
        let restore = try #require(undo.first { remoteScript($0).contains("relaybar-new") })
        let restored = try #require(try JSONSerialization.jsonObject(with: restore.stdin ?? Data()) as? [String: Any])
        #expect((restored["providerInstances"] as? [String: Any])?.isEmpty == true)
        #expect((restored["defaultModelSelection"] as? [String: String]) == ["instanceId": "claudeAgent", "model": "m"])
        let cleanup = try #require(undo.map(plainScript).first { $0.contains("userdata/secrets/provider-env-") })
        #expect(cleanup.contains("rm -f \"$HOME/.t3/userdata/secrets/\(client.t3Secrets[0]).bin\""))
        #expect(cleanup.contains("rmdir \"$HOME/.t3/userdata/secrets\""))
        let plain = Recorder()
        clientHost(plain)
        _ = try await add(plain)
        #expect(!plain.commands.contains { remoteScript($0).contains("relaybar-new") || remoteScript($0).contains("userdata/secrets/") })
        let bad = Recorder()
        clientHost(bad, FakeClientHost(probe: FakeClientHost.probe + "\nt3:yes", settings: "not json"))
        await #expect(throws: PoolClientError.t3Unreadable("laptop")) { _ = try await add(bad) }
        #expect(!bad.commands.contains { $0.stdin != nil || remoteScript($0).contains("ssh-keygen -q") })
    }

    @Test func onlyLinuxIsAdded() async throws {
        let recorder = Recorder()
        clientHost(recorder, FakeClientHost(system: "Darwin\n"))
        let mac = await #expect(throws: PoolClientError.self) { _ = try await add(recorder) }
        #expect(mac == .mac("laptop"))
        #expect(mac?.errorDescription == "laptop is a Mac. Open Relaybar on that Mac. It finds your accounts and connects in one click.")
        clientHost(recorder, FakeClientHost(system: "FreeBSD\n"))
        let other = await #expect(throws: PoolClientError.self) { _ = try await add(recorder) }
        #expect(other?.errorDescription == "laptop is not a Linux computer. Relaybar can add Linux computers only for now.")
        #expect(recorder.commands.count == 2)
        #expect(!recorder.commands.contains { $0.stdin != nil })
        clientHost(recorder, FakeClientHost(probe: FakeClientHost.probe + "\nhub:yes"))
        let same = await #expect(throws: PoolClientError.self) { _ = try await add(recorder) }
        #expect(same == .isTheHub("laptop"))
        #expect(!recorder.commands.dropFirst(2).contains { $0.stdin != nil })
    }

    @Test func linuxClientIsUndone() async throws {
        let recorder = Recorder()
        clientHost(
            recorder,
            FakeClientHost(probe: "new:.codex-hub\nnew:.config/relaybar\nlinger:off", hubAdds: "created:ssh\ncreated:keys\n"))
        let client = try await add(recorder)
        var expected = PoolLinuxClient(host: "laptop", folders: [".codex-hub", ".config/relaybar"], linger: true)
        expected.hubKey = true
        expected.hubCreated = ["ssh", "keys"]
        #expect(client == expected)
        recorder.respond = { _ in CommandResult() }
        let before = recorder.commands.count
        try PoolJoin.removeLinuxClient(client, hubRoutes: ["homebox"], run: recorder.runner)
        let sent = Array(recorder.commands.dropFirst(before))
        #expect(sent.first?.arguments.contains("homebox") == true)
        let undo = remoteScript(try #require(sent.last))
        #expect(undo.contains("systemctl --user disable --now relaybar-tunnel.service"))
        #expect(undo.contains("rm -f \"$HOME/.config/systemd/user/relaybar-tunnel.service\" \"$HOME/.config/relaybar/access-key\""))
        for file in ["hub_key", "hub_key.pub", "known_hosts"] {
            #expect(undo.contains("\"$HOME/.config/relaybar/\(file)\""))
        }
        #expect(undo.contains("rm -f \"$p\""))
        #expect(undo.contains("rmdir \"$HOME/.codex-hub\""))
        #expect(undo.contains("rmdir \"$HOME/.config/relaybar\""))
        #expect(!undo.contains("rmdir \"$HOME/.claude-hub\""))
        #expect(undo.contains("loginctl disable-linger"))
        clientHost(recorder, FakeClientHost(probe: "new:.claude-hub"))
        let kept = try await add(recorder)
        var plain = PoolLinuxClient(host: "laptop", folders: [".claude-hub"], linger: false)
        plain.hubKey = true
        #expect(kept == plain)
        try PoolJoin.removeLinuxClient(kept, hubRoutes: ["homebox"], run: recorder.runner)
        #expect(!remoteScript(try #require(recorder.commands.last)).contains("disable-linger"))
        recorder.respond = { command in
            command.arguments.contains("homebox") ? CommandResult(status: 255, error: "Connection refused") : CommandResult()
        }
        let seen = recorder.commands.count
        let hubDown = try PoolJoin.removeLinuxClient(kept, hubRoutes: ["homebox"], run: recorder.runner)
        #expect(hubDown.hubKeyProblem?.contains("refused the connection") == true)
        #expect(recorder.commands.dropFirst(seen).contains { $0.arguments.contains("laptop") })
        recorder.respond = { _ in CommandResult(status: 255, error: "Connection refused") }
        #expect(throws: PoolSSHError.self) { try PoolJoin.removeLinuxClient(PoolLinuxClient(host: "laptop"), run: recorder.runner) }
        #expect(throws: PoolSSHError.self) { try PoolJoin.removeLinuxClient(plain, run: recorder.runner) }
        recorder.respond = { _ in CommandResult() }
        let noRoute = try PoolJoin.removeLinuxClient(plain, run: recorder.runner)
        #expect(noRoute.hubKeyProblem?.contains("does not know how to reach the home computer") == true)
    }

    @Test func linuxClientStopsWithTheHub() async throws {
        let harness = try Harness()
        harness.answerHomeAndComputers(FakeClientHost(probe: "new:.codex-hub\nlinger:off", hubAdds: "created:keys\n"))
        let setup = PoolSetup(env: harness.env())
        _ = try await setup.combineOnHome(host: "homebox")
        let added = try await setup.useOnLinux(host: "laptop")
        let state = try #require(PoolState.load(harness.paths))
        #expect(state.steps.contains(.linuxClient))
        #expect(state.linuxClients == [added.client])
        #expect(added.folders == [".codex-hub"])
        #expect(added.linger)
        #expect(added.hubKey)
        let tunnel = try #require(
            harness.recorder.commands.first { remoteScript($0).contains("relaybar-tunnel.service\"") && $0.stdin != nil })
        #expect(
            String(decoding: tunnel.stdin ?? Data(), as: UTF8.self).contains("for a in \"100.64.0.7\" \"192.168.1.20\" \"172.17.0.1\";"))
        let access = try #require(setup.accessKey())
        let keyWrites = harness.recorder.commands.filter { $0.stdin == Data(access.utf8) }
        #expect(keyWrites.count == 1)
        let again = try await setup.useOnLinux(host: "laptop")
        #expect(PoolState.load(harness.paths)?.linuxClients == [again.client])
        let mark = harness.recorder.commands.count
        #expect(setup.stop().finished)
        let sent = Array(harness.recorder.commands.dropFirst(mark)).filter { $0.executable == "/usr/bin/ssh" }.map(remoteScript)
        let laptop = try #require(sent.firstIndex { $0.contains("rmdir \"$HOME/.codex-hub\"") && $0.contains("disable-linger") })
        let key = try #require(sent.firstIndex { $0.contains("relaybar-client:laptop") })
        let helper = try #require(sent.firstIndex { $0.contains("rm -rf \"$HOME/.local/share/relaybar-helper\"") })
        #expect(key < laptop)
        #expect(laptop < helper)
        #expect(PoolState.load(harness.paths) == nil)
    }

    @Test func removesOneComputerAndKeepsTheRest() async throws {
        let harness = try Harness()
        harness.answerHomeAndComputers()
        let setup = PoolSetup(env: harness.env())
        _ = try await setup.combineOnHome(host: "homebox")
        try await setup.useOnLinux(host: "laptop")
        try await setup.useOnLinux(host: "desktop")
        try setup.removeComputer(host: "laptop")
        var state = try #require(PoolState.load(harness.paths))
        #expect(state.linuxClients.map(\.host) == ["desktop"])
        #expect(state.steps.contains(.linuxClient))
        try setup.removeComputer(host: "desktop")
        try setup.removeComputer(host: "nobody")
        state = try #require(PoolState.load(harness.paths))
        #expect(state.linuxClients.isEmpty)
        #expect(!state.steps.contains(.linuxClient))
    }

    @Test func linuxClientRefusesWhatItCannotUndoOrReach() async throws {
        let recorder = Recorder()
        clientHost(recorder, FakeClientHost(probe: "foreign:claude-all"))
        await #expect(throws: PoolFileError.notRelaybars("laptop:.local/bin/claude-all")) { _ = try await add(recorder) }
        #expect(!recorder.commands.contains { $0.stdin != nil })
        clientHost(recorder, FakeClientHost(tunnel: "down\n"))
        await #expect(
            throws: PoolSSHError.failed(
                "laptop reached homebox, but the helper did not answer there. Check that the helper is running, then try again.")
        ) { _ = try await add(recorder) }
        #expect(remoteScript(try #require(recorder.commands.last)).contains("rmdir"))
        recorder.respond = { command in
            plainScript(command).contains("ssh-keygen -q")
                ? CommandResult(output: "nokeygen\n") : FakeClientHost().answer(command) ?? CommandResult()
        }
        await #expect(throws: PoolClientError.noKeyTool("laptop")) { _ = try await add(recorder) }
        #expect(PoolClientError.noKeyTool("laptop").errorDescription?.contains("OpenSSH client") == true)
    }

    @Test func rollsBackAndRecordsEveryStep() async throws {
        let recorder = Recorder()
        clientHost(recorder, FakeClientHost(tunnel: "down\n"))
        let steps = Steps()
        await #expect(throws: PoolSSHError.self) {
            _ = try await PoolJoin.linuxClient(
                host: "laptop", hub: "homebox", accessKey: secrets.accessKey, run: recorder.runner, checkpoint: { steps.log.append($0) })
        }
        #expect(steps.log.first.flatMap { $0 }?.hubKey == false)
        #expect(steps.log.contains { $0?.hubKey == true })
        #expect(steps.log.last.map { $0 == nil } == true)
    }
}

final class Steps: @unchecked Sendable {
    var log: [PoolLinuxClient?] = []
}

final class Flag: @unchecked Sendable {
    var on = false
}
