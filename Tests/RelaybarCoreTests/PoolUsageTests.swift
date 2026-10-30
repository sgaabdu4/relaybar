import Foundation
import Testing

@testable import RelaybarCore

struct PoolUsageTests {
    private let soon = Date().addingTimeInterval(3600)
    private let later = Date().addingTimeInterval(7200)

    private func credential(_ email: String, _ kind: PoolKind = .claude, disabled: Bool = false, status: String = "active")
        -> PoolCredential
    {
        PoolCredential(name: email + ".json", authIndex: email, email: email, kind: kind, disabled: disabled, status: status)
    }

    private func active(_ used: Double, resets: Date? = nil, weekly: Double? = nil) -> FetchResult {
        .ok(session: Window(used: used, resetsAt: resets), weekly: weekly.map { Window(used: $0, resetsAt: later) })
    }

    @Test func averagesSignedInMembers() {
        let members = [
            PoolUsage.member(credential("a@example.com"), result: active(20, resets: later, weekly: 10)),
            PoolUsage.member(credential("b@example.com"), result: active(61, resets: soon, weekly: 30)),
            PoolUsage.member(credential("c@example.com", .codex), result: active(0)),
        ]
        let card = PoolUsage.card(kind: .claude, members: members)
        #expect(card.counted == 2)
        #expect(card.session?.left == 60)
        #expect(card.session?.resetsAt == soon)
        #expect(card.weekly?.left == 80)
        #expect(card.members.count == 2)
        #expect(PoolUsage.card(kind: .codex, members: members).session?.left == 100)
    }

    @Test func flagsSignedOutMembers() {
        let expired = PoolUsage.member(credential("a@example.com"), result: .expired)
        let stale = PoolUsage.member(credential("b@example.com", status: "error"), result: nil)
        let busy = PoolUsage.member(credential("c@example.com"), result: .failed)
        let fine = PoolUsage.member(credential("d@example.com"), result: active(50))
        #expect(expired.state == .signedOut)
        #expect(stale.state == .signedOut)
        #expect(busy.state == .unavailable)
        let card = PoolUsage.card(kind: .claude, members: [expired, stale, busy, fine])
        #expect(card.counted == 1)
        #expect(card.session?.left == 50)
        #expect(card.members.count == 4)
    }

    @Test func leavesOutPausedAccounts() {
        let paused = PoolUsage.member(credential("a@example.com", disabled: true), result: active(90))
        let fine = PoolUsage.member(credential("b@example.com"), result: active(10))
        #expect(paused.state == .paused)
        let card = PoolUsage.card(kind: .claude, members: [paused, fine])
        #expect(card.session?.left == 90)
        #expect(PoolUsage.card(kind: .claude, members: [paused]).session == nil)
        #expect(PoolUsage.card(kind: .claude, members: []).counted == 0)
    }

    @Test func fetchesEveryActiveAccountInOrder() async {
        let http = FakeHTTP()
        http.handler = { request in
            let sent = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
            let body = #"{"five_hour":{"utilization":\#(sent?["auth_index"] as? String == "a@example.com" ? 10 : 70)}}"#
            return ok(["status_code": 200, "body": body])
        }
        let management = PoolManagement(secret: "s", http: http.client)
        let list = [credential("a@example.com"), credential("p@example.com", disabled: true), credential("b@example.com")]
        let members = await PoolUsage.fetch(management: management, credentials: list)
        #expect(members.map(\.credential.email) == ["a@example.com", "p@example.com", "b@example.com"])
        #expect(
            members.map(\.state).map { state -> Int? in
                if case .active(let session, _) = state { return session?.left }
                return nil
            } == [90, nil, 30])
        #expect(http.requests.count == 2)
        #expect(!http.requests.contains { $0.url.host == "ipinfo.io" })
    }
}
