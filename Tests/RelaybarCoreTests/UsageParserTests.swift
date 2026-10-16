import Foundation
import Testing

@testable import RelaybarCore

struct UsageParserTests {
    private func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func claudeLimitsGiveSessionAndWeekly() throws {
        let body = try json(
            """
            {"limits": [
              {"kind": "session", "percent": 14, "resets_at": "2030-01-01T10:00:00.002866+00:00"},
              {"kind": "weekly_all", "percent": 75, "resets_at": "2030-01-05T09:00:00+00:00"},
              {"kind": "weekly_scoped", "percent": 3, "resets_at": "2030-01-05T09:00:00+00:00"}
            ]}
            """)
        guard case .ok(let session, let weekly) = UsageParser.claude(body) else {
            Issue.record("not ok")
            return
        }
        #expect(session?.left == 86)
        #expect(weekly?.left == 25)
        #expect(session?.resetsAt == Date(timeIntervalSince1970: 1_893_492_000))
    }

    @Test func claudeFallsBackToOlderFields() throws {
        let body = try json(#"{"five_hour": {"utilization": 40.4}, "seven_day": {"utilization": 99.6}}"#)
        guard case .ok(let session, let weekly) = UsageParser.claude(body) else {
            Issue.record("not ok")
            return
        }
        #expect(session?.left == 60)
        #expect(weekly?.left == 0)
        #expect(session?.resetsAt == nil)
    }

    @Test func codexWeeklyOnlyPlan() throws {
        let body = try json(
            #"{"rate_limit": {"primary_window": {"used_percent": 29, "limit_window_seconds": 604800, "reset_at": 1893492000}}}"#)
        #expect(
            UsageParser.codex(body)
                == .ok(session: nil, weekly: Window(used: 29, resetsAt: Date(timeIntervalSince1970: 1_893_492_000))))
    }

    @Test func codexSplitsFiveHourAndWeekly() throws {
        let body = try json(
            """
            {"rate_limit": {
              "primary_window": {"used_percent": 10, "limit_window_seconds": 18000},
              "secondary_window": {"used_percent": 60, "limit_window_seconds": 604800}
            }}
            """)
        #expect(UsageParser.codex(body) == .ok(session: Window(used: 10, resetsAt: nil), weekly: Window(used: 60, resetsAt: nil)))
    }

    @Test func codexLogUsesTheLatestCodexLimits() {
        let lines = [
            #"{"payload": {"type": "token_count", "rate_limits": {"limit_id": "codex", "primary": {"used_percent": 20, "window_minutes": 10080}}}}"#,
            #"{"payload": {"type": "message"}}"#,
            #"{"payload": {"type": "token_count", "rate_limits": {"limit_id": "codex", "primary": {"used_percent": 28, "window_minutes": 10080, "resets_at": 1893492000}}}}"#,
            #"{"payload": {"type": "token_count", "rate_limits": {"limit_id": "review", "primary": {"used_percent": 90, "window_minutes": 10080}}}}"#,
        ]
        let result = UsageParser.codexLog(Data(lines.joined(separator: "\n").utf8))
        #expect(result == .ok(session: nil, weekly: Window(used: 28, resetsAt: Date(timeIntervalSince1970: 1_893_492_000))))
    }

    @Test(arguments: [
        (401, nil as String?, FetchResult.expired),
        (403, nil, .expired),
        (429, "0", .rateLimited(retryAfter: nil)),
        (429, "30", .rateLimited(retryAfter: 30)),
        (500, nil, .failed),
    ])
    func statusCodes(status: Int, retryAfter: String?, expected: FetchResult) {
        #expect(UsageParser.response(status: status, body: Data(), retryAfter: retryAfter, parse: UsageParser.claude) == expected)
    }

    @Test func passedResetMeansFull() {
        #expect(Window(used: 90, resetsAt: Date(timeIntervalSinceNow: -60)).left == 100)
        #expect(Window(used: 90, resetsAt: Date(timeIntervalSinceNow: 60)).left == 10)
        #expect(Window(used: 130, resetsAt: nil).left == 0)
    }
}
