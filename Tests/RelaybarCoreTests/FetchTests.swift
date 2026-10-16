import Foundation
import Testing

@testable import RelaybarCore

struct FetchTests {
    @Test func newClaudeAccountWithoutLoginIsWaitingNotExpired() async {
        #expect(await Fetch.claude(service: "Claude Code-credentials-relaybar-test-\(UUID().uuidString)") == .failed)
    }

    @Test func codexWithoutTokenIsWaitingNotExpired() async throws {
        let home = try Fixture()
        try home.write("auth.json", #"{"tokens": {}}"#)
        #expect(await Fetch.codex(authFile: home.root.appendingPathComponent("auth.json")) == .failed)
    }

    @Test func readsTheNewestCodexSessionInAFolder() throws {
        let home = try Fixture()
        let line = { (used: Int) in #"{"payload": {"rate_limits": {"primary": {"used_percent": \#(used), "window_minutes": 10080}}}}"# }
        try home.write("day/old.jsonl", line(10))
        try home.write("day/new.jsonl", line(42))
        try home.write("day/notes.txt", line(99))
        let old = home.root.appendingPathComponent("day/old.jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: old.path)
        #expect(
            Fetch.newestCodexLog(in: home.root.appendingPathComponent("day")) == .ok(session: nil, weekly: Window(used: 42, resetsAt: nil)))
    }

    @Test func longCodexLogReadsTheNewestLimits() throws {
        let home = try Fixture()
        let filler = String(
            repeating: #"{"payload": {"type": "message", "text": "\#(String(repeating: "x", count: 200))"}}"# + "\n", count: 500)
        let latest = #"{"payload": {"rate_limits": {"limit_id": "codex", "primary": {"used_percent": 42, "window_minutes": 10080}}}}"#
        try home.write("session.jsonl", filler + latest + "\n")
        #expect(
            Fetch.codexLog(home.root.appendingPathComponent("session.jsonl")) == .ok(session: nil, weekly: Window(used: 42, resetsAt: nil)))
        #expect(Fetch.codexLog(home.root.appendingPathComponent("missing.jsonl")) == nil)
    }
}
