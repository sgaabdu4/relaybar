import Foundation
import Testing

@testable import RelaybarCore

struct PoolTeardownTests {
    private func state(
        _ steps: [PoolStep], ssh: String? = nil, previous: String? = nil, folders: [String] = [], keepOn: PoolKeepOn = PoolKeepOn(),
        joined: Bool = false, harness: Harness
    ) throws {
        var state = PoolState(ssh: ssh, joined: joined)
        state.steps = steps
        state.previousSelection = previous
        state.hubFolders = folders
        state.keepOn = keepOn
        try state.save(harness.paths)
    }

    @Test func undoesOnlyRecordedSteps() throws {
        let harness = try Harness()
        try harness.home.write(".local/bin/claude-all", "#!/bin/sh\n# \(PoolFile.marker).\n")
        try harness.home.folder(".claude-hub")
        try harness.home.write("Library/Application Support/Relaybar/Helper/config.yaml", "x")
        try harness.home.write("Library/LaunchAgents/com.relaybar.helper.plist", "x")
        try harness.home.write("Library/LaunchAgents/com.relaybar.helper-update.plist", "x")
        try harness.home.write(".t3/userdata/settings.json", #"{"providerInstances": {}}"#)
        try state([.keychainAccessKey, .helperAgent], harness: harness)
        let report = PoolTeardown.run(harness.env())
        #expect(report.undone == [.helperAgent, .keychainAccessKey])
        #expect(report.finished)
        let ran = harness.recorder.commands.map { $0.executable + " " + $0.arguments.joined(separator: " ") }
        #expect(
            ran == [
                "/bin/launchctl bootout gui/501/com.relaybar.helper", "/usr/bin/security delete-generic-password -s Relaybar access key",
            ])
        #expect(!FileManager.default.fileExists(atPath: harness.paths.agent(Pool.helperLabel).path))
        #expect(FileManager.default.fileExists(atPath: harness.paths.agent(Pool.updateLabel).path))
        #expect(FileManager.default.fileExists(atPath: harness.paths.claudeAll.path))
        #expect(FileManager.default.fileExists(atPath: harness.paths.claudeHub.path))
        #expect(FileManager.default.fileExists(atPath: harness.paths.config.path))
        #expect(harness.trashed.urls.isEmpty)
        #expect(PoolState.load(harness.paths) == nil)
    }

    @Test func removesTheTunnel() throws {
        let harness = try Harness()
        try harness.home.write("Library/LaunchAgents/com.relaybar.helper-tunnel.plist", "x")
        try harness.home.write("Library/LaunchAgents/com.relaybar.helper.plist", "x")
        try state([.tunnelAgent], ssh: "homebox", harness: harness)
        let report = PoolTeardown.run(harness.env())
        #expect(report.undone == [.tunnelAgent])
        #expect(harness.recorder.ran("/bin/launchctl", containing: "bootout gui/501/com.relaybar.helper-tunnel"))
        #expect(!FileManager.default.fileExists(atPath: harness.paths.agent(Pool.tunnelLabel).path))
        #expect(FileManager.default.fileExists(atPath: harness.paths.agent(Pool.helperLabel).path))
    }

    @Test func undoesEverythingInReverseAndRestoresTheDefault() throws {
        let harness = try Harness()
        let t3 = T3Settings(home: harness.home.root)
        try harness.home.write(
            ".t3/userdata/settings.json",
            #"{"defaultModelSelection": {"instanceId": "codex", "model": "m"}, "favorites": [{"provider": "claudeAgent", "model": "cm"}], "providerInstances": {}}"#
        )
        try t3.addPoolEntries(
            accessKey: "k", claudeHome: harness.paths.claudeHub.path, codexHome: harness.paths.codexHub.path, hex: "#32ade6")
        guard case .set(let previous) = try t3.setPoolDefault() else {
            Issue.record("the default did not change")
            return
        }
        _ = try t3.addUsageSource(url: "http://127.0.0.1:8317", managementSecret: "s", alreadyAdded: false)
        try harness.home.folder(".claude-hub")
        try harness.home.folder(".codex-hub")
        try harness.home.write(".local/bin/claude-all", "#!/bin/sh\n# \(PoolFile.marker).\n")
        try harness.home.write(".local/bin/codex-all", "mine\n")
        try harness.home.write("Library/Application Support/Relaybar/Helper/auth/x.json", "{}")
        try harness.home.write("Library/Application Support/Relaybar/relaybar-helper.sh", "x")
        try harness.home.write("Library/LaunchAgents/com.relaybar.helper-update.plist", "x")
        let all: [PoolStep] = [
            .keychainAccessKey, .keychainManagementSecret, .helperFolder, .helperAgent, .updateAgent, .hubFolders, .terminalCommands,
            .t3Entries, .t3Default, .t3UsageSource,
        ]
        try state(all, previous: previous, folders: [".claude-hub", ".codex-hub"], harness: harness)
        let seen = Seen()
        let report = PoolTeardown.run(harness.env(), progress: { seen.steps.append($0) })
        #expect(seen.steps == all.reversed())
        #expect(report.undone == all.reversed())
        #expect(PoolState.load(harness.paths) == nil)
        let settings = try harness.home.json(".t3/userdata/settings.json")
        #expect(settings["defaultModelSelection"] as? [String: String] == ["instanceId": "codex", "model": "m"])
        #expect((settings["providerInstances"] as? [String: Any])?.isEmpty == true)
        #expect((settings["usageLimitSources"] as? [String: Any])?.isEmpty == true)
        #expect(Set(harness.trashed.urls.map(\.lastPathComponent)) == [".claude-hub", ".codex-hub"])
        #expect(!FileManager.default.fileExists(atPath: harness.paths.claudeAll.path))
        #expect(FileManager.default.fileExists(atPath: harness.paths.codexAll.path))
        #expect(!FileManager.default.fileExists(atPath: harness.paths.helper.path))
        #expect(!FileManager.default.fileExists(atPath: harness.paths.updateScript.path))
        #expect(harness.recorder.ran("/usr/bin/security", containing: "Relaybar management secret"))
    }

    @Test func aSecondRunFinishesAHalfDoneStop() throws {
        let harness = try Harness()
        try harness.home.folder(".claude-hub")
        try state([.helperAgent, .hubFolders], folders: [".claude-hub"], harness: harness)
        let failing = Failing()
        let env = PoolEnvironment(
            home: harness.home.root, uid: 501, run: harness.recorder.runner, http: harness.http.client,
            trash: { _ in
                if failing.on { throw CocoaError(.fileWriteNoPermission) }
            }, script: nil, t3Installed: false)
        failing.on = true
        let first = PoolTeardown.run(env)
        #expect(first.undone == [.helperAgent])
        #expect(first.failed.map(\.step) == [.hubFolders])
        #expect(first != PoolTeardownReport())
        #expect(!first.finished)
        #expect(PoolState.load(harness.paths)?.steps == [.hubFolders])
        failing.on = false
        let second = PoolTeardown.run(env)
        #expect(second.finished)
        #expect(second.undone == [.hubFolders])
        #expect(PoolTeardown.run(env) == PoolTeardownReport())
    }

    @Test func stopsAHelperOnAHomeComputer() throws {
        let harness = try Harness()
        try state([.remoteHelper], ssh: "homebox", harness: harness)
        let report = PoolTeardown.run(harness.env())
        #expect(report.finished)
        let command = try #require(harness.recorder.commands.first)
        let text = remoteScript(command)
        #expect(command.arguments.contains("homebox"))
        #expect(text.contains("systemctl --user disable --now \"$u\""))
        #expect(text.contains("rm -rf \"$HOME/.local/share/relaybar-helper\""))
        try state([.remoteHelper], ssh: "homebox", harness: harness)
        harness.recorder.respond = { _ in CommandResult(status: 255, error: "Connection refused") }
        let failed = PoolTeardown.run(harness.env())
        #expect(failed.failed.first?.reason.contains("refused the connection") == true)
        #expect(PoolState.load(harness.paths)?.steps == [.remoteHelper])
        try state([.remoteHelper], harness: harness)
        #expect(PoolTeardown.run(harness.env()).finished)
    }
}

extension PoolTeardownTests {
    @Test func stopsEachHomeComputerUnitOnItsOwn() {
        let script = PoolTeardown.remoteRemoval
        let stop = script.components(separatedBy: "; done;").first ?? ""
        #expect(stop.hasPrefix("for u in relaybar-helper.service relaybar-helper-update.timer relaybar-tunnel.service; do "))
        #expect(stop.contains("systemctl --user disable --now \"$u\""))
        #expect(script.components(separatedBy: "disable --now").count == 2)
        let stopAt = script.range(of: "done;")?.upperBound
        let removeAt = script.range(of: "rm -f")?.lowerBound
        let reloadAt = script.range(of: "daemon-reload")?.lowerBound
        let foldersAt = script.range(of: "rm -rf")?.lowerBound
        #expect(stopAt != nil && removeAt != nil && reloadAt != nil && foldersAt != nil)
        #expect(stopAt! <= removeAt! && removeAt! < reloadAt! && reloadAt! < foldersAt!)
    }

    @Test func keepsAHubFolderTheUserHad() throws {
        let harness = try Harness()
        try harness.home.folder(".claude-hub")
        try harness.home.folder(".codex-hub")
        try state([.hubFolders], folders: [".codex-hub"], harness: harness)
        #expect(PoolTeardown.run(harness.env()).finished)
        #expect(harness.trashed.urls.map(\.lastPathComponent) == [".codex-hub"])
        #expect(FileManager.default.fileExists(atPath: harness.paths.claudeHub.path))
        #expect(!FileManager.default.fileExists(atPath: harness.paths.codexHub.path))
    }

    @Test func neverRemovesAHubItDidNotCreate() async throws {
        let harness = try Harness()
        let up = Flag()
        let secrets = PoolSecrets(accessKey: String(repeating: "a1", count: 32), managementSecret: String(repeating: "b2", count: 32))
        let join = #"{"accessKey":"\#(secrets.accessKey)","managementSecret":"\#(secrets.managementSecret)"}"#
        harness.recorder.respond = { command in
            if command.executable == "/usr/bin/ssh" { return CommandResult(output: join) }
            if command.arguments.first == "bootstrap" { up.on = true }
            return CommandResult()
        }
        harness.http.handler = joinedHelper(up: up, secrets: secrets)
        let setup = PoolSetup(env: harness.env(t3: false))
        try await setup.join(host: "homebox")
        let before = harness.recorder.commands.count
        #expect(setup.stop().finished)
        let after = harness.recorder.commands.dropFirst(before)
        #expect(!after.contains { $0.executable == "/usr/bin/ssh" })
        #expect(!harness.recorder.commands.contains { remoteScript($0).contains("rm -rf") })
        harness.recorder.respond = { command in
            remoteScript(command).contains("mkdir -m 700") ? CommandResult(output: "exists") : CommandResult(output: "000")
        }
        harness.http.handler = { _ in nil }
        await #expect(throws: PoolSetupError.self) { _ = try await PoolSetup(env: harness.env(t3: false)).combineOnHome(host: "homebox") }
        #expect(!harness.recorder.commands.contains { remoteScript($0).contains("rm -rf") })
        #expect(PoolState.load(harness.paths) == nil)
    }

    @Test func canForgetAnUnreachableHomeComputer() throws {
        let harness = try Harness()
        try harness.home.write("Library/LaunchAgents/com.relaybar.helper-tunnel.plist", "x")
        try state([.tunnelAgent, .remoteHelper, .keepOn], ssh: "homebox", keepOn: PoolKeepOn(linger: true), harness: harness)
        harness.recorder.respond = { _ in CommandResult(status: 255, error: "ssh: connect to host homebox port 22: Operation timed out") }
        let first = PoolTeardown.run(harness.env())
        #expect(first.undone == [.tunnelAgent])
        #expect(first.failed.map(\.step) == [.keepOn, .remoteHelper])
        #expect(first.unreachable == "homebox")
        #expect(!first.finished)
        #expect(PoolState.load(harness.paths)?.steps == [.remoteHelper, .keepOn])
        #expect(!FileManager.default.fileExists(atPath: harness.paths.agent(Pool.tunnelLabel).path))
        let calls = harness.recorder.commands.count
        let forgotten = PoolTeardown.forgetRemote(harness.env())
        #expect(forgotten.finished)
        #expect(PoolState.load(harness.paths) == nil)
        #expect(harness.recorder.commands.count == calls)
        #expect(PoolTeardown.forgetRemote(harness.env()) == PoolTeardownReport())
        try state([.helperAgent, .remoteHelper], ssh: "homebox", harness: harness)
        harness.recorder.respond = { _ in CommandResult(status: 255, error: "Connection refused") }
        let partial = PoolTeardown.forgetRemote(harness.env())
        #expect(partial.undone == [.helperAgent])
        #expect(PoolState.load(harness.paths) == nil)
    }

    @Test func undoesKeepOnChanges() throws {
        let harness = try Harness()
        try state(
            [.keepOn], ssh: "homebox", keepOn: PoolKeepOn(linger: true, masked: ["sleep.target", "suspend.target"]), harness: harness)
        #expect(PoolTeardown.run(harness.env()).finished)
        let script = remoteScript(try #require(harness.recorder.commands.first))
        #expect(script.contains("sudo -n systemctl unmask sleep.target suspend.target"))
        #expect(!script.contains("hibernate"))
        #expect(script.contains("loginctl disable-linger \"$u\""))
        try state([.keepOn], ssh: "homebox", keepOn: PoolKeepOn(masked: ["sleep.target"]), harness: harness)
        #expect(PoolTeardown.run(harness.env()).finished)
        #expect(!remoteScript(try #require(harness.recorder.commands.last)).contains("disable-linger"))
        try state([.keepOn], ssh: "homebox", keepOn: PoolKeepOn(linger: true, masked: ["sleep.target"]), harness: harness)
        harness.recorder.respond = { command in
            command.stdin == nil
                ? CommandResult(status: PoolRemote.needsPasswordStatus, error: "sudo: a password is required") : CommandResult()
        }
        let asked = PoolTeardown.run(harness.env())
        #expect(asked.needsPassword == "homebox")
        #expect(asked.failed.map(\.step) == [.keepOn])
        #expect(PoolState.load(harness.paths)?.steps == [.keepOn])
        let withPassword = PoolTeardown.run(harness.env(), sudoPassword: "pw")
        #expect(withPassword.finished)
        let last = try #require(harness.recorder.commands.last)
        #expect(last.stdin == Data("pw\n".utf8))
        #expect(!last.arguments.joined(separator: " ").contains("pw"))
        #expect(remoteScript(last).contains("sudo -S -p"))
        try state([.keepOn], ssh: "homebox", keepOn: PoolKeepOn(linger: true), harness: harness)
        harness.recorder.respond = { _ in CommandResult(status: 255, error: "Connection refused") }
        let down = PoolTeardown.run(harness.env())
        #expect(down.needsPassword == nil)
        #expect(down.failed.first?.reason.contains("refused the connection") == true)
        #expect(PoolKeepOnError.needsPassword("h").errorDescription?.contains("password") == true)
    }

    @Test func emptyKeepOnAndOtherRemoteStepsDoNothingWithoutAHost() throws {
        let harness = try Harness()
        try state([.keepOn, .remoteHelper, .linuxClient], harness: harness)
        let report = PoolTeardown.run(harness.env())
        #expect(report.finished)
        #expect(harness.recorder.commands.isEmpty)
    }
}

extension PoolTeardownTests {
    private func combined(_ harness: Harness, computers: [String]) async throws -> PoolSetup {
        harness.answerHomeAndComputers()
        let setup = PoolSetup(env: harness.env())
        _ = try await setup.combineOnHome(host: "homebox")
        for computer in computers { try setup.useOnLinux(host: computer) }
        return setup
    }

    private func down(_ harness: Harness, _ hosts: String...) {
        let base = harness.recorder.respond
        harness.recorder.respond = { command in
            hosts.contains { command.arguments.contains($0) } ? CommandResult(status: 255, error: "Connection refused") : base(command)
        }
    }

    @Test func stopKeepsGoingWhenAComputerIsOffline() async throws {
        let harness = try Harness()
        let setup = try await combined(harness, computers: ["laptop", "desktop"])
        let working = harness.recorder.respond
        down(harness, "laptop")
        let first = setup.stop()
        #expect(first.unreachableComputers == ["laptop"])
        #expect(first.failed.map(\.step) == [.linuxClient])
        #expect(first.undone.contains(.remoteHelper))
        let kept = try #require(PoolState.load(harness.paths))
        #expect(kept.linuxClients.map(\.host) == ["laptop"])
        #expect(kept.steps.contains(.linuxClient))
        let sent = harness.recorder.commands.filter { $0.arguments.contains("desktop") }.map(remoteScript)
        #expect(sent.contains { $0.contains("rmdir") })
        harness.recorder.respond = working
        let second = setup.stop()
        #expect(second.finished)
        #expect(second.unreachableComputers.isEmpty)
        #expect(PoolState.load(harness.paths) == nil)
    }

    @Test func forgettingAnOfflineComputerStillRemovesItsKeyFromTheHub() async throws {
        let harness = try Harness()
        let setup = try await combined(harness, computers: ["laptop"])
        down(harness, "laptop")
        #expect(throws: PoolSSHError.self) { try setup.removeComputer(host: "laptop") }
        #expect(PoolState.load(harness.paths)?.linuxClients.map(\.host) == ["laptop"])
        let mark = harness.recorder.commands.count
        let forgotten = try setup.forgetComputer(host: "laptop")
        #expect(forgotten.hubKeyProblem == nil)
        let sent = Array(harness.recorder.commands.dropFirst(mark))
        #expect(sent.count == 1)
        let drop = plainScript(try #require(sent.first))
        #expect(sent.first?.arguments.contains("homebox") == true)
        #expect(drop.contains("awk -v t=' relaybar-client:laptop'"))
        let state = try #require(PoolState.load(harness.paths))
        #expect(state.linuxClients.isEmpty)
        #expect(!state.steps.contains(.linuxClient))
        #expect(try setup.forgetComputer(host: "laptop") == PoolClientRemoval())
        #expect(setup.stop().finished)
    }

    @Test func forgettingStillWorksWhenTheHubIsDownToo() async throws {
        let harness = try Harness()
        let setup = try await combined(harness, computers: ["laptop"])
        down(harness, "laptop", "homebox")
        let forgotten = try setup.forgetComputer(host: "laptop")
        #expect(forgotten.hubKeyProblem?.contains("refused the connection") == true)
        #expect(PoolState.load(harness.paths)?.linuxClients.isEmpty == true)
    }

    @Test func aJoinedMacWhoseHubIsGoneStillFinishesStop() throws {
        let harness = try Harness()
        try harness.home.write("Library/LaunchAgents/com.relaybar.helper-tunnel.plist", "x")
        var client = PoolLinuxClient(host: "laptop", folders: [".codex-hub"])
        client.hubKey = true
        var joined = PoolState(ssh: "homebox", joined: true)
        joined.steps = [.tunnelAgent, .linuxClient]
        joined.linuxClients = [client]
        try joined.save(harness.paths)
        down(harness, "homebox")
        let report = PoolTeardown.run(harness.env())
        #expect(report.finished)
        #expect(report.keysLeft == ["laptop"])
        #expect(report.undone.contains(.linuxClient))
        #expect(harness.recorder.commands.contains { $0.arguments.contains("laptop") && remoteScript($0).contains("rmdir") })
        #expect(PoolState.load(harness.paths) == nil)
    }
}

final class Seen: @unchecked Sendable {
    var steps: [PoolStep] = []
}

final class Failing: @unchecked Sendable {
    var on = false
}
