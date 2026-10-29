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
            remoteScript($0).contains(".local/bin/claude-all") || remoteScript($0).contains(".local/bin/codex-all")
        }
        let claude = try #require(launchers.first { remoteScript($0).contains("claude-all") })
        let codex = try #require(launchers.first { remoteScript($0).contains("codex-all") })
        #expect(String(decoding: claude.stdin ?? Data(), as: UTF8.self).contains("exec \"$HOME/.local/bin/claude\" \"$@\""))
        #expect(String(decoding: codex.stdin ?? Data(), as: UTF8.self).contains("exec \"$HOME/.local/bin/codex\" \"$@\""))
        let push = try #require(onLaptop(recorder).last { remoteScript($0).contains("relaybar-new") })
        let settings = try #require(try JSONSerialization.jsonObject(with: push.stdin ?? Data()) as? [String: Any])
        let instances = try #require(settings["providerInstances"] as? [String: [String: Any]])
        #expect((instances["claudeAgent_all_accounts"]?["config"] as? [String: String])?["binaryPath"] == "/home/sam/.local/bin/claude")
        #expect((instances["codex_all_accounts"]?["config"] as? [String: String])?["binaryPath"] == "/home/sam/.local/bin/codex")
        let probe = try #require(onLaptop(recorder).map(plainScript).first { $0.contains("for d in") })
        #expect(probe.contains("PATH=\"$HOME/.local/bin:$PATH\" command -v $t"))

        let plain = Recorder()
        clientHost(plain, FakeClientHost(probe: FakeClientHost.probe + "\nt3:yes", settings: t3File))
        _ = try await add(plain)
        let bare = try #require(plain.commands.first { remoteScript($0).contains("claude-all") && $0.stdin != nil })
        #expect(String(decoding: bare.stdin ?? Data(), as: UTF8.self).contains("exec claude \"$@\""))
        let bareSettings = try #require(plain.commands.last { remoteScript($0).contains("relaybar-new") })
        #expect(!String(decoding: bareSettings.stdin ?? Data(), as: UTF8.self).contains("binaryPath"))
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
        #expect(probe.contains("[ -n \"$p\" ] || p=$(\"${SHELL:-sh}\" -lc \"command -v $t\" </dev/null 2>/dev/null | grep '^/' | tail -n 1)"))
        let order = try #require(probe.range(of: "-lc")).lowerBound
        let needs = try #require(probe.range(of: "echo need:$t")).lowerBound
        #expect(order < needs)
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
        let refused = try await add(
            wrong, options: PoolAddOptions(t3Channel: .stable), hooks: PoolAddHooks(pair: { opens.add($0) }))
        #expect(refused.t3LinkMissing)
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
        #expect(client.t3LinkMissing)
        #expect(client.t3Installed && client.t3Service && client.t3Entries)
        #expect(asked.calls.map(\.why) == ["laptop"])
        #expect(opens.urls.isEmpty)
        let sent = harness.recorder.commands.map(plainScript)
        #expect(!sent.contains { $0.contains("service uninstall") || $0.contains("rm -f \"$HOME/.local/bin/claude\"") })
        let saved = try #require(PoolState.load(harness.paths)?.linuxClients.first)
        #expect(saved == client)
        #expect(saved.hubKey)
        let log = AddLog()
        let quiet = Recorder()
        let (failing, _) = failingPair(FakeClientHost(), times: 9)
        quiet.respond = failing.respond
        let plain = try await PoolJoin.linuxClient(
            host: "laptop", hub: "homebox", accessKey: secrets.accessKey, options: PoolAddOptions(t3Channel: .stable),
            hooks: PoolAddHooks(plan: log.hooks.plan, report: log.hooks.report), run: quiet.runner)
        #expect(plain.t3LinkMissing)
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
        #expect(!client.t3LinkMissing)
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

    @Test func asksForThePasswordOnce() async throws {
        let secret = "hunter2-added"
        let signedOut = "RB-MISSING\n"
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
        #expect(asked.calls.first?.why == "install Tailscale")
        #expect(opened.urls.map(\.absoluteString) == ["https://login.tailscale.com/a/1a2b3c4d5e6f"])
        let withPassword = recorder.commands.filter { $0.stdin == Data((secret + "\n").utf8) }
        #expect(withPassword.count >= 2)
        for command in recorder.commands {
            #expect(!([command.executable] + command.arguments).joined(separator: " ").contains(secret))
            if command.stdin == Data((secret + "\n").utf8) { #expect(plainScript(command).hasPrefix("sudo -S -p '' sh -c ")) }
        }
        #expect(client.tailscaleInstalled)

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
        #expect(refusal == .needsPassword(host: "laptop", why: "install Tailscale"))
        #expect(
            refusal?.errorDescription
                == "Relaybar needs the password for laptop to install Tailscale. It did not get it, so it removed what it had set up. Try again when you have it."
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
        #expect(failed == .rootStepFailed(host: "laptop", why: "install Tailscale", reason: "curl: (6) Could not resolve host: pkgs.example.com"))
        let text = try #require(failed?.errorDescription)
        #expect(text.hasPrefix("Relaybar could not install Tailscale on laptop: curl: (6)"))
        #expect(!text.contains("administrator") && !text.contains("sudo"))

        for refusal in ["sam is not in the sudoers file.  This incident will be reported.\n", "Sorry, user sam may not run sudo on laptop.\n"] {
            let denied = await run(refusal)
            #expect(denied?.errorDescription?.contains("administrator rights (sudo)") == true)
        }
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
            host: "laptop", ask: { wrong, why in asked.add(wrong, why); return secret }, run: recorder.runner)
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
            ("https://example.com/$(x)", nil), ("ftp://example.com/x", nil),
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
