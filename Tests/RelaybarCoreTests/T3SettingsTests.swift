import Foundation
import Testing

@testable import RelaybarCore

struct T3SettingsTests {
    private let settingsPath = ".t3/userdata/settings.json"

    private func seeded() throws -> (Fixture, T3Settings) {
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
