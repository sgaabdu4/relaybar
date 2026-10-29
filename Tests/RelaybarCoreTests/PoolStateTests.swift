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
        var newer = state
        newer.linuxClients[0].hubKey = true
        newer.linuxClients[0].t3Secrets = ["provider-env-x"]
        try newer.save(harness.paths)
        #expect(PoolState.load(harness.paths) == newer)
    }
}
