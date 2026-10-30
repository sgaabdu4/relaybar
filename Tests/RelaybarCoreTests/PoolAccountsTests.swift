import Foundation
import Testing

@testable import RelaybarCore

struct PoolAccountsTests {
    private func credential(_ email: String, _ kind: PoolKind, disabled: Bool = false, status: String = "active") -> PoolCredential {
        PoolCredential(
            name: "\(kind.rawValue)-\(email).json", authIndex: email, email: email, kind: kind, disabled: disabled, status: status)
    }

    private func member(_ email: String, _ kind: PoolKind, disabled: Bool = false, status: String = "active") -> PoolMember {
        PoolUsage.member(credential(email, kind, disabled: disabled, status: status), result: .ok(session: nil, weekly: nil))
    }

    private let ann = PoolAccountInput(id: "/h/.claude-ann", kind: .claude, name: "Ann", email: "Ann@Example.com")
    private let bob = PoolAccountInput(id: "/h/.claude-bob", kind: .claude, name: "Bob", email: "bob@example.com")
    private let cat = PoolAccountInput(id: "/h/.codex-cat", kind: .codex, name: "Cat", email: "cat@example.com")

    @Test func matchesLoginsByEmail() {
        let rows = PoolAccounts.rows(
            accounts: [ann, bob, cat], members: [member("ann@example.com", .claude), member("cat@example.com", .claude)])
        #expect(rows[0].state == .active)
        #expect(rows[0].credential?.name == "claude-ann@example.com.json")
        #expect(rows[1].state == .notInHelper)
        #expect(rows[2].state == .notInHelper)
        let noEmail = PoolAccountInput(id: "x", kind: .claude, name: "X", email: nil)
        #expect(PoolAccounts.rows(accounts: [noEmail], members: [member("a@example.com", .claude)])[0].state == .notInHelper)
    }

    @Test func pausesAndResumes() async throws {
        let dan = PoolAccountInput(id: "/h/.claude-dan", kind: .claude, name: "Dan", email: "dan@example.com")
        let rows = PoolAccounts.rows(
            accounts: [ann, bob, dan],
            members: [
                member("ann@example.com", .claude), member("bob@example.com", .claude, disabled: true), member("dan@example.com", .claude),
            ])
        #expect(rows[1].state == .paused)
        let pause = PoolAccounts.toggle(rows[0])
        #expect(pause == .pause("claude-ann@example.com.json"))
        #expect(PoolAccounts.toggle(rows[1]) == .resume("claude-bob@example.com.json"))
        let http = FakeHTTP()
        http.handler = { _ in ok(["status": "ok"]) }
        let management = PoolManagement(secret: "s", http: http.client)
        try await PoolAccounts.apply(pause, management: management)
        try await PoolAccounts.apply(.resume("claude-bob@example.com.json"), management: management)
        try await PoolAccounts.apply(.signIn(.claude), management: management)
        #expect(http.requests.count == 2)
        let bodies = http.requests.compactMap { try? JSONSerialization.jsonObject(with: $0.body ?? Data()) as? [String: Any] }
        #expect(bodies.map { $0["disabled"] as? Bool } == [true, false])
    }

    @Test func signsInAMissingAccount() {
        let rows = PoolAccounts.rows(accounts: [ann, bob], members: [member("ann@example.com", .claude, status: "error")])
        #expect(rows[0].state == .signedOut)
        #expect(PoolAccounts.toggle(rows[0]) == .signIn(.claude))
        #expect(PoolAccounts.toggle(rows[1]) == .signIn(.claude))
    }

    @Test func keepsTheLastAccountOfEachKind() {
        let rows = PoolAccounts.rows(
            accounts: [ann, bob, cat],
            members: [
                member("ann@example.com", .claude), member("bob@example.com", .claude, disabled: true), member("cat@example.com", .codex),
            ])
        #expect(!rows[0].canPause)
        #expect(!rows[2].canPause)
        guard case .blocked(let why) = PoolAccounts.toggle(rows[0]) else {
            Issue.record("pausing the last Claude account was allowed")
            return
        }
        #expect(why.contains("Claude"))
        guard case .blocked = PoolAccounts.toggle(rows[2]) else {
            Issue.record("pausing the last Codex account was allowed")
            return
        }
        let two = PoolAccounts.rows(
            accounts: [ann, bob], members: [member("ann@example.com", .claude), member("bob@example.com", .claude)])
        #expect(two.allSatisfy({ $0.canPause }))
        let withSignedOut = PoolAccounts.rows(
            accounts: [ann, bob], members: [member("ann@example.com", .claude), member("bob@example.com", .claude, status: "error")])
        #expect(!withSignedOut[0].canPause)
    }

    @Test func offersNewAccounts() {
        let offers = PoolAccounts.offers(known: [ann.id], current: [ann, bob, cat])
        #expect(offers.map(\.title) == ["Add Bob to All accounts?", "Add Cat to All accounts?"])
        #expect(offers[0].addButton == "Add")
        #expect(offers[0].declineButton == "Not now")
        #expect(PoolAccounts.offers(known: [ann.id, bob.id, cat.id], current: [ann, bob, cat]).isEmpty)
    }
}
