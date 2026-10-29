import Foundation
import Testing

@testable import RelaybarCore

final class Opens: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [URL] = []

    func add(_ url: URL) { lock.withLock { kept.append(url) } }

    var urls: [URL] { lock.withLock { kept } }
}

final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [(wrong: Bool, why: String)] = []

    func add(_ wrong: Bool, _ why: String) { lock.withLock { kept.append((wrong, why)) } }

    var calls: [(wrong: Bool, why: String)] { lock.withLock { kept } }
}

final class AddLog: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [[PoolAddStage]] = []
    private var states: [(PoolAddStage, PoolStageState)] = []

    var hooks: PoolAddHooks {
        PoolAddHooks(
            plan: { [self] stages in lock.withLock { plans.append(stages) } },
            report: { [self] stage, state in lock.withLock { states.append((stage, state)) } })
    }

    var plan: [PoolAddStage]? { lock.withLock { plans.last } }

    func last(_ stage: PoolAddStage) -> PoolStageState? { lock.withLock { states.last { $0.0 == stage }?.1 } }
}

extension PoolJoinTests {
    private func installs(_ recorder: Recorder) -> [String] {
        onLaptop(recorder).map(plainScript).filter { $0.contains("curl -fsSL '") }
    }

    @Test func installsOnlyMissingTools() async throws {
        let recorder = Recorder()
        clientHost(recorder, FakeClientHost(probe: FakeClientHost.probe + "\nneed:claude\nneed:codex\ncodexdir:new"))
        let client = try await add(recorder)
        let scripts = installs(recorder)
        #expect(scripts.count == 2)
        #expect(scripts[0].contains("curl -fsSL 'https://claude.ai/install.sh' -o \"$f\" && bash \"$f\""))
        #expect(
            scripts[1].contains("curl -fsSL 'https://chatgpt.com/codex/install.sh' -o \"$f\" && CODEX_NON_INTERACTIVE=1 sh \"$f\""))
        #expect(scripts.allSatisfy { !$0.contains("sudo") })
        #expect(scripts.allSatisfy { $0.contains("[ -x \"$HOME/.local/bin/") })
        #expect(client.claudeInstalled && client.codexInstalled && client.codexProfile && client.codexFolder)
        let first = try #require(recorder.commands.firstIndex { remoteScript($0).contains("bash \"$f\"") })
        let tunnel = try #require(
            recorder.commands.firstIndex { remoteScript($0).contains("relaybar-tunnel.service\"") && $0.stdin != nil })
        #expect(first < tunnel)

        let onlyCodex = Recorder()
        clientHost(onlyCodex, FakeClientHost(probe: FakeClientHost.probe + "\nneed:codex\nprofile:codex"))
        let some = try await add(onlyCodex)
        #expect(installs(onlyCodex).count == 1)
        #expect(some.codexInstalled && !some.claudeInstalled && !some.codexProfile && !some.codexFolder)

        let none = Recorder()
        clientHost(none)
        let nothing = try await add(none)
        #expect(installs(none).isEmpty)
        #expect(!nothing.claudeInstalled && !nothing.codexInstalled)
        let probe = try #require(onLaptop(none).map(plainScript).first { $0.contains("for d in") })
        #expect(probe.contains("command -v $t"))
        #expect(probe.contains("need:$t"))
    }

    @Test func plansOnlyTheStepsThatApply() async throws {
        let plain = AddLog()
        let recorder = Recorder()
        clientHost(recorder)
        _ = try await add(recorder, hooks: plain.hooks)
        #expect(plain.plan == [.letIn, .route, .commands])
        #expect(plain.plan?.allSatisfy { plain.last($0) == .done } == true)

        let full = AddLog()
        let everything = Recorder()
        let up = "RB-IP\n100.64.0.9\nRB-STATUS\n" + tailscaleStatus("Running") + "\n"
        let host = FakeClientHost(probe: FakeClientHost.probe + "\nneed:claude")
        everything.respond = { command in
            if command.executable == "/usr/bin/ssh", remoteScript(command).hasPrefix("if ! command -v tailscale") {
                return CommandResult(output: up)
            }
            return host.answer(command) ?? CommandResult()
        }
        _ = try await add(everything, options: PoolAddOptions(t3Channel: .nightly, tailscale: true), hooks: full.hooks)
        #expect(full.plan == [.letIn, .tools, .tailscale, .route, .commands, .t3, .link])
        #expect(full.plan?.allSatisfy { full.last($0) == .done } == true)
        #expect(!everything.commands.contains { plainScript($0).hasPrefix("sudo") })
    }

    @Test func aFailedInstallNamesTheToolAndUndoesIt() async throws {
        let recorder = Recorder()
        let failing = FakeClientHost(
            probe: FakeClientHost.probe + "\nneed:claude", installFailure: ["claude.ai": "curl: (6) Could not resolve host: claude.ai\n"])
        clientHost(recorder, failing)
        let failure = await #expect(throws: PoolClientError.self) { _ = try await add(recorder) }
        #expect(failure == .installFailed(host: "laptop", tool: "Claude Code", reason: "curl: (6) Could not resolve host: claude.ai"))
        let message = try #require(failure?.errorDescription)
        #expect(message.hasPrefix("Claude Code could not be installed on laptop: curl: (6)"))
        #expect(message.hasSuffix("Check that laptop can reach the internet, then try again."))
        #expect(!message.contains("—"))
        let undo = try #require(onLaptop(recorder).map(plainScript).last)
        #expect(undo.contains("rm -f \"$HOME/.local/bin/claude\"; rm -rf \"$HOME/.local/share/claude\""))
        #expect(!undo.contains("$HOME/.claude\""))
        #expect(!undo.contains(".claude.json"))
    }

    @Test func findsToolsInTheLocalBinFolder() async throws {
        let recorder = Recorder()
        let host = FakeClientHost(
            probe: FakeClientHost.probe + "\nbin:claude\nbin:codex\nt3:yes", settings: t3File)
        clientHost(recorder, host)
        _ = try await add(recorder)
        let launchers = recorder.commands.filter {
            remoteScript($0).contains(".local/bin/claude+") || remoteScript($0).contains(".local/bin/codex+")
        }
        let claude = try #require(launchers.first { remoteScript($0).contains("claude+") })
        let codex = try #require(launchers.first { remoteScript($0).contains("codex+") })
        #expect(String(decoding: claude.stdin ?? Data(), as: UTF8.self).contains("exec \"$HOME/.local/bin/claude\" \"$@\""))
        #expect(String(decoding: codex.stdin ?? Data(), as: UTF8.self).contains("exec \"$HOME/.local/bin/codex\" -c "))
        let push = try #require(onLaptop(recorder).last { remoteScript($0).contains("relaybar-new") })
        let settings = try #require(try JSONSerialization.jsonObject(with: push.stdin ?? Data()) as? [String: Any])
        let instances = try #require(settings["providerInstances"] as? [String: [String: Any]])
        #expect((instances["claudeAgent_all_accounts"]?["config"] as? [String: String])?["binaryPath"] == "/home/sam/.local/bin/claude")
        #expect((instances["codex_all_accounts"]?["config"] as? [String: String])?["binaryPath"] == "/home/sam/.local/bin/codex+")
        let probe = try #require(onLaptop(recorder).map(plainScript).first { $0.contains("for d in") })
        #expect(probe.contains("PATH=\"$HOME/.local/bin:$PATH\" command -v $t"))

        let plain = Recorder()
        clientHost(plain, FakeClientHost(probe: FakeClientHost.probe + "\nt3:yes", settings: t3File))
        _ = try await add(plain)
        let bare = try #require(plain.commands.first { remoteScript($0).contains("claude+") && $0.stdin != nil })
        #expect(String(decoding: bare.stdin ?? Data(), as: UTF8.self).contains("exec claude \"$@\""))
        let bareSettings = try #require(plain.commands.last { remoteScript($0).contains("relaybar-new") })
        let bareRoot = try #require(try JSONSerialization.jsonObject(with: bareSettings.stdin ?? Data()) as? [String: Any])
        let bareInstances = try #require(bareRoot["providerInstances"] as? [String: [String: Any]])
        #expect((bareInstances["claudeAgent_all_accounts"]?["config"] as? [String: String]) == [:])
    }

    @Test func installsT3CodeOnTheMacsChannel() async throws {
        #expect(T3Channel.detect(version: "0.1.4-nightly.20261028.3824") == .nightly)
        #expect(T3Channel.detect(version: "0.1.4-preview.3") == .preview)
        #expect(T3Channel.detect(version: "0.1.4") == .stable)
        #expect(PoolInstallSite.t3.address == "https://t3.codes/install.sh")
        for (channel, word) in [(T3Channel.nightly, "nightly"), (.stable, "stable"), (.preview, "preview")] {
            let recorder = Recorder()
            clientHost(recorder)
            let client = try await add(recorder, options: PoolAddOptions(t3Channel: channel))
            let script = try #require(installs(recorder).first { $0.contains("t3.codes") })
            #expect(script.contains("curl -fsSL 'https://t3.codes/install.sh' -o \"$f\" && T3CODE_CHANNEL=\(word) sh \"$f\""))
            #expect(client.t3Installed && client.t3Service)
            #expect(
                recorder.commands.contains { remoteScript($0).contains("\"$HOME/.local/bin/t3\" service install </dev/null") })
        }
        let already = Recorder()
        clientHost(already, FakeClientHost(probe: FakeClientHost.probe + "\nt3path:/usr/local/bin/t3"))
        let kept = try await add(already, options: PoolAddOptions(t3Channel: .stable))
        #expect(installs(already).isEmpty)
        #expect(!kept.t3Installed && !kept.t3Service)
        #expect(!already.commands.contains { remoteScript($0).contains("service install") })
        let off = Recorder()
        clientHost(off)
        _ = try await add(off)
        #expect(!off.commands.contains { remoteScript($0).contains("t3.codes") })
    }

    @Test func findsToolsThroughTheLoginShell() async throws {
        let recorder = Recorder()
        clientHost(recorder)
        _ = try await add(recorder)
        let probe = try #require(onLaptop(recorder).map(plainScript).first { $0.contains("for d in") })
        #expect(
            probe.contains("[ -n \"$p\" ] || p=$(\"${SHELL:-sh}\" -lc \"command -v $t\" </dev/null 2>/dev/null | grep '^/' | tail -n 1)"))
        let order = try #require(probe.range(of: "-lc")).lowerBound
        let needs = try #require(probe.range(of: "echo need:$t")).lowerBound
        #expect(order < needs)
    }

    private func outcome(
        _ host: FakeClientHost, options: PoolAddOptions, hooks: PoolAddHooks = .none, tailscaleUp: Bool = false
    ) async throws -> PoolAddResult {
        let up = "RB-IP\n100.64.0.9\nRB-STATUS\n" + tailscaleStatus("Running") + "\n"
        let recorder = Recorder()
        recorder.respond = { command in
            if tailscaleUp, command.executable == "/usr/bin/ssh", remoteScript(command).hasPrefix("if ! command -v tailscale") {
                return CommandResult(output: up)
            }
            return host.answer(command) ?? CommandResult()
        }
        return try await PoolJoin.linuxClient(
            host: "laptop", hub: "homebox", accessKey: secrets.accessKey, options: options, hooks: hooks, run: recorder.runner)
    }

    @Test func saysWhatTheSetupDid() async throws {
        let both = PoolAddOptions(t3Channel: .nightly, tailscale: true)
        let linked = try await outcome(FakeClientHost(), options: both, tailscaleUp: true)
        #expect(linked.link == .linked && linked.listening == .tailscale && linked.notes.isEmpty)

        let homeOnly = try await outcome(FakeClientHost(reachable: false), options: both, tailscaleUp: true)
        #expect(homeOnly.link == .linked && homeOnly.listening == .homeNetwork && homeOnly.notes == [.tailscaleUnreachable])

        let declined = try await outcome(
            FakeClientHost(pair: "no link\n"), options: PoolAddOptions(t3Channel: .nightly), hooks: PoolAddHooks(linkFailed: { _ in false })
        )
        #expect(declined.link == .notLinked)

        let quiet = try await outcome(FakeClientHost(), options: PoolAddOptions())
        #expect(quiet.link == .notTried && quiet.listening == .unchanged && quiet.notes.isEmpty)

        let running = "\nt3svc:yes\nt3exec:/home/laptop/.t3/runtime/versions/0.1.6/t3"
        let kept = try await outcome(FakeClientHost(probe: FakeClientHost.probe + running), options: both, tailscaleUp: true)
        #expect(kept.link == .linked && kept.listening == .unchanged && kept.notes == [.t3Kept])

        let lost = try await outcome(
            FakeClientHost(probe: FakeClientHost.probe + "\nt3svc:yes"), options: PoolAddOptions(t3Channel: .nightly))
        #expect(lost.link == .notTried && lost.notes == [.t3NotFound])
        #expect(!lost.client.t3Installed)
    }

    @Test func usesTheFullPathOfALoginShellTool() async throws {
        let recorder = Recorder()
        let found = "\npath:claude:/home/sam/.nvm/bin/claude\npath:codex:/opt/tools/bin/codex\nt3:yes"
        clientHost(recorder, FakeClientHost(probe: FakeClientHost.probe + found, settings: t3File))
        _ = try await add(recorder)
        let claude = try #require(recorder.commands.first { remoteScript($0).contains("claude+") && $0.stdin != nil })
        let codex = try #require(recorder.commands.first { remoteScript($0).contains("codex+") && $0.stdin != nil })
        #expect(String(decoding: claude.stdin ?? Data(), as: UTF8.self).contains("exec \"/home/sam/.nvm/bin/claude\" \"$@\""))
        #expect(String(decoding: codex.stdin ?? Data(), as: UTF8.self).contains("exec \"/opt/tools/bin/codex\" -c "))
        let push = try #require(onLaptop(recorder).last { remoteScript($0).contains("relaybar-new") })
        let settings = try #require(try JSONSerialization.jsonObject(with: push.stdin ?? Data()) as? [String: Any])
        let instances = try #require(settings["providerInstances"] as? [String: [String: Any]])
        #expect((instances["claudeAgent_all_accounts"]?["config"] as? [String: String])?["binaryPath"] == "/home/sam/.nvm/bin/claude")
        #expect((instances["codex_all_accounts"]?["config"] as? [String: String])?["binaryPath"] == "/home/sam/.local/bin/codex+")
        let probe = try #require(onLaptop(recorder).map(plainScript).first { $0.contains("for d in") })
        #expect(probe.contains("elif [ -x \"$p\" ]; then echo path:$t:$p; fi"))

        let unsafe = Recorder()
        let bad = "\npath:claude:/home/sam/a b/claude\npath:codex:/home/sam/$(x)/codex\nt3:yes"
        clientHost(unsafe, FakeClientHost(probe: FakeClientHost.probe + bad, settings: t3File))
        _ = try await add(unsafe)
        let bare = try #require(unsafe.commands.first { remoteScript($0).contains("claude+") && $0.stdin != nil })
        #expect(String(decoding: bare.stdin ?? Data(), as: UTF8.self).contains("exec claude \"$@\""))

        let pairing = Recorder()
        clientHost(pairing, FakeClientHost(probe: FakeClientHost.probe + "\nt3path:/home/sam/.nvm/bin/t3\nt3svc:yes"))
        _ = try await add(pairing, options: PoolAddOptions(t3Channel: .nightly))
        let pair = try #require(onLaptop(pairing).map(plainScript).first { $0.contains("pair --label Relaybar") })
        #expect(pair.contains("\"/home/sam/.nvm/bin/t3\" pair"))
        let probeScript = try #require(onLaptop(pairing).map(plainScript).first { $0.contains("for d in") })
        #expect(
            probeScript.contains(
                "p=$(PATH=\"$HOME/.local/bin:$PATH\" command -v t3 2>/dev/null); [ -n \"$p\" ] || p=$(\"${SHELL:-sh}\" -lc \"command -v t3\""
            ))
    }

    private func watching(_ attempts: [Watch.Attempt], host: FakeClientHost = FakeClientHost()) -> (Recorder, Watch) {
        let watch = Watch(attempts)
        let recorder = Recorder()
        recorder.respond = { command in
            guard command.executable == "/usr/bin/ssh" else { return host.answer(command) ?? CommandResult() }
            let text = remoteScript(command)
            if text.contains("auth session list --json") { return CommandResult(output: watch.sessions()) }
            if text.contains("auth pairing list --json") { return CommandResult(output: watch.pairings()) }
            if text.contains("pair --label") { watch.pairStarted() }
            return host.answer(command) ?? CommandResult()
        }
        return (recorder, watch)
    }

    private func eventHooks(_ events: Events, tryAgain: Bool = false) -> PoolAddHooks {
        PoolAddHooks(
            report: { stage, state in if stage == .link { events.add("link:\(state)") } },
            pair: { _ in events.add("open") },
            linkFailed: { _ in
                events.add("ask")
                return tryAgain && events.count("ask") == 1
            },
            pause: { seconds in events.add("pause:\(Int(seconds))") })
    }

    @Test func waitsForTheUserToConfirmInT3Code() async throws {
        let (recorder, _) = watching([.confirms(3)])
        let events = Events()
        let result = try await PoolJoin.linuxClient(
            host: "laptop", hub: "homebox", accessKey: secrets.accessKey, options: PoolAddOptions(t3Channel: .nightly),
            hooks: eventHooks(events), run: recorder.runner)
        #expect(
            events.items == ["link:working", "open", "link:yourTurn", "pause:2", "pause:2", "pause:2", "link:done"])
        #expect(result.link == .linked && result.client.t3Session == "s-1")
        let scripts = onLaptop(recorder).map(plainScript)
        let before = try #require(scripts.firstIndex { $0.contains("auth session list --json") })
        let pair = try #require(scripts.firstIndex { $0.contains("pair --label Relaybar") })
        #expect(before < pair)
        #expect(scripts.contains { $0.contains("\"$HOME/.local/bin/t3\" auth session list --json </dev/null") })

        let old = Recorder()
        clientHost(old)
        let plain = try await PoolJoin.linuxClient(
            host: "laptop", hub: "homebox", accessKey: secrets.accessKey, options: PoolAddOptions(t3Channel: .nightly),
            hooks: eventHooks(Events()), run: old.runner)
        #expect(plain.link == .linked && plain.client.t3Session == nil)
    }

    @Test func offersTryAgainWhenTheLinkIsNotConfirmed() async throws {
        let (recorder, _) = watching([.gone(2), .confirms(1)])
        let events = Events()
        let result = try await PoolJoin.linuxClient(
            host: "laptop", hub: "homebox", accessKey: secrets.accessKey, options: PoolAddOptions(t3Channel: .nightly),
            hooks: eventHooks(events, tryAgain: true), run: recorder.runner)
        #expect(
            events.items == [
                "link:working", "open", "link:yourTurn", "pause:2", "pause:2", "ask", "link:working", "open", "link:yourTurn", "pause:2",
                "link:done",
            ])
        #expect(result.link == .linked && result.client.t3Session == "s-2")

        let (silent, _) = watching([.never])
        let waited = Events()
        let late = try await PoolJoin.linuxClient(
            host: "laptop", hub: "homebox", accessKey: secrets.accessKey, options: PoolAddOptions(t3Channel: .nightly),
            hooks: eventHooks(waited), run: silent.runner)
        #expect(late.link == .notLinked && late.client.t3Session == nil)
        #expect(waited.items.filter { $0 == "pause:2" }.count == 150)
        #expect(waited.items.last == "link:problem(\"Not linked\")")
    }

    @Test func stopsWaitingWhenCancelled() async throws {
        let (recorder, _) = watching([.never])
        let box = TaskBox()
        let events = Events()
        let hooks = PoolAddHooks(
            pause: { _ in
                events.add("pause")
                if events.count("pause") == 2 {
                    while !box.isSet { await Task.yield() }
                    box.cancel()
                }
            })
        let secrets = secrets
        let task = Task {
            try await PoolJoin.linuxClient(
                host: "laptop", hub: "homebox", accessKey: secrets.accessKey, options: PoolAddOptions(t3Channel: .nightly), hooks: hooks,
                run: recorder.runner)
        }
        box.set { task.cancel() }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(events.count("pause") == 2)
    }

    @Test func removeEndsTheT3CodeLink() async throws {
        var installed = PoolLinuxClient(host: "laptop")
        installed.t3Installed = true
        installed.t3Service = true
        installed.t3Session = "s-1"
        let recorder = Recorder()
        let removal = try PoolJoin.removeLinuxClient(installed, hubRoutes: [], run: recorder.runner)
        #expect(!removal.t3LinkStays)
        let scripts = onLaptop(recorder).map(plainScript)
        let revoke = try #require(scripts.firstIndex { $0.contains("auth session revoke 's-1'") })
        let uninstall = try #require(scripts.firstIndex { $0.contains("service uninstall") })
        #expect(revoke < uninstall)
        #expect(scripts[revoke].contains("\"$HOME/.local/bin/t3\""))

        var kept = PoolLinuxClient(host: "laptop")
        kept.t3Session = "s-2"
        kept.t3Binary = "/usr/local/bin/t3"
        let existing = Recorder()
        try PoolJoin.removeLinuxClient(kept, hubRoutes: [], run: existing.runner)
        let revokeKept = try #require(onLaptop(existing).map(plainScript).first { $0.contains("auth session revoke 's-2'") })
        #expect(revokeKept.contains("/usr/local/bin/t3") && revokeKept.contains("\"$t3\" auth session revoke 's-2'"))
        #expect(!existing.commands.map(plainScript).contains { $0.contains("service uninstall") || $0.contains("uninstall -y") })

        let failing = Recorder()
        failing.respond = { command in
            remoteScript(command).contains("session revoke") ? CommandResult(status: 1, error: "t3: not running\n") : CommandResult()
        }
        let stuck = try PoolJoin.removeLinuxClient(installed, hubRoutes: [], run: failing.runner)
        #expect(stuck.t3LinkStays)
        #expect(failing.commands.map(plainScript).contains { $0.contains("service uninstall") })

        let none = Recorder()
        try PoolJoin.removeLinuxClient(PoolLinuxClient(host: "laptop"), hubRoutes: [], run: none.runner)
        #expect(!none.commands.map(plainScript).contains { $0.contains("session revoke") })
    }

    @Test func saysWhyItDidNotLink() async throws {
        let installed = FakeClientHost(probe: FakeClientHost.probe + "\nt3path:/usr/local/bin/t3")
        let log = AddLog()
        let stopped = try await outcome(installed, options: PoolAddOptions(t3Channel: .nightly), hooks: log.hooks)
        #expect(stopped.link == .notTried && stopped.notes == [.t3NotRunning])
        #expect(!stopped.client.t3Installed && !stopped.client.t3Service)
        #expect(log.plan == [.letIn, .route, .commands])
        let both = try await outcome(installed, options: PoolAddOptions(t3Channel: .nightly, tailscale: true), tailscaleUp: true)
        #expect(both.notes == [.t3NotRunning])
        let off = try await outcome(installed, options: PoolAddOptions())
        #expect(off.notes.isEmpty)
    }

    @Test func leavesAnExistingT3CodeAlone() async throws {
        let running = "\nt3svc:yes\nt3exec:/home/laptop/.t3/runtime/versions/0.1.6/t3"
        let recorder = Recorder()
        let log = AddLog()
        clientHost(recorder, FakeClientHost(probe: FakeClientHost.probe + running))
        let client = try await add(recorder, options: PoolAddOptions(t3Channel: .nightly), hooks: log.hooks)
        #expect(installs(recorder).isEmpty)
        #expect(!client.t3Installed && !client.t3Service)
        #expect(!recorder.commands.contains { remoteScript($0).contains("service install") })
        #expect(log.plan == [.letIn, .route, .commands, .link])
        let pair = try #require(onLaptop(recorder).map(plainScript).first { $0.contains("pair --label Relaybar") })
        #expect(pair.contains("\"/home/laptop/.t3/runtime/versions/0.1.6/t3\" pair"))

        let lost = Recorder()
        let lostLog = AddLog()
        clientHost(lost, FakeClientHost(probe: FakeClientHost.probe + "\nt3svc:yes"))
        let kept = try await add(lost, options: PoolAddOptions(t3Channel: .nightly), hooks: lostLog.hooks)
        #expect(installs(lost).isEmpty)
        #expect(!kept.t3Installed && !kept.t3Service)
        #expect(lostLog.plan == [.letIn, .route, .commands])
        #expect(!lost.commands.contains { remoteScript($0).contains("pair --label") })
    }

    @Test func setsTheDefaultOnAFreshT3Code() async throws {
        let recorder = Recorder()
        clientHost(recorder)
        let client = try await add(recorder, options: PoolAddOptions(t3Channel: .nightly, t3Model: "claude-x"))
        let pushed = try #require(onLaptop(recorder).first { remoteScript($0).contains("relaybar-new") })
        let settings = try #require(try JSONSerialization.jsonObject(with: pushed.stdin ?? Data()) as? [String: Any])
        #expect(settings["defaultModelSelection"] as? [String: String] == ["instanceId": "claudeAgent_all_accounts", "model": "claude-x"])
        #expect(client.t3DefaultSet && client.previousSelection == nil)
    }

    @Test func addsEntriesAfterT3CodeStarts() async throws {
        let recorder = Recorder()
        clientHost(recorder)
        let client = try await add(recorder, options: PoolAddOptions(t3Channel: .nightly))
        let scripts = onLaptop(recorder).map(plainScript)
        let install = try #require(scripts.firstIndex { $0.contains("T3CODE_CHANNEL=nightly") })
        let service = try #require(scripts.firstIndex { $0.contains("service install") })
        let wait = try #require(scripts.firstIndex { $0.contains("server-runtime.json") && $0.contains("echo ready") })
        let push = try #require(scripts.firstIndex { $0.contains("relaybar-new") })
        #expect(install < service && service < wait && wait < push)
        let waiting = scripts[wait]
        #expect(waiting.contains("systemctl --user is-active --quiet t3code.service"))
        #expect(waiting.contains("\"$HOME/.t3/userdata/server-runtime.json\" -nt \"$HOME/.config/systemd/user/t3code.service\""))
        #expect(waiting.contains("echo notready"))
        let pushed = try #require(onLaptop(recorder).first { remoteScript($0).contains("relaybar-new") })
        let settings = try #require(try JSONSerialization.jsonObject(with: pushed.stdin ?? Data()) as? [String: Any])
        #expect((settings["providerInstances"] as? [String: Any])?.keys.sorted() == ["claudeAgent_all_accounts", "codex_all_accounts"])
        #expect(plainScript(pushed).contains("if [ -e \"$f\" ]; then"))
        #expect(client.t3Entries)
        #expect(!client.t3SecretsFolder)

        let late = Recorder()
        clientHost(late, FakeClientHost(ready: "notready\n"))
        let failure = await #expect(throws: PoolClientError.self) { _ = try await add(late, options: PoolAddOptions(t3Channel: .nightly)) }
        #expect(failure == .t3NotReady("laptop"))
        #expect(failure?.errorDescription?.contains("systemctl --user status t3code on laptop") == true)
        #expect(!late.commands.contains { remoteScript($0).contains("relaybar-new") })
        let undo = try #require(onLaptop(late).map(plainScript).last { $0.contains("service uninstall") })
        #expect(undo.contains("service uninstall </dev/null || exit 1; \"$t3\" uninstall -y </dev/null || exit 1;"))
    }

    @Test func opensOnlyAT3PairLink() async throws {
        let good = "x\nApp link: t3code://pair?pairingUrl=http%3A%2F%2F192.168.1.30%3A3773%2Fpair%23token%3DFIXTURE\nToken: FIXTURE\n"
        #expect(PoolJoin.pairLink(in: good)?.scheme == "t3code")
        for bad in [
            "App link: https://pair?x=1", "App link: t3code://other?x=1", "App link: javascript:alert(1)", "Pairing URL: t3code://pair?x=1",
            "App link: file:///etc/passwd", "", "App link: t3code-dev://pair?x=1",
        ] {
            #expect(PoolJoin.pairLink(in: bad) == nil, "\(bad)")
        }
        let opens = Opens()
        let recorder = Recorder()
        clientHost(recorder)
        _ = try await add(
            recorder, options: PoolAddOptions(t3Channel: .stable), hooks: PoolAddHooks(pair: { opens.add($0) }))
        #expect(opens.urls.map(\.host) == ["pair"])
        #expect(opens.urls.first?.scheme == "t3code")
        let pairing = try #require(recorder.commands.first { remoteScript($0).contains("pair --label") })
        #expect(pairing.arguments.joined(separator: " ").contains("FIXTURE") == false)
        #expect(
            !recorder.commands.contains {
                ($0.arguments + [String(decoding: $0.stdin ?? Data(), as: UTF8.self)]).joined(separator: " ").contains("token%3DFIXTURE")
            })

        let wrong = Recorder()
        clientHost(wrong, FakeClientHost(pair: "App link: https://evil.example/pair#token=FIXTURE\n"))
        let refused = try await PoolJoin.linuxClient(
            host: "laptop", hub: "homebox", accessKey: secrets.accessKey, options: PoolAddOptions(t3Channel: .stable),
            hooks: PoolAddHooks(pair: { opens.add($0) }), run: wrong.runner)
        #expect(refused.link == .notLinked)
        #expect(opens.urls.count == 1)
    }

    private func failingPair(_ host: FakeClientHost, times: Int) -> (Recorder, Tally) {
        let recorder = Recorder()
        let calls = Tally()
        recorder.respond = { command in
            if command.executable == "/usr/bin/ssh", remoteScript(command).contains("pair --label"), calls.next() <= times {
                return CommandResult(status: 1, error: "t3: the server is not ready\n")
            }
            return host.answer(command) ?? CommandResult()
        }
        return (recorder, calls)
    }

    @Test func keepsTheSetupWhenTheLinkFails() async throws {
        let harness = try Harness()
        harness.answerHomeAndComputers()
        let setup = PoolSetup(env: harness.env())
        _ = try await setup.combineOnHome(host: "homebox")
        let base = harness.recorder.respond
        harness.recorder.respond = { command in
            remoteScript(command).contains("pair --label")
                ? CommandResult(status: 1, error: "t3: the server is not ready\n") : base(command)
        }
        let asked = Asked()
        let opens = Opens()
        let hooks = PoolAddHooks(
            pair: { opens.add($0) },
            linkFailed: { host in
                asked.add(false, host)
                return false
            })
        let client = try await setup.useOnLinux(host: "laptop", options: PoolAddOptions(t3Channel: .stable), hooks: hooks)
        #expect(client.link == .notLinked)
        #expect(client.t3Installed && client.t3Service && client.t3Entries)
        #expect(asked.calls.map(\.why) == ["laptop"])
        #expect(opens.urls.isEmpty)
        let sent = harness.recorder.commands.map(plainScript)
        #expect(!sent.contains { $0.contains("service uninstall") || $0.contains("rm -f \"$HOME/.local/bin/claude\"") })
        let saved = try #require(PoolState.load(harness.paths)?.linuxClients.first)
        #expect(saved == client.client)
        #expect(saved.hubKey)
        let log = AddLog()
        let quiet = Recorder()
        let (failing, _) = failingPair(FakeClientHost(), times: 9)
        quiet.respond = failing.respond
        let plain = try await PoolJoin.linuxClient(
            host: "laptop", hub: "homebox", accessKey: secrets.accessKey, options: PoolAddOptions(t3Channel: .stable),
            hooks: PoolAddHooks(plan: log.hooks.plan, report: log.hooks.report), run: quiet.runner)
        #expect(plain.link == .notLinked)
        #expect(log.last(.link) == .problem("Not linked"))
    }

    @Test func triesTheLinkAgain() async throws {
        let (recorder, calls) = failingPair(FakeClientHost(), times: 1)
        let asked = Asked()
        let opens = Opens()
        let hooks = PoolAddHooks(
            pair: { opens.add($0) },
            linkFailed: { host in
                asked.add(false, host)
                return true
            })
        let client = try await PoolJoin.linuxClient(
            host: "laptop", hub: "homebox", accessKey: secrets.accessKey, options: PoolAddOptions(t3Channel: .stable), hooks: hooks,
            run: recorder.runner)
        #expect(calls.count == 2)
        #expect(asked.calls.count == 1)
        #expect(opens.urls.map(\.host) == ["pair"])
        #expect(client.link == .linked)
    }

    @Test func limitsT3CodeToTailscale() async throws {
        let up = "RB-IP\n100.64.0.9\nRB-STATUS\n" + tailscaleStatus("Running") + "\n"
        let recorder = Recorder()
        let host = FakeClientHost()
        recorder.respond = { command in
            let text = remoteScript(command)
            if command.executable == "/usr/bin/ssh", text.hasPrefix("if ! command -v tailscale") { return CommandResult(output: up) }
            return host.answer(command) ?? CommandResult()
        }
        let opens = Opens()
        let client = try await add(
            recorder, options: PoolAddOptions(t3Channel: .nightly, tailscale: true), hooks: PoolAddHooks(pair: { opens.add($0) }))
        let scripts = onLaptop(recorder).map(plainScript)
        let env = try #require(scripts.firstIndex { $0.contains("T3CODE_HOST=%s") })
        let retry = try #require(scripts.firstIndex { $0.contains("t3code.service.d/relaybar.conf") })
        let restart = try #require(scripts.firstIndex { $0.contains("service restart") })
        let waited = try #require(scripts.lastIndex { $0.contains("grep -q '\"host\":\"100.64.0.9\"'") })
        let pair = try #require(scripts.firstIndex { $0.contains("pair --label") })
        #expect(env < retry && retry < restart && restart < waited && waited < pair)
        #expect(scripts[retry].contains("printf '[Unit]\\nStartLimitIntervalSec=0\\n' > \"$f\" && systemctl --user daemon-reload"))
        #expect(scripts[retry].contains("if [ -L \"$d\" ] || [ -L \"$f\" ]; then echo link; exit 0; fi;"))
        #expect(scripts[env].contains("printf 'T3CODE_HOST=%s\\n' '100.64.0.9'"))
        #expect(scripts[env].contains("if [ -L \"$f\" ]; then echo link; exit 0; fi;"))
        #expect(client.t3Host == "100.64.0.9")
        #expect(opens.urls.count == 1)
        let reach = try #require(recorder.commands.first { $0.arguments.last == "true" && $0.arguments.contains("sam@100.64.0.9") })
        #expect(reach.arguments.contains("BatchMode=yes"))

        let quiet = Recorder()
        let silent = FakeClientHost(reachable: false)
        quiet.respond = { command in
            let text = remoteScript(command)
            if command.executable == "/usr/bin/ssh", text.hasPrefix("if ! command -v tailscale") { return CommandResult(output: up) }
            return silent.answer(command) ?? CommandResult()
        }
        let default3773 = try await add(quiet, options: PoolAddOptions(t3Channel: .nightly, tailscale: true))
        #expect(default3773.t3Host == nil)
        #expect(!quiet.commands.contains { remoteScript($0).contains("T3CODE_HOST") || remoteScript($0).contains("service restart") })
        #expect(quiet.commands.contains { remoteScript($0).contains("pair --label") })
    }

    @Test(arguments: [
        ("RB-MISSING\n", "install Tailscale"), ("RB-STATUS\n" + tailscaleStatus("NeedsLogin", own: []) + "\n", "start Tailscale"),
    ])
    func asksForThePasswordOnce(signedOut: String, why: String) async throws {
        let secret = "hunter2-added"
        let installed = Flag()
        let recorder = Recorder()
        let host = FakeClientHost(password: secret)
        recorder.respond = { command in
            let text = remoteScript(command)
            if command.executable == "/usr/bin/ssh" {
                if text.hasPrefix("if ! command -v tailscale") {
                    return CommandResult(
                        output: installed.on ? "RB-IP\n100.64.0.9\nRB-STATUS\n" + tailscaleStatus("Running") + "\n" : signedOut)
                }
                if text.contains("sudo"), text.contains("tailscale up") {
                    if command.stdin != nil { installed.on = true }
                    return command.stdin == nil
                        ? CommandResult(status: 1, error: "sudo: a password is required\n") : CommandResult(output: signInOutput)
                }
            }
            return host.answer(command) ?? CommandResult()
        }
        let asked = Asked()
        let opened = Opens()
        let hooks = PoolAddHooks(
            password: { wrong, why in
                asked.add(wrong, why)
                return secret
            }, signIn: { opened.add($0) })
        let client = try await add(recorder, options: PoolAddOptions(t3Channel: .nightly, tailscale: true), hooks: hooks)
        #expect(asked.calls.count == 1)
        #expect(asked.calls.first?.wrong == false)
        #expect(asked.calls.first?.why == why)
        #expect(opened.urls.map(\.absoluteString) == ["https://login.tailscale.com/a/1a2b3c4d5e6f"])
        let withPassword = recorder.commands.filter { $0.stdin == Data((secret + "\n").utf8) }
        #expect(withPassword.count >= (why == "install Tailscale" ? 2 : 1))
        for command in recorder.commands {
            #expect(!([command.executable] + command.arguments).joined(separator: " ").contains(secret))
            if command.stdin == Data((secret + "\n").utf8) { #expect(plainScript(command).hasPrefix("sudo -S -p '' sh -c ")) }
        }
        #expect(client.tailscaleInstalled == (why == "install Tailscale"))

        let wrong = Recorder()
        let strict = FakeClientHost(password: secret)
        wrong.respond = { command in
            let text = remoteScript(command)
            if command.executable == "/usr/bin/ssh", text.hasPrefix("if ! command -v tailscale") { return CommandResult(output: signedOut) }
            return strict.answer(command) ?? CommandResult()
        }
        let tries = Asked()
        let guesses = Guesses(["nope", secret])
        let retry = PoolAddHooks(
            password: { wrongBefore, why in
                tries.add(wrongBefore, why)
                return guesses.next()
            })
        await #expect(throws: PoolTailscaleError.self) {
            _ = try await add(wrong, options: PoolAddOptions(tailscale: true), hooks: retry)
        }
        #expect(tries.calls.map(\.wrong) == [false, true])

        let declined = Recorder()
        declined.respond = wrong.respond
        let declining = PoolAddHooks(password: { _, _ in nil })
        let refusal = await #expect(throws: PoolClientError.self) {
            _ = try await add(declined, options: PoolAddOptions(tailscale: true), hooks: declining)
        }
        #expect(refusal == .needsPassword(host: "laptop", why: why))
        #expect(
            refusal?.errorDescription
                == "Relaybar needs the password for laptop to \(why). It did not get it, so it removed what it had set up. Try again when you have it."
        )
    }

    @Test func namesTheRealReasonWhenARootStepFails() async throws {
        func run(_ error: String) async -> PoolClientError? {
            let recorder = Recorder()
            recorder.respond = { _ in CommandResult(status: 1, error: error) }
            let session = PoolPasswordSession(host: "laptop", run: recorder.runner, ask: { _, _ in nil })
            return await #expect(throws: PoolClientError.self) { _ = try await session.run("true", why: "install Tailscale") }
        }
        let network = "curl: (6) Could not resolve host: pkgs.example.com\n"
        let failed = await run(network)
        #expect(
            failed
                == .rootStepFailed(host: "laptop", why: "install Tailscale", reason: "curl: (6) Could not resolve host: pkgs.example.com"))
        let text = try #require(failed?.errorDescription)
        #expect(text.hasPrefix("Relaybar could not install Tailscale on laptop: curl: (6)"))
        #expect(!text.contains("administrator") && !text.contains("sudo"))

        for refusal in [
            "sam is not in the sudoers file.  This incident will be reported.\n", "Sorry, user sam may not run sudo on laptop.\n",
        ] {
            let denied = await run(refusal)
            #expect(denied?.errorDescription?.contains("administrator rights (sudo)") == true)
        }
    }

    @Test func asksOnceForTailscaleAndLinger() async throws {
        let secret = "hunter2-twice"
        let installed = Flag()
        let recorder = Recorder()
        let host = FakeClientHost(password: secret, lingerNeedsSudo: true)
        recorder.respond = { command in
            let text = remoteScript(command)
            if command.executable == "/usr/bin/ssh" {
                if text.hasPrefix("if ! command -v tailscale") {
                    return CommandResult(
                        output: installed.on ? "RB-IP\n100.64.0.9\nRB-STATUS\n" + tailscaleStatus("Running") + "\n" : "RB-MISSING\n")
                }
                if text.contains("sudo"), text.contains("tailscale up") {
                    if command.stdin != nil { installed.on = true }
                    return command.stdin == nil
                        ? CommandResult(status: 1, error: "sudo: a password is required\n") : CommandResult(output: signInOutput)
                }
            }
            return host.answer(command) ?? CommandResult()
        }
        let asked = Asked()
        let hooks = PoolAddHooks(password: { wrong, why in
            asked.add(wrong, why)
            return secret
        })
        let client = try await add(recorder, options: PoolAddOptions(t3Channel: .nightly, tailscale: true), hooks: hooks)
        #expect(asked.calls.map(\.why) == ["install Tailscale"])
        #expect(client.linger)
        let scripts = recorder.commands.map(plainScript)
        let tailscale = try #require(scripts.firstIndex { $0.hasPrefix("sudo -S") && $0.contains("tailscale up") })
        let linger = try #require(scripts.firstIndex { $0.hasPrefix("sudo") && $0.contains("loginctl enable-linger \"$SUDO_USER\"") })
        #expect(tailscale < linger)
        #expect(scripts[linger].hasPrefix("sudo -S -p '' sh -c "))
        #expect(recorder.commands[linger].stdin == Data((secret + "\n").utf8))

        let alone = Recorder()
        alone.respond = { command in host.answer(command) ?? CommandResult() }
        let lone = Asked()
        let loneHooks = PoolAddHooks(password: { wrong, why in
            lone.add(wrong, why)
            return secret
        })
        _ = try await add(alone, options: PoolAddOptions(t3Channel: .nightly), hooks: loneHooks)
        #expect(lone.calls.map(\.why) == ["keep T3 Code running after you log out"])
    }

    @Test func removesOnlyWhatItInstalled() async throws {
        var client = PoolLinuxClient(host: "laptop", folders: [".codex-hub"], linger: true)
        client.claudeInstalled = true
        client.codexInstalled = true
        client.codexProfile = true
        client.codexFolder = true
        client.t3Installed = true
        client.t3Service = true
        client.t3Host = "100.64.0.9"
        let recorder = Recorder()
        try PoolJoin.removeLinuxClient(client, hubRoutes: ["homebox"], run: recorder.runner)
        let scripts = onLaptop(recorder).map(plainScript)
        let t3 = try #require(scripts.first { $0.contains("service uninstall") })
        #expect(
            t3.hasPrefix(
                "t3=\"$HOME/.local/bin/t3\"; if [ -x \"$t3\" ]; then \"$t3\" service uninstall </dev/null || exit 1; \"$t3\" uninstall -y </dev/null || exit 1; fi;"
            ))
        #expect(t3.contains("grep -v '^T3CODE_HOST=' \"$f\""))
        #expect(t3.contains("rm -f \"$f\"; rmdir \"$d\" 2>/dev/null; systemctl --user daemon-reload"))
        let undo = try #require(scripts.last)
        #expect(undo.contains("rm -f \"$HOME/.local/bin/claude\"; rm -rf \"$HOME/.local/share/claude\""))
        #expect(undo.contains("rm -rf \"$HOME/.codex/packages/standalone\"; rmdir \"$HOME/.codex/packages\""))
        #expect(undo.contains("*/.codex/packages/standalone/*) rm -f \"$p\""))
        #expect(undo.contains("rm -rf \"$HOME/.codex/tmp\"; rmdir \"$HOME/.codex\""))
        #expect(undo.contains("# >>> Codex installer >>>"))
        for script in scripts {
            #expect(!script.contains("rm -rf \"$HOME/.claude\""))
            #expect(!script.contains(".claude.json"))
            #expect(!script.contains("rm -rf \"$HOME/.codex\""))
            #expect(!script.contains("rm -rf \"$HOME/.t3\""))
            #expect(!script.contains("userdata"))
        }

        let plain = Recorder()
        try PoolJoin.removeLinuxClient(PoolLinuxClient(host: "laptop"), hubRoutes: [], run: plain.runner)
        let all = plain.commands.map(plainScript).joined(separator: "\n")
        #expect(!all.contains("service uninstall") && !all.contains("local/share/claude") && !all.contains("packages/standalone"))

        var codexOnly = PoolLinuxClient(host: "laptop")
        codexOnly.codexInstalled = true
        let partial = Recorder()
        try PoolJoin.removeLinuxClient(codexOnly, run: partial.runner)
        let text = partial.commands.map(plainScript).joined(separator: "\n")
        #expect(!text.contains("rmdir \"$HOME/.codex\"") && !text.contains("Codex installer") && !text.contains("local/share/claude"))
    }

    @Test func removesLingerWithThePassword() async throws {
        let secret = "hunter2-removed"
        var client = PoolLinuxClient(host: "laptop", linger: true)
        client.t3Installed = true
        let recorder = Recorder()
        let host = FakeClientHost(password: secret)
        recorder.respond = { command in
            if command.executable == "/usr/bin/ssh", remoteScript(command).contains("echo linger:stays") {
                return CommandResult(output: "linger:stays\n")
            }
            return host.answer(command) ?? CommandResult()
        }
        let removal = try PoolJoin.removeLinuxClient(client, hubRoutes: [], run: recorder.runner)
        #expect(removal.lingerStays)
        let steps = try #require(onLaptop(recorder).map(plainScript).last { $0.contains("disable-linger") })
        #expect(steps.contains("loginctl show-user \"$u\" -p Linger --value"))

        let asked = Asked()
        let off = await PoolJoin.releaseLinger(
            host: "laptop",
            ask: { wrong, why in
                asked.add(wrong, why)
                return secret
            }, run: recorder.runner)
        #expect(off)
        #expect(asked.calls.count == 1)
        let sudo = try #require(recorder.commands.last { plainScript($0).hasPrefix("sudo -S -p '' sh -c ") })
        #expect(plainScript(sudo).contains("loginctl disable-linger \"$SUDO_USER\""))
        #expect(sudo.stdin == Data((secret + "\n").utf8))
        for command in recorder.commands { #expect(!([command.executable] + command.arguments).joined(separator: " ").contains(secret)) }

        let refused = await PoolJoin.releaseLinger(host: "laptop", ask: { _, _ in nil }, run: recorder.runner)
        #expect(!refused)

        let quiet = Recorder()
        quiet.respond = { command in
            remoteScript(command).contains("echo linger:stays") ? CommandResult() : (host.answer(command) ?? CommandResult())
        }
        #expect(try !PoolJoin.removeLinuxClient(client, hubRoutes: [], run: quiet.runner).lingerStays)
    }

    private func runHere(_ command: Command, home: URL) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", plainScript(command)]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try? process.run()
        input.fileHandleForWriting.write(command.stdin ?? Data())
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    private func fileBacked(_ host: FakeClientHost, home: Fixture) -> Recorder {
        let recorder = Recorder()
        recorder.respond = { [self] command in
            guard command.executable == "/usr/bin/ssh" else { return host.answer(command) ?? CommandResult() }
            let text = remoteScript(command)
            let touches = [".claude/settings.json", ".claude/.credentials.json", ".codex/config.toml", ".codex/auth.json", "relaybar/kept"]
            if !text.contains("for d in"), touches.contains(where: text.contains) || text.contains("mkdir -p \"$HOME/.claude\"") {
                return runHere(command, home: home.root)
            }
            return host.answer(command) ?? CommandResult()
        }
        return recorder
    }

    private func tree(_ home: Fixture, _ folders: [String]) -> [String: Data] {
        var found: [String: Data] = [:]
        for folder in folders {
            let root = home.root.appendingPathComponent(folder)
            for path in (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [] {
                found["\(folder)/\(path)"] = try? Data(contentsOf: root.appendingPathComponent(path))
            }
        }
        return found
    }

    private func seedLogins(_ home: Fixture) throws {
        try home.write(
            ".claude/settings.json",
            "{\n  \"model\": \"sample-model\",\n  \"env\": {\"ANTHROPIC_AUTH_TOKEN\": \"old-token\", \"KEEP\": \"1\"}\n}\n")
        try home.write(".claude/.credentials.json", "{\"claudeAiOauth\": {\"accessToken\": \"sample\"}}")
        try home.write(".claude/rules/style.md", "style")
        try home.write(
            ".codex/config.toml",
            "model = \"sample\"\nmodel_provider = \"other\"\n\n[mcp_servers.x]\ncommand = \"x\"\n\n[model_providers.relaybar]\nname = \"old\"\n\n[model_providers.relaybar.auth]\ncommand = \"old\"\n\n[projects.p]\ntrust = \"trusted\"\n"
        )
        try home.write(".codex/auth.json", "{\"tokens\": {}}")
    }

    @Test func replacesTheLoginsAfterAsking() async throws {
        let home = try Fixture()
        try seedLogins(home)
        let host = FakeClientHost(probe: "new:.config/relaybar\nlinger:off\nlogin:claude\nlogin:codex\nt3:yes", settings: t3File)
        let recorder = fileBacked(host, home: home)
        let asked = Asked()
        let log = AddLog()
        var hooks = log.hooks
        hooks.replaceLogins = { name in
            asked.add(false, name)
            return true
        }
        let result = try await PoolJoin.linuxClient(
            host: "laptop", hub: "homebox", accessKey: secrets.accessKey, options: PoolAddOptions(t3Channel: nil), hooks: hooks,
            run: recorder.runner)
        #expect(asked.calls.map(\.why) == ["laptop"])
        #expect(result.replaced && !result.client.t3Entries)
        #expect(log.plan == [.letIn, .route, .commands, .logins])
        #expect(
            result.client.kept == [
                PoolKeptFile(path: ".claude/.credentials.json", existed: true, edited: false),
                PoolKeptFile(path: ".codex/auth.json", existed: true, edited: false),
                PoolKeptFile(path: ".claude/settings.json", existed: true, edited: true),
                PoolKeptFile(path: ".codex/config.toml", existed: true, edited: true),
            ])
        let kept = home.root.appendingPathComponent(".config/relaybar/kept")
        #expect(try FileManager.default.attributesOfItem(atPath: kept.path)[.posixPermissions] as? Int == 0o700)
        #expect(try String(contentsOf: kept.appendingPathComponent("claude-credentials.json"), encoding: .utf8).contains("accessToken"))
        #expect(try String(contentsOf: kept.appendingPathComponent("codex-auth.json"), encoding: .utf8) == "{\"tokens\": {}}")
        #expect(!FileManager.default.fileExists(atPath: home.root.appendingPathComponent(".claude/.credentials.json").path))
        #expect(!FileManager.default.fileExists(atPath: home.root.appendingPathComponent(".codex/auth.json").path))

        let settings = try home.json(".claude/settings.json")
        #expect(settings["model"] as? String == "sample-model")
        #expect(settings["apiKeyHelper"] as? String == "/bin/cat '/home/sam/.config/relaybar/access-key'")
        let env = try #require(settings["env"] as? [String: String])
        #expect(env == ["ANTHROPIC_BASE_URL": "http://127.0.0.1:8317", "KEEP": "1"])
        let config = try String(contentsOf: home.root.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        let sections = Self.sections(of: config)
        #expect(sections[""]?["model_provider"] == "\"relaybar\"" && sections[""]?["model"] == "\"sample\"")
        #expect(sections["mcp_servers.x"] == ["command": "\"x\""] && sections["projects.p"] == ["trust": "\"trusted\""])
        #expect(sections["model_providers.relaybar"]?["base_url"] == "\"http://127.0.0.1:8317/v1\"")
        #expect(sections["model_providers.relaybar"]?["name"] == "\"All accounts\"")
        #expect(
            sections["model_providers.relaybar.auth"] == ["command": "\"/bin/cat\"", "args": "[\"/home/sam/.config/relaybar/access-key\"]"])
        #expect(config.components(separatedBy: "[model_providers.relaybar]").count == 2)
        #expect(config.hasPrefix("model_provider = \"relaybar\"\n"))
        for text in [
            String(decoding: try Data(contentsOf: home.root.appendingPathComponent(".claude/settings.json")), as: UTF8.self), config,
        ] {
            #expect(!text.contains(secrets.accessKey))
        }
        for command in recorder.commands {
            #expect(!([command.executable] + command.arguments).joined(separator: " ").contains(secrets.accessKey))
        }
        let scripts = recorder.commands.map(plainScript)
        #expect(!scripts.contains { $0.contains(".local/bin/claude+") || $0.contains(".local/bin/codex+") })
        #expect(!recorder.commands.contains { remoteScript($0).contains(".t3/userdata/settings.json") && $0.stdin != nil })
        let backup = try #require(scripts.firstIndex { $0.contains("cp -p \"$f\" \"$HOME/.config/relaybar/kept/claude-settings.json\"") })
        let write = try #require(scripts.firstIndex { $0.contains("mv \"$t\" \"$f\"") && $0.contains(".claude/settings.json") })
        #expect(backup == write)

        let bare = try Fixture()
        let empty = fileBacked(FakeClientHost(probe: "new:.config/relaybar\nlinger:off"), home: bare)
        let silent = Asked()
        var quiet = AddLog().hooks
        quiet.replaceLogins = { name in
            silent.add(false, name)
            return false
        }
        let fresh = try await PoolJoin.linuxClient(
            host: "laptop", hub: "homebox", accessKey: secrets.accessKey, hooks: quiet, run: empty.runner)
        #expect(silent.calls.isEmpty && fresh.replaced)
        #expect(
            fresh.client.kept == [
                PoolKeptFile(path: ".claude/settings.json", existed: false, edited: true),
                PoolKeptFile(path: ".codex/config.toml", existed: false, edited: true),
            ])
        #expect(fresh.client.createdFolders == [])
        #expect(try bare.json(".claude/settings.json")["apiKeyHelper"] != nil)
    }

    static func sections(of toml: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = ["": [:]]
        var current = ""
        for line in toml.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if line.hasPrefix("[") {
                current = String(line.dropFirst().dropLast())
                result[current] = result[current] ?? [:]
            } else if let equals = line.firstIndex(of: "=") {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                result[current]?[key] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    @Test func keepsTheLoginsWhenAsked() async throws {
        let home = try Fixture()
        try seedLogins(home)
        let before = tree(home, [".claude", ".codex"])
        let host = FakeClientHost(probe: "new:.config/relaybar\nlinger:off\nlogin:claude\nlogin:codex\nt3:yes", settings: t3File)
        let recorder = fileBacked(host, home: home)
        let asked = Asked()
        let log = AddLog()
        var hooks = log.hooks
        hooks.replaceLogins = { name in
            asked.add(false, name)
            return false
        }
        let result = try await PoolJoin.linuxClient(
            host: "laptop", hub: "homebox", accessKey: secrets.accessKey, hooks: hooks, run: recorder.runner)
        #expect(asked.calls.count == 1 && !result.replaced && result.client.kept.isEmpty)
        #expect(log.plan == [.letIn, .route, .commands])
        #expect(tree(home, [".claude", ".codex"]) == before)
        #expect(!FileManager.default.fileExists(atPath: home.root.appendingPathComponent(".config/relaybar/kept").path))
        let scripts = recorder.commands.map(plainScript)
        #expect(scripts.contains { $0.contains(".local/bin/claude+") } && scripts.contains { $0.contains(".local/bin/codex+") })
        #expect(result.client.t3Entries)

        for (blocked, why) in [("link:.claude/settings.json", "a link"), ("login:claude", "bad json")] {
            let other = try Fixture()
            try seedLogins(other)
            if why == "bad json" { try other.write(".claude/settings.json", "{ not json") }
            let probe = "new:.config/relaybar\nlinger:off\nlogin:claude\n" + blocked
            let guarded = fileBacked(FakeClientHost(probe: probe), home: other)
            let silent = Asked()
            var quiet = AddLog().hooks
            quiet.replaceLogins = { name in
                silent.add(true, name)
                return true
            }
            let kept = try await PoolJoin.linuxClient(
                host: "laptop", hub: "homebox", accessKey: secrets.accessKey, hooks: quiet, run: guarded.runner)
            #expect(!kept.replaced, "\(why)")
            #expect(silent.calls.isEmpty, "\(why)")
            #expect(guarded.commands.map(plainScript).contains { $0.contains(".local/bin/claude+") }, "\(why)")
        }
    }

    @Test func removePutsTheLoginsBack() async throws {
        let home = try Fixture()
        try seedLogins(home)
        let before = tree(home, [".claude", ".codex"])
        let host = FakeClientHost(probe: "new:.config/relaybar\nlinger:off\nlogin:claude\nlogin:codex\nclaudedir:new")
        let recorder = fileBacked(host, home: home)
        var hooks = AddLog().hooks
        hooks.replaceLogins = { _ in true }
        let result = try await PoolJoin.linuxClient(
            host: "laptop", hub: "homebox", accessKey: secrets.accessKey, hooks: hooks, run: recorder.runner)
        #expect(tree(home, [".claude", ".codex"]) != before)
        let restore = try #require(PoolReplace.restoreScript(result.client.kept, createdFolders: result.client.createdFolders))
        let removal = Recorder()
        removal.respond = { _ in CommandResult() }
        try PoolJoin.removeLinuxClient(result.client, hubRoutes: [], run: removal.runner)
        let undo = try #require(onLaptop(removal).map(plainScript).last { $0.contains("relaybar-tunnel.service") })
        #expect(undo.hasPrefix(restore))
        let command = try #require(onLaptop(removal).first { plainScript($0).hasPrefix(restore) })
        let ran = runHere(command, home: home.root)
        #expect(ran.status == 0)
        #expect(tree(home, [".claude", ".codex"]) == before)
        #expect(!FileManager.default.fileExists(atPath: home.root.appendingPathComponent(".config/relaybar/kept").path))

        let fresh = try Fixture()
        let created = fileBacked(FakeClientHost(probe: "new:.config/relaybar\nlinger:off\nclaudedir:new\ncodexdir:new"), home: fresh)
        let bare = try await PoolJoin.linuxClient(
            host: "laptop", hub: "homebox", accessKey: secrets.accessKey, hooks: hooks, run: created.runner)
        #expect(bare.client.createdFolders == [".claude", ".codex"])
        let undoFresh = try #require(PoolReplace.restoreScript(bare.client.kept, createdFolders: bare.client.createdFolders))
        let last = Recorder()
        try PoolJoin.removeLinuxClient(bare.client, hubRoutes: [], run: last.runner)
        let again = try #require(onLaptop(last).first { plainScript($0).hasPrefix(undoFresh) })
        _ = runHere(again, home: fresh.root)
        #expect(!FileManager.default.fileExists(atPath: fresh.root.appendingPathComponent(".claude").path))
        #expect(!FileManager.default.fileExists(atPath: fresh.root.appendingPathComponent(".codex").path))

        let edited = try Fixture()
        try edited.write(".codex/auth.json", "new login")
        let mine = PoolKeptFile(path: ".codex/auth.json", existed: true, edited: false)
        let kept = edited.root.appendingPathComponent(".config/relaybar/kept/codex-auth.json")
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old login".utf8).write(to: kept)
        let script = try #require(PoolReplace.restoreScript([mine], createdFolders: []))
        _ = runHere(Command("/usr/bin/ssh", ["-o", "x", "laptop", "--", "sh -c " + Shell.quote(script)]), home: edited.root)
        #expect(try String(contentsOf: edited.root.appendingPathComponent(".codex/auth.json"), encoding: .utf8) == "new login")
    }

    @Test func removesAnEarlierBuildsSetup() async throws {
        let old = PoolLinuxClient(host: "laptop", folders: [".claude-hub", ".codex-hub", ".config/relaybar"], linger: false)
        let recorder = Recorder()
        try PoolJoin.removeLinuxClient(old, hubRoutes: [], run: recorder.runner)
        let script = try #require(onLaptop(recorder).map(plainScript).last { $0.contains("relaybar-tunnel.service") })
        #expect(script.contains("for f in claude+ codex+ claude-all codex-all; do"))
        #expect(script.contains("f=\"$HOME/.codex-hub/config.toml\"; grep -q '\(PoolFile.marker)' \"$f\" 2>/dev/null && rm -f \"$f\""))
        for folder in [".claude-hub", ".codex-hub", ".config/relaybar"] {
            #expect(script.contains("rmdir \"$HOME/\(folder)\" 2>/dev/null"))
        }
        let fresh = PoolLinuxClient(host: "laptop", folders: [".config/relaybar"])
        let current = Recorder()
        try PoolJoin.removeLinuxClient(fresh, hubRoutes: [], run: current.runner)
        let text = try #require(onLaptop(current).map(plainScript).last { $0.contains("relaybar-tunnel.service") })
        #expect(!text.contains("rmdir \"$HOME/.claude-hub\""))
    }

    @Test func neverRemovesTailscale() async throws {
        var client = PoolLinuxClient(host: "laptop")
        client.tailscaleInstalled = true
        client.t3Installed = true
        client.t3Service = true
        client.claudeInstalled = true
        let recorder = Recorder()
        try PoolJoin.removeLinuxClient(client, hubRoutes: ["homebox"], run: recorder.runner)
        let everything = recorder.commands.map {
            ($0.arguments + [String(decoding: $0.stdin ?? Data(), as: UTF8.self)]).joined(separator: " ")
        }
        #expect(!everything.contains { $0.lowercased().contains("tailscale") })
        #expect(
            PoolJoin.removalNote(client)
                == "Relaybar removes what it installed there: T3 Code and Claude Code. Your chats and Tailscale stay.")
    }

    @Test func overridesInstallAddressesOnlyWithSafeOnes() {
        let name = "RELAYBAR_TEST_OVERRIDE_URL"
        defer { unsetenv(name) }
        for (value, expected) in [
            ("https://example.com/install.sh", "https://example.com/install.sh"),
            ("file:///tmp/e2e/install.sh", "file:///tmp/e2e/install.sh"),
            ("http://example.com/install.sh", nil), ("https://example.com/a b", nil), ("https://example.com/'x", nil),
            ("https://example.com/$(x)", nil), ("ftp://example.com/x", nil), ("https://example.com/a;rm", nil),
            ("https://example.com/a|sh", nil), ("https://example.com/a&b", nil), ("https://example.com/<x", nil),
            ("https://example.com/x>", nil), ("https://example.com/(x)", nil), ("https://example.com/a\u{7}b", nil),
        ] as [(String, String?)] {
            setenv(name, value, 1)
            #expect(Pool.overriddenURL(name) == expected, "\(value)")
        }
        unsetenv(name)
        #expect(Pool.overriddenURL(name) == nil)
        #expect(PoolInstallSite.claude.url == "https://claude.ai/install.sh")
        #expect(PoolInstallSite.codex.url == "https://chatgpt.com/codex/install.sh")
        #expect(PoolTailscaleComputer.installURL == "https://tailscale.com/install.sh")
    }
}

final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    func next() -> Int {
        lock.withLock {
            total += 1
            return total
        }
    }

    var count: Int { lock.withLock { total } }
}

final class Guesses: @unchecked Sendable {
    private let lock = NSLock()
    private var rest: [String]

    init(_ values: [String]) { rest = values }

    func next() -> String? { lock.withLock { rest.isEmpty ? nil : rest.removeFirst() } }
}

final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String] = []

    func add(_ item: String) { lock.withLock { kept.append(item) } }

    func count(_ item: String) -> Int { lock.withLock { kept.filter { $0 == item }.count } }

    var items: [String] { lock.withLock { kept } }
}

final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    func set(_ action: @escaping @Sendable () -> Void) { lock.withLock { self.action = action } }

    var isSet: Bool { lock.withLock { action != nil } }

    func cancel() { lock.withLock { action }?() }
}

final class Watch: @unchecked Sendable {
    enum Attempt {
        case confirms(Int)
        case gone(Int)
        case never
    }

    private let lock = NSLock()
    private let attempts: [Attempt]
    private var pairs = 0
    private var polls = 0

    init(_ attempts: [Attempt]) { self.attempts = attempts }

    func pairStarted() {
        lock.withLock {
            pairs += 1
            polls = 0
        }
    }

    func sessions() -> String {
        lock.withLock {
            guard pairs > 0 else { return "[]" }
            polls += 1
            if case .confirms(let after) = attempts[pairs - 1], polls >= after {
                return #"[{"sessionId":"s-\#(pairs)","method":"one-time-token","client":{"label":"Relaybar"}}]"#
            }
            return "[]"
        }
    }

    func pairings() -> String {
        lock.withLock {
            guard pairs > 0 else { return "[]" }
            if case .gone(let after) = attempts[pairs - 1], polls >= after { return "[]" }
            return #"[{"id":"p\#(pairs)","label":"Relaybar"}]"#
        }
    }
}
