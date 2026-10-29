import Foundation
import Testing

@testable import RelaybarCore

struct T3SettingsTests {
    let settingsPath = ".t3/userdata/settings.json"

    func seeded() throws -> (Fixture, T3Settings) {
        let home = try Fixture()
        try home.write(
            settingsPath,
            """
            {
              "theme": "dark",
              "favorites": [{"provider": "claudeAgent", "model": "m1"}, {"provider": "claudeAgent_old", "model": "m1"}],
              "providerModelPreferences": {"claudeAgent_old": {"hiddenModels": ["m2"]}, "codex": {"hiddenModels": []}},
              "defaultModelSelection": {"instanceId": "claudeAgent_old", "model": "m1"},
              "textGenerationModelSelection": {"instanceId": "codex", "model": "m3"},
              "providerInstances": {
                "claudeAgent_old": {"driver": "claudeAgent", "displayName": "Old", "enabled": false, "config": {"homePath": "/h/.claude-old"}},
                "claudeAgent_keep": {"driver": "claudeAgent", "displayName": "Keep", "config": {"homePath": "/h/.claude-keep"}}
              }
            }
            """)
        return (home, T3Settings(home: home.root))
    }

    @Test func addsANewAccount() throws {
        let (home, settings) = try seeded()
        try settings.add(claude: false, name: "Client Work", hex: "#34c759", homePath: "/h/.codex-client-work")
        let instances = try home.json(settingsPath)["providerInstances"] as? [String: [String: Any]]
        let entry = try #require(instances?["codex_client_work"])
        #expect(entry["driver"] as? String == "codex")
        #expect(entry["displayName"] as? String == "Client Work")
        #expect(entry["accentColor"] as? String == "#34c759")
        #expect(entry["enabled"] as? Bool == true)
        #expect((entry["config"] as? [String: String])?["homePath"] == "/h/.codex-client-work")
        #expect(settings.contains(homePath: "/h/.codex-client-work"))
        #expect(FileManager.default.fileExists(atPath: home.root.appendingPathComponent(settingsPath + ".relaybar-backup").path))
    }

    @Test func readdingSwitchesAnOldEntryBackOn() throws {
        let (home, settings) = try seeded()
        try settings.add(claude: true, name: "Old", hex: "#ffffff", homePath: "/h/.claude-old")
        let instances = try home.json(settingsPath)["providerInstances"] as? [String: [String: Any]]
        #expect(instances?.count == 2)
        #expect(instances?["claudeAgent_old"]?["enabled"] as? Bool == true)
    }

    @Test func removingCleansEveryReference() throws {
        let (home, settings) = try seeded()
        try settings.remove(homePath: "/h/.claude-old")
        let root = try home.json(settingsPath)
        #expect((root["providerInstances"] as? [String: Any])?.keys.sorted() == ["claudeAgent_keep"])
        #expect((root["favorites"] as? [[String: String]])?.map { $0["provider"] } == ["claudeAgent"])
        #expect((root["providerModelPreferences"] as? [String: Any])?.keys.sorted() == ["codex"])
        #expect((root["defaultModelSelection"] as? [String: String])?["instanceId"] == "claudeAgent")
        #expect((root["textGenerationModelSelection"] as? [String: String])?["instanceId"] == "codex")
        #expect(root["theme"] as? String == "dark")
        #expect(!settings.contains(homePath: "/h/.claude-old"))
    }

    @Test func removingAnUnknownAccountChangesNothing() throws {
        let (home, settings) = try seeded()
        let before = try Data(contentsOf: home.root.appendingPathComponent(settingsPath))
        try settings.remove(homePath: "/h/.claude-missing")
        #expect(try Data(contentsOf: home.root.appendingPathComponent(settingsPath)) == before)
    }
}

extension T3SettingsTests {
    private func secretNames(_ home: Fixture) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: home.root.appendingPathComponent(".t3/userdata/secrets").path)) ?? [])
            .sorted()
    }

    @Test func addsPoolEntriesWithSensitiveEnvironment() throws {
        let (home, settings) = try seeded()
        try settings.addPoolEntries(accessKey: "k-123", claudeHome: "/h/.claude-hub", codexHome: "/h/.codex-hub", hex: "#32ade6")
        let root = try home.json(settingsPath)
        let instances = try #require(root["providerInstances"] as? [String: [String: Any]])
        #expect(instances.keys.sorted() == ["claudeAgent_all_accounts", "claudeAgent_keep", "claudeAgent_old", "codex_all_accounts"])
        let claude = try #require(instances["claudeAgent_all_accounts"])
        #expect(claude["driver"] as? String == "claudeAgent")
        #expect(claude["displayName"] as? String == "Claude, all accounts")
        #expect((claude["config"] as? [String: String])?["homePath"] == "/h/.claude-hub")
        let environment = try #require(claude["environment"] as? [[String: Any]])
        #expect(environment[0]["name"] as? String == "ANTHROPIC_BASE_URL")
        #expect(environment[0]["value"] as? String == "http://127.0.0.1:8317")
        #expect(environment[0]["sensitive"] as? Bool == false)
        #expect(environment[1]["name"] as? String == "ANTHROPIC_AUTH_TOKEN")
        #expect(environment[1]["value"] as? String == "")
        #expect(environment[1]["sensitive"] as? Bool == true)
        #expect(environment[1]["valueRedacted"] as? Bool == true)
        let codex = try #require(instances["codex_all_accounts"])
        #expect(codex["displayName"] as? String == "Codex, all accounts")
        let config = try #require(codex["config"] as? [String: String])
        #expect(config["homePath"] == "/h/.codex-hub")
        #expect(config["setupMode"] == "existing")
        let name = "provider-env-" + T3Settings.encode("claudeAgent_all_accounts") + "-" + T3Settings.encode("ANTHROPIC_AUTH_TOKEN")
        #expect(secretNames(home) == [name + ".bin"])
        let file = settings.secretFile(name)
        #expect(try String(contentsOf: file, encoding: .utf8) == "k-123")
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(root["theme"] as? String == "dark")
        try settings.removePoolEntries()
        let after = try home.json(settingsPath)["providerInstances"] as? [String: Any]
        #expect(after?.keys.sorted() == ["claudeAgent_keep", "claudeAgent_old"])
        #expect(secretNames(home).isEmpty)
    }

    @Test func backupHasNoPoolKey() throws {
        let (home, settings) = try seeded()
        try settings.addPoolEntries(accessKey: "plain-key-xyz", claudeHome: "/h/.claude-hub", codexHome: "/h/.codex-hub", hex: "#32ade6")
        _ = try settings.setPoolDefault()
        _ = try settings.addUsageSource(url: "http://127.0.0.1:8317", managementSecret: "plain-secret-xyz", alreadyAdded: false)
        for name in ["", ".relaybar-backup"] {
            let text = try String(contentsOf: home.root.appendingPathComponent(settingsPath + name), encoding: .utf8)
            #expect(!text.contains("plain-key-xyz"))
            #expect(!text.contains("plain-secret-xyz"))
        }
        #expect(secretNames(home).count == 2)
    }

    @Test func setsAndRestoresTheDefault() throws {
        let (home, settings) = try seeded()
        guard case .set(let previous) = try settings.setPoolDefault() else {
            Issue.record("the default did not change")
            return
        }
        #expect(previous == #"{"instanceId":"claudeAgent_old","model":"m1"}"#)
        let selection = try home.json(settingsPath)["defaultModelSelection"] as? [String: String]
        #expect(selection?["instanceId"] == "claudeAgent_all_accounts")
        #expect(selection?["model"] == "m1")
        #expect(try settings.setPoolDefault() == .alreadyPool)
        try settings.restoreDefault(to: previous)
        #expect(
            try home.json(settingsPath)["defaultModelSelection"] as? [String: String] == ["instanceId": "claudeAgent_old", "model": "m1"])
        _ = try settings.setPoolDefault()
        let changed = try String(contentsOf: home.root.appendingPathComponent(settingsPath), encoding: .utf8)
            .replacingOccurrences(of: "claudeAgent_all_accounts\"", with: "claudeAgent_keep\"")
        try home.write(settingsPath, changed)
        try settings.restoreDefault(to: previous)
        #expect((try home.json(settingsPath)["defaultModelSelection"] as? [String: String])?["instanceId"] == "claudeAgent_keep")
    }

    @Test func poolDefaultUsesAClaudeModel() throws {
        let home = try Fixture()
        let settings = T3Settings(home: home.root)
        let codexDefault =
            #"{"instanceId": "codex", "model": "gpt-x", "options": [{"id": "effort", "value": "high"}]}"#
        func seed(favorites: String, preferences: String, selection: String?) throws {
            let chosen = selection.map { "\"defaultModelSelection\": \($0)," } ?? ""
            try home.write(
                settingsPath,
                """
                {\(chosen) "favorites": \(favorites), "providerModelPreferences": \(preferences),
                 "providerInstances": {"claudeAgent_work": {"driver": "claudeAgent", "config": {"homePath": "/h"}}}}
                """)
        }
        func selection() throws -> [String: Any]? { try home.json(settingsPath)["defaultModelSelection"] as? [String: Any] }

        try seed(
            favorites:
                #"[{"provider": "codex", "model": "g1"}, {"provider": "claudeAgent_work", "model": "claude-w"}, {"provider": "claudeAgent", "model": "claude-a"}]"#,
            preferences: "{}", selection: codexDefault)
        guard case .set(let previous) = try settings.setPoolDefault() else {
            Issue.record("the default did not change")
            return
        }
        let chosen = try #require(try selection())
        #expect(chosen["instanceId"] as? String == "claudeAgent_all_accounts")
        #expect(chosen["model"] as? String == "claude-w")
        #expect(chosen["options"] == nil)
        try settings.restoreDefault(to: previous)
        let back = try #require(try selection())
        #expect(back["instanceId"] as? String == "codex")
        #expect(back["model"] as? String == "gpt-x")
        #expect((back["options"] as? [[String: String]])?.first?["value"] == "high")

        try seed(
            favorites: #"[{"provider": "codex", "model": "g1"}]"#,
            preferences: #"{"codex": {"modelOrder": ["g2"]}, "claudeAgent": {"modelOrder": ["", "claude-order"]}}"#, selection: codexDefault
        )
        _ = try settings.setPoolDefault()
        #expect(try selection()?["model"] as? String == "claude-order")

        try seed(favorites: #"[{"provider": "codex", "model": "g1"}]"#, preferences: "{}", selection: codexDefault)
        let before = try Data(contentsOf: home.root.appendingPathComponent(settingsPath))
        #expect(try settings.setPoolDefault() == .kept)
        #expect(try Data(contentsOf: home.root.appendingPathComponent(settingsPath)) == before)

        try seed(favorites: #"[{"provider": "claudeAgent", "model": "claude-a"}]"#, preferences: "{}", selection: nil)
        #expect(try settings.setPoolDefault() == .set(previous: nil))
        #expect(try selection() as? [String: String] == ["instanceId": "claudeAgent_all_accounts", "model": "claude-a"])
        try settings.restoreDefault(to: nil)
        #expect(try selection() == nil)
    }

    @Test func leavesTheDefaultAloneWhenThereIsNone() throws {
        let home = try Fixture()
        let settings = T3Settings(home: home.root)
        #expect(try settings.setPoolDefault() == .kept)
        #expect(!FileManager.default.fileExists(atPath: home.root.appendingPathComponent(settingsPath).path))
    }

    @Test func refusesToRewriteAnUnreadableFile() throws {
        let home = try Fixture()
        let text = "{ // my notes\n \"theme\": \"dark\", }"
        try home.write(settingsPath, text)
        let settings = T3Settings(home: home.root)
        let file = home.root.appendingPathComponent(settingsPath)
        #expect(throws: T3SettingsError.unreadable) { try settings.validate() }
        #expect(throws: T3SettingsError.unreadable) {
            try settings.addPoolEntries(accessKey: "k", claudeHome: "/h/.claude-hub", codexHome: "/h/.codex-hub", hex: "#32ade6")
        }
        #expect(throws: T3SettingsError.unreadable) { _ = try settings.setPoolDefault() }
        #expect(throws: T3SettingsError.unreadable) {
            _ = try settings.addUsageSource(url: "u", managementSecret: "s", alreadyAdded: false)
        }
        #expect(throws: T3SettingsError.unreadable) { try settings.removePoolEntries() }
        #expect(throws: T3SettingsError.unreadable) { try settings.removeUsageSource() }
        #expect(throws: T3SettingsError.unreadable) { try settings.restoreDefault(to: nil) }
        #expect(throws: T3SettingsError.unreadable) { try settings.add(claude: true, name: "A", hex: "#fff", homePath: "/h") }
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
        #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("relaybar-backup").path))
        #expect(secretNames(home).isEmpty)
        #expect(!settings.contains(homePath: "/h"))
        #expect(T3SettingsError.unreadable.errorDescription?.contains("settings.json") == true)
    }

    @Test func keepsTheFirstBackupOfAFlow() throws {
        let (home, _) = try seeded()
        let file = home.root.appendingPathComponent(settingsPath)
        let original = try String(contentsOf: file, encoding: .utf8)
        let flow = T3Flow()
        let settings = T3Settings(home: home.root, flow: flow)
        try settings.addPoolEntries(accessKey: "k", claudeHome: "/h/.claude-hub", codexHome: "/h/.codex-hub", hex: "#32ade6")
        _ = try settings.setPoolDefault()
        _ = try settings.addUsageSource(url: "u", managementSecret: "s", alreadyAdded: false)
        let backup = file.appendingPathExtension("relaybar-backup")
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        let next = T3Settings(home: home.root, flow: T3Flow())
        try next.removeUsageSource()
        #expect(try String(contentsOf: backup, encoding: .utf8) != original)
    }

    @Test func addsTheUsageSourceOnce() throws {
        let (home, settings) = try seeded()
        #expect(try settings.addUsageSource(url: "http://127.0.0.1:8317", managementSecret: "s1", alreadyAdded: false))
        #expect(try !settings.addUsageSource(url: "http://127.0.0.1:8317", managementSecret: "s2", alreadyAdded: false))
        let sources = try #require(home.json(settingsPath)["usageLimitSources"] as? [String: [String: Any]])
        #expect(sources.keys.sorted() == ["relaybar"])
        let source = try #require(sources["relaybar"])
        #expect(source["kind"] as? String == "cliproxy")
        #expect(source["label"] as? String == "All accounts")
        #expect(source["url"] as? String == "http://127.0.0.1:8317")
        #expect(source["managementKey"] as? String == "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
        #expect(source["enabled"] as? Bool == true)
        let file = settings.secretFile("usage-limit-source-" + T3Settings.encode("relaybar"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "s1")
        try settings.removeUsageSource()
        #expect(try !settings.addUsageSource(url: "http://127.0.0.1:8317", managementSecret: "s3", alreadyAdded: true))
        #expect(try home.json(settingsPath)["usageLimitSources"] == nil)
    }

    @Test func stopRemovesTheUsageSource() throws {
        let (home, settings) = try seeded()
        _ = try settings.addUsageSource(url: "http://127.0.0.1:8317", managementSecret: "s1", alreadyAdded: false)
        try settings.removeUsageSource()
        #expect(try home.json(settingsPath)["usageLimitSources"] == nil)
        #expect(secretNames(home).isEmpty)
        try settings.removeUsageSource()
    }

    @Test func encodesNamesWithoutPadding() {
        #expect(T3Settings.encode("a") == "YQ")
        #expect(T3Settings.encode("???>>>") == "Pz8_Pj4-")
    }
}
