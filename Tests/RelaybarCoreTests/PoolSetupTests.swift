import Foundation
import Testing

@testable import RelaybarCore

struct PoolSetupTests {
    private let t3Path = ".t3/userdata/settings.json"

    private func seeded() throws -> Harness {
        let harness = try Harness()
        try harness.home.write(
            t3Path,
            #"{"theme": "dark", "defaultModelSelection": {"instanceId": "claudeAgent", "model": "m"}, "providerInstances": {}}"#)
        return harness
    }

    private func helperLifecycle(_ harness: Harness, failInstall: Bool = false) {
        let up = Flag()
        let recorder = harness.recorder
        let paths = harness.paths
        recorder.respond = { command in
            if command.executable == "/usr/bin/security", command.arguments == ["find-generic-password", "-s", Pool.accessService, "-w"] {
                return CommandResult(output: "ignored")
            }
            if command.executable == "/bin/sh", command.arguments.dropFirst().first == "install" {
                if failInstall { return CommandResult(status: 1, error: "failed: cannot download CLIProxyAPI\n") }
                up.on = true
            }
            _ = paths
            return CommandResult()
        }
        harness.http.handler = { request in
            guard request.url.path == "/v1/models", up.on else { return nil }
            return HTTPResponse(status: request.headers["Authorization"] == nil ? 401 : 200)
        }
    }

    @Test func combinesOnThisMac() async throws {
        let harness = try seeded()
        helperLifecycle(harness)
        let steps = Messages()
        try await PoolSetup(env: harness.env()).combineOnThisMac(progress: { steps.texts.append($0) })
        let state = try #require(PoolState.load(harness.paths))
        #expect(state.runsOnThisMac)
        #expect(
            state.steps == [
                .keychainAccessKey, .keychainManagementSecret, .helperFolder, .helperAgent, .updateAgent, .hubFolders, .terminalCommands,
                .t3Entries, .t3Default, .t3UsageSource,
            ])
        #expect(state.previousSelection == #"{"instanceId":"claudeAgent","model":"m"}"#)
        #expect(state.hubFolders == [".claude-hub", ".codex-hub"])
        #expect(!state.defaultKept)
        #expect(state.usageSourceAdded)
        let config = try String(contentsOf: harness.paths.config, encoding: .utf8)
        #expect(config.contains("host: \"127.0.0.1\""))
        #expect(try FileManager.default.attributesOfItem(atPath: harness.paths.config.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: harness.paths.helper.path)[.posixPermissions] as? Int == 0o700)
        #expect(try String(contentsOf: harness.paths.updateScript, encoding: .utf8) == String(decoding: harness.script, as: UTF8.self))
        #expect(FileManager.default.fileExists(atPath: harness.paths.sandbox.path))
        #expect(FileManager.default.fileExists(atPath: harness.paths.agent(Pool.helperLabel).path))
        #expect(FileManager.default.fileExists(atPath: harness.paths.agent(Pool.updateLabel).path))
        #expect(PoolFile.isOwned(harness.paths.codexConfig))
        #expect(try FileManager.default.attributesOfItem(atPath: harness.paths.claudeAll.path)[.posixPermissions] as? Int == 0o755)
        let settings = try harness.home.json(t3Path)
        #expect((settings["defaultModelSelection"] as? [String: String])?["instanceId"] == "claudeAgent_all_accounts")
        #expect((settings["usageLimitSources"] as? [String: Any])?.keys.sorted() == ["relaybar"])
        #expect(harness.recorder.ran("/bin/launchctl", containing: "bootstrap gui/501"))
        #expect(steps.texts.first == "Saving the keys in the Keychain")
        let stored = harness.recorder.commands.filter { $0.arguments == ["-i"] }
        #expect(stored.count == 2)
    }

    @Test func stopsWhatItCombined() async throws {
        let harness = try seeded()
        helperLifecycle(harness)
        let setup = PoolSetup(env: harness.env())
        try await setup.combineOnThisMac()
        let report = setup.stop()
        #expect(report.finished)
        #expect(PoolState.load(harness.paths) == nil)
        let settings = try harness.home.json(t3Path)
        #expect((settings["defaultModelSelection"] as? [String: String])?["instanceId"] == "claudeAgent")
        #expect((settings["providerInstances"] as? [String: Any])?.isEmpty == true)
        #expect(settings["theme"] as? String == "dark")
        #expect(!FileManager.default.fileExists(atPath: harness.paths.helper.path))
        #expect(!FileManager.default.fileExists(atPath: harness.paths.claudeAll.path))
        #expect(Set(harness.trashed.urls.map(\.lastPathComponent)) == [".claude-hub", ".codex-hub"])
    }

    @Test func skipsT3WhenItIsNotInstalled() async throws {
        let harness = try seeded()
        helperLifecycle(harness)
        try await PoolSetup(env: harness.env(t3: false)).combineOnThisMac()
        let state = try #require(PoolState.load(harness.paths))
        #expect(!state.steps.contains(.t3Entries))
        #expect((try harness.home.json(t3Path)["providerInstances"] as? [String: Any])?.isEmpty == true)
    }

    @Test func rollsBackWhenTheDownloadFails() async throws {
        let harness = try seeded()
        helperLifecycle(harness, failInstall: true)
        await #expect(throws: PoolInstallError.failed("cannot download CLIProxyAPI")) {
            try await PoolSetup(env: harness.env()).combineOnThisMac()
        }
        #expect(PoolState.load(harness.paths) == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.helper.path))
        #expect(!FileManager.default.fileExists(atPath: harness.paths.agent(Pool.helperLabel).path))
        #expect(harness.recorder.ran("/usr/bin/security", containing: "delete-generic-password -s Relaybar access key"))
    }

    @Test func rollsBackWhenTheHelperNeverAnswers() async throws {
        let harness = try seeded()
        helperLifecycle(harness)
        harness.http.handler = { _ in nil }
        await #expect(throws: PoolSetupError.notAnswering) { try await PoolSetup(env: harness.env()).combineOnThisMac() }
        #expect(PoolState.load(harness.paths) == nil)
    }

    @Test func refusesWithoutTheInstallerOrOnAConflict() async throws {
        let harness = try seeded()
        await #expect(throws: PoolSetupError.missingScript) { try await PoolSetup(env: harness.env(script: false)).combineOnThisMac() }
        try harness.home.write("Library/Application Support/Relaybar/Helper/config.yaml", "mine")
        await #expect(throws: PoolSetupError.self) { try await PoolSetup(env: harness.env()).combineOnThisMac() }
        #expect(PoolState.load(harness.paths) == nil)
        #expect(try String(contentsOf: harness.paths.config, encoding: .utf8) == "mine")
        for error in [PoolSetupError.missingScript, .keychain, .notAnswering, .conflict(.portInUse(8317))] {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test func rollsBackWhenTheKeychainRefuses() async throws {
        let harness = try seeded()
        harness.recorder.respond = { command in command.arguments == ["-i"] ? CommandResult(status: 1) : CommandResult() }
        await #expect(throws: PoolSetupError.keychain) { try await PoolSetup(env: harness.env()).combineOnThisMac() }
        #expect(PoolState.load(harness.paths) == nil)
    }

    @Test func rollsBackWhenTheKeychainReturnsAnotherValue() async throws {
        let harness = try seeded()
        helperLifecycle(harness)
        harness.recorder.remembersKeys = false
        await #expect(throws: PoolSetupError.keychain) { try await PoolSetup(env: harness.env()).combineOnThisMac() }
        #expect(PoolState.load(harness.paths) == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.helper.path))
        #expect(harness.recorder.ran("/usr/bin/security", containing: "delete-generic-password -s Relaybar access key"))
    }

    @Test func combinesOnAHomeComputer() async throws {
        let harness = try seeded()
        let up = Flag()
        let recorder = harness.recorder
        recorder.respond = { command in
            let text = command.executable == "/usr/bin/ssh" ? remoteScript(command) : ""
            if text.contains("printf %s \"$HOME\"") { return CommandResult(output: "/home/sam") }
            if text.contains("join.json\" ]") { return CommandResult(output: "000") }
            if text.contains("mkdir -m 700") { return CommandResult(output: "claimed") }
            if text.contains("sudo -n") { return CommandResult(status: 1) }
            if command.executable == "/bin/launchctl", command.arguments.first == "bootstrap" { up.on = true }
            return CommandResult()
        }
        harness.http.handler = { request in
            guard request.url.path == "/v1/models", up.on else { return nil }
            return HTTPResponse(status: request.headers["Authorization"] == nil ? 401 : 200)
        }
        let setup = PoolSetup(env: harness.env())
        let sleep = try await setup.combineOnHome(host: "homebox")
        #expect(sleep == .needsPassword)
        let state = try #require(PoolState.load(harness.paths))
        #expect(state.ssh == "homebox")
        #expect(state.steps.starts(with: [.keychainAccessKey, .keychainManagementSecret, .remoteHelper, .tunnelAgent]))
        #expect(FileManager.default.fileExists(atPath: harness.paths.agent(Pool.tunnelLabel).path))
        #expect(!FileManager.default.fileExists(atPath: harness.paths.helper.path))
        #expect(setup.stop().finished)
        #expect(recorder.commands.contains { remoteScript($0).contains("rm -rf \"$HOME/.local/share/relaybar-helper\"") })
    }

    @Test func refusesAHomeComputerThatIsTaken() async throws {
        let harness = try seeded()
        harness.recorder.respond = { _ in CommandResult(output: "folder") }
        await #expect(throws: PoolSetupError.self) { _ = try await PoolSetup(env: harness.env()).combineOnHome(host: "homebox") }
        harness.recorder.respond = { _ in CommandResult(output: "401") }
        await #expect(throws: PoolSetupError.conflict(.portInUse(8317))) {
            _ = try await PoolSetup(env: harness.env()).combineOnHome(host: "homebox")
        }
        harness.recorder.respond = { _ in CommandResult(output: "000") }
        harness.http.handler = { _ in HTTPResponse(status: 401) }
        await #expect(throws: PoolSetupError.conflict(.portInUse(8317))) {
            _ = try await PoolSetup(env: harness.env()).combineOnHome(host: "homebox")
        }
        harness.recorder.respond = { command in
            remoteScript(command).contains("mkdir -m 700") ? CommandResult(output: "exists") : CommandResult(output: "000")
        }
        harness.http.handler = { _ in nil }
        await #expect(throws: PoolSetupError.conflict(.foreignHelperFolder("homebox:.local/share/relaybar-helper"))) {
            _ = try await PoolSetup(env: harness.env()).combineOnHome(host: "homebox")
        }
        #expect(!harness.recorder.commands.contains { remoteScript($0).contains("rm -rf") })
        await #expect(throws: PoolInputError.self) { _ = try await PoolSetup(env: harness.env()).combineOnHome(host: "-x") }
        await #expect(throws: PoolSetupError.missingScript) {
            _ = try await PoolSetup(env: harness.env(script: false)).combineOnHome(host: "homebox")
        }
        #expect(PoolState.load(harness.paths) == nil)
    }

    @Test func joinsAnExistingHubInsteadOfReplacingIt() async throws {
        let harness = try seeded()
        let up = Flag()
        let secrets = PoolSecrets(accessKey: String(repeating: "a1", count: 32), managementSecret: String(repeating: "b2", count: 32))
        let join = String(
            decoding: try JSONSerialization.data(withJSONObject: [
                "accessKey": secrets.accessKey, "managementSecret": secrets.managementSecret,
            ]),
            as: UTF8.self)
        harness.recorder.respond = { command in
            let text = command.executable == "/usr/bin/ssh" ? remoteScript(command) : ""
            if text.contains("join.json\" ]") { return CommandResult(output: "ours") }
            if text.contains("cat \"$HOME/.local/share/relaybar-helper/join.json\"") { return CommandResult(output: join) }
            if command.executable == "/bin/launchctl", command.arguments.first == "bootstrap" { up.on = true }
            return CommandResult()
        }
        harness.http.handler = joinedHelper(up: up, secrets: secrets)
        let setup = PoolSetup(env: harness.env())
        #expect(try setup.homeStatus(host: "homebox") == .relaybarHub)
        await #expect(throws: PoolSetupError.hubExists("homebox")) { _ = try await setup.combineOnHome(host: "homebox") }
        let ssh = harness.recorder.commands.filter { $0.executable == "/usr/bin/ssh" }
        #expect(!ssh.contains { remoteScript($0).contains(" install ") || $0.stdin != nil })
        #expect(!ssh.contains { remoteScript($0).contains("mkdir") || remoteScript($0).contains("rm -rf") })
        #expect(PoolState.load(harness.paths) == nil)
        try await setup.join(host: "homebox")
        let state = try #require(PoolState.load(harness.paths))
        #expect(state.joined)
        #expect(!state.steps.contains(.remoteHelper))
        #expect(state.steps.contains(.tunnelAgent))
        #expect(PoolSetupError.hubExists("homebox").errorDescription?.contains("homebox already combines accounts") == true)
    }

    @Test func recordsWhatKeepOnChanged() async throws {
        let harness = try seeded()
        let up = Flag()
        harness.recorder.respond = { command in
            let text = command.executable == "/usr/bin/ssh" ? remoteScript(command) : ""
            if text.contains("printf %s \"$HOME\"") { return CommandResult(output: "/home/sam") }
            if text.contains("join.json\" ]") { return CommandResult(output: "000") }
            if text.contains("mkdir -m 700") { return CommandResult(output: "claimed") }
            if text.contains("lingerNeeded") { return CommandResult(output: "changed:linger\nchanged:sleep.target\n") }
            if command.executable == "/bin/launchctl", command.arguments.first == "bootstrap" { up.on = true }
            return CommandResult()
        }
        harness.http.handler = { request in
            guard request.url.path == "/v1/models", up.on else { return nil }
            return HTTPResponse(status: request.headers["Authorization"] == nil ? 401 : 200)
        }
        let setup = PoolSetup(env: harness.env())
        let sleep = try await setup.combineOnHome(host: "homebox")
        #expect(sleep == .off)
        let state = try #require(PoolState.load(harness.paths))
        #expect(state.keepOn == PoolKeepOn(linger: true, masked: ["sleep.target"]))
        #expect(state.steps.contains(.keepOn))
        #expect(setup.keepOn(password: "pw") == .off)
        #expect(PoolState.load(harness.paths)?.keepOn == PoolKeepOn(linger: true, masked: ["sleep.target"]))
        let report = setup.stop()
        #expect(report.finished)
        let restore = harness.recorder.commands.map(remoteScript).first { $0.contains("systemctl unmask sleep.target") }
        #expect(restore?.contains("loginctl disable-linger") == true)
        #expect(PoolState.load(harness.paths) == nil)
        #expect(setup.keepOn(password: "pw") == nil)
    }

    @Test func stopsBeforeTouchingAnythingWhenT3SettingsAreUnreadable() async throws {
        let harness = try seeded()
        helperLifecycle(harness)
        try harness.home.write(t3Path, "{ not json")
        await #expect(throws: T3SettingsError.unreadable) { try await PoolSetup(env: harness.env()).combineOnThisMac() }
        await #expect(throws: T3SettingsError.unreadable) {
            _ = try await PoolSetup(env: harness.env()).combineOnHome(host: "homebox")
        }
        await #expect(throws: T3SettingsError.unreadable) { try await PoolSetup(env: harness.env()).join(host: "homebox") }
        #expect(harness.recorder.commands.isEmpty)
        #expect(PoolState.load(harness.paths) == nil)
        #expect(try String(contentsOf: harness.home.root.appendingPathComponent(t3Path), encoding: .utf8) == "{ not json")
        try await PoolSetup(env: harness.env(t3: false)).combineOnThisMac()
    }

    @Test func doesNotRecordAHubFolderTheUserHad() async throws {
        let harness = try seeded()
        helperLifecycle(harness)
        try harness.home.folder(".claude-hub")
        let setup = PoolSetup(env: harness.env())
        try await setup.combineOnThisMac()
        #expect(PoolState.load(harness.paths)?.hubFolders == [".codex-hub"])
        #expect(setup.stop().finished)
        #expect(harness.trashed.urls.map(\.lastPathComponent) == [".codex-hub"])
        #expect(FileManager.default.fileExists(atPath: harness.paths.claudeHub.path))
    }

    @Test func readsTheKeysBackFromTheKeychain() throws {
        let harness = try Harness()
        harness.recorder.respond = { command in CommandResult(output: command.arguments.contains(Pool.accessService) ? "key\n" : "secret\n")
        }
        let setup = PoolSetup(env: harness.env())
        #expect(setup.accessKey() == "key")
        #expect(setup.management != nil)
        harness.recorder.respond = { _ in CommandResult(status: 44) }
        #expect(setup.management == nil)
    }

    @Test func refreshesTheUpdateScriptAfterAnAppUpdate() async throws {
        let harness = try seeded()
        helperLifecycle(harness)
        try await PoolSetup(env: harness.env()).combineOnThisMac()
        let setup = PoolSetup(env: harness.env())
        #expect(try !setup.refreshUpdateScript())
        try Data("old".utf8).write(to: harness.paths.updateScript)
        #expect(try setup.refreshUpdateScript())
        #expect(try Data(contentsOf: harness.paths.updateScript) == harness.script)
        #expect(try !PoolSetup(env: harness.env(script: false)).refreshUpdateScript())
        var joined = try #require(PoolState.load(harness.paths))
        joined.joined = true
        try joined.save(harness.paths)
        #expect(try !setup.refreshUpdateScript())
        var remote = joined
        remote.joined = false
        remote.ssh = "homebox"
        try remote.save(harness.paths)
        harness.recorder.respond = { _ in CommandResult() }
        #expect(try setup.refreshUpdateScript())
        #expect(harness.recorder.commands.last?.stdin == harness.script)
    }

    @Test func doesNotAddTheUsageSourceTwice() async throws {
        let harness = try seeded()
        helperLifecycle(harness)
        var existing = PoolState()
        existing.usageSourceAdded = true
        try existing.save(harness.paths)
        try await PoolSetup(env: harness.env()).combineOnThisMac()
        let state = try #require(PoolState.load(harness.paths))
        #expect(!state.steps.contains(.t3UsageSource))
    }
}

final class Messages: @unchecked Sendable {
    var texts: [String] = []
}
