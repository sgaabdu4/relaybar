import Foundation
import Testing

@testable import RelaybarCore

struct PoolStateTests {
    private let older = """
        {
          "defaultKept": false,
          "hubFolders": [],
          "joined": false,
          "keepOn": {"linger": true, "masked": ["sleep.target"]},
          "linuxClients": [{"folders": [".codex-hub", ".config/relaybar"], "host": "laptop", "linger": true}],
          "order": {},
          "ssh": "homebox",
          "steps": ["keychainAccessKey", "remoteHelper", "linuxClient"],
          "usageSourceAdded": false
        }
        """

    @Test func readsAnOlderStateFile() throws {
        let harness = try Harness()
        try harness.home.write("Library/Application Support/Relaybar/pool.json", older)
        let state = try #require(PoolState.load(harness.paths))
        #expect(state.ssh == "homebox")
        #expect(state.steps == [.keychainAccessKey, .remoteHelper, .linuxClient])
        #expect(state.linuxClients == [PoolLinuxClient(host: "laptop", folders: [".codex-hub", ".config/relaybar"], linger: true)])
        let client = try #require(state.linuxClients.first)
        #expect(!client.hubKey)
        #expect(client.hubCreated.isEmpty)
        #expect(!client.t3Entries)
        #expect(client.previousSelection == nil)
        #expect(!client.claudeInstalled && !client.codexInstalled && !client.codexProfile && !client.codexFolder)
        #expect(
            !client.t3Installed && !client.t3Service && client.t3Host == nil && !client.tailscaleInstalled && client.t3Session == nil
                && client.t3Binary == nil)
        #expect(state.orderMode == .automatic)
        var manual = state
        manual.orderMode = .manual
        try manual.save(harness.paths)
        #expect(PoolState.load(harness.paths)?.orderMode == .manual)
        try harness.home.write(
            "Library/Application Support/Relaybar/pool.json",
            older.replacingOccurrences(of: "\"order\": {},", with: "\"orderMode\": \"sideways\","))
        #expect(PoolState.load(harness.paths)?.orderMode == .automatic)
        var newer = state
        newer.linuxClients[0].hubKey = true
        newer.linuxClients[0].t3Secrets = ["provider-env-x"]
        newer.linuxClients[0].t3Installed = true
        newer.linuxClients[0].t3Host = "100.64.0.9"
        try newer.save(harness.paths)
        #expect(PoolState.load(harness.paths) == newer)
    }
}
