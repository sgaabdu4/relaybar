import Foundation
import Testing

@testable import RelaybarCore

struct PoolOrderTests {
    private func member(
        _ email: String, kind: PoolKind = .claude, priority: Int = 0, session: Double = 20, weekly: Double = 20, resets: Date? = nil,
        disabled: Bool = false, status: String = "active"
    ) -> PoolMember {
        let credential = PoolCredential(
            name: "\(kind.rawValue)-\(email).json", authIndex: email, email: email, kind: kind, disabled: disabled, status: status,
            priority: priority)
        return PoolUsage.member(
            credential,
            result: .ok(session: Window(used: session, resetsAt: resets), weekly: Window(used: weekly, resetsAt: nil)))
    }

    private func emails(_ plan: PoolPlan) -> [String] { plan.effective.map(\.credential.email) }

    @Test func followsTheUserOrder() {
        let members = [member("a@example.com"), member("b@example.com"), member("c@example.com"), member("x@example.com", kind: .codex)]
        let plan = PoolOrder.plan(kind: .claude, members: members, saved: ["B@example.com", "a@example.com"])
        #expect(emails(plan) == ["b@example.com", "a@example.com", "c@example.com"])
        #expect(plan.savedOrder == ["b@example.com", "a@example.com", "c@example.com"])
        #expect(
            plan.changes == [
                PoolPriority(name: "claude-b@example.com.json", priority: 3), PoolPriority(name: "claude-a@example.com.json", priority: 2),
                PoolPriority(name: "claude-c@example.com.json", priority: 1),
            ])
        #expect(PoolOrder.plan(kind: .codex, members: members, saved: []).effective.count == 1)
        #expect(PoolOrder.move("c@example.com", to: 0, in: plan.savedOrder) == ["c@example.com", "b@example.com", "a@example.com"])
        #expect(PoolOrder.move("C@example.com", to: 99, in: ["c@example.com", "a@example.com"]) == ["a@example.com", "c@example.com"])
        #expect(PoolOrder.move("a@example.com", to: -4, in: ["b@example.com"]) == ["a@example.com", "b@example.com"])
    }

    @Test func movesANearlyUsedAccountDown() {
        let members = [
            member("a@example.com", session: 95), member("b@example.com"), member("c@example.com", weekly: 91.2),
            member("d@example.com"),
        ]
        let plan = PoolOrder.plan(
            kind: .claude, members: members, saved: ["a@example.com", "b@example.com", "c@example.com", "d@example.com"])
        #expect(emails(plan) == ["b@example.com", "d@example.com", "a@example.com", "c@example.com"])
        #expect(plan.savedOrder == ["a@example.com", "b@example.com", "c@example.com", "d@example.com"])
        let exactlyTen = PoolOrder.plan(
            kind: .claude, members: [member("a@example.com", session: 90), member("b@example.com")], saved: ["a@example.com"])
        #expect(emails(exactlyTen) == ["a@example.com", "b@example.com"])
        let alone = PoolOrder.plan(kind: .claude, members: [member("a@example.com", session: 99)], saved: [])
        #expect(emails(alone) == ["a@example.com"])
    }

    @Test func returnsItAfterReset() {
        let saved = ["a@example.com", "b@example.com"]
        let nearly = PoolOrder.plan(kind: .claude, members: [member("a@example.com", session: 97), member("b@example.com")], saved: saved)
        #expect(emails(nearly) == ["b@example.com", "a@example.com"])
        let reset = PoolOrder.plan(
            kind: .claude,
            members: [member("a@example.com", session: 97, resets: Date().addingTimeInterval(-60)), member("b@example.com")], saved: saved)
        #expect(emails(reset) == saved)
        let rested = PoolOrder.plan(kind: .claude, members: [member("a@example.com", session: 60), member("b@example.com")], saved: saved)
        #expect(emails(rested) == saved)
    }

    @Test func onlyPatchesChangedPriorities() async throws {
        let saved = ["a@example.com", "b@example.com", "c@example.com"]
        let settled = PoolOrder.plan(
            kind: .claude,
            members: [member("a@example.com", priority: 3), member("b@example.com", priority: 2), member("c@example.com", priority: 1)],
            saved: saved)
        #expect(settled.changes.isEmpty)
        let swapped = PoolOrder.plan(
            kind: .claude,
            members: [
                member("a@example.com", priority: 3, session: 99), member("b@example.com", priority: 2),
                member("c@example.com", priority: 1),
            ],
            saved: saved)
        #expect(
            swapped.changes == [
                PoolPriority(name: "claude-b@example.com.json", priority: 3), PoolPriority(name: "claude-c@example.com.json", priority: 2),
                PoolPriority(name: "claude-a@example.com.json", priority: 1),
            ])
        let partial = PoolOrder.plan(
            kind: .claude,
            members: [member("a@example.com", priority: 3), member("b@example.com", priority: 2), member("c@example.com", priority: 9)],
            saved: saved)
        #expect(partial.changes == [PoolPriority(name: "claude-c@example.com.json", priority: 1)])
        let http = FakeHTTP()
        http.handler = { _ in ok(["status": "ok"]) }
        let management = PoolManagement(secret: "s", http: http.client)
        try await PoolOrder.apply(partial, management: management)
        try await PoolOrder.apply(settled, management: management)
        #expect(http.requests.count == 1)
        let request = try #require(http.requests.first)
        #expect(request.method == "PATCH")
        #expect(request.url.path == "/v8/management/credentials/fields")
        let body = try #require(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
        #expect(body["name"] as? String == "claude-c@example.com.json")
        #expect(body["priority"] as? Int == 1)
    }

    @Test func namesTheAccountInUse() {
        let saved = ["a@example.com", "b@example.com", "c@example.com"]
        let members = [member("a@example.com", disabled: true), member("b@example.com", status: "error"), member("c@example.com")]
        #expect(PoolOrder.plan(kind: .claude, members: members, saved: saved).inUse?.credential.email == "c@example.com")
        let none = PoolOrder.plan(kind: .claude, members: Array(members.prefix(2)), saved: saved)
        #expect(none.inUse == nil)
        let slipped = [member("a@example.com", session: 95), member("b@example.com")]
        #expect(PoolOrder.plan(kind: .claude, members: slipped, saved: saved).inUse?.credential.email == "b@example.com")
        #expect(PoolOrder.plan(kind: .claude, members: [], saved: saved).inUse == nil)
    }

    @Test func keepsTheOrderInThePoolFileAndSendsChanges() async throws {
        let harness = try Harness()
        try PoolState().save(harness.paths)
        harness.recorder.respond = { _ in CommandResult(output: "msecret\n") }
        harness.http.handler = { _ in ok(["status": "ok"]) }
        let setup = PoolSetup(env: harness.env())
        try setup.setOrder(kind: .claude, emails: ["B@example.com", "a@example.com"])
        let plans = try await setup.updateOrder(members: [member("a@example.com"), member("b@example.com"), member("c@example.com")])
        #expect(plans.map(\.kind) == [.claude, .codex])
        #expect(PoolState.load(harness.paths)?.order["claude"] == ["b@example.com", "a@example.com", "c@example.com"])
        #expect(harness.http.requests.count == 3)
        let none = try Harness()
        #expect(try await PoolSetup(env: none.env()).updateOrder(members: []).isEmpty)
        try PoolSetup(env: none.env()).setOrder(kind: .claude, emails: ["x"])
        #expect(PoolState.load(none.paths) == nil)
    }

    @Test func aJoinedMacNeverSendsPriorities() async throws {
        let harness = try Harness()
        try PoolState(ssh: "homebox", joined: true).save(harness.paths)
        harness.recorder.respond = { _ in CommandResult(output: "msecret\n") }
        harness.http.handler = { _ in ok(["status": "ok"]) }
        let plans = try await PoolSetup(env: harness.env()).updateOrder(members: [member("a@example.com"), member("b@example.com")])
        #expect(plans.isEmpty)
        #expect(harness.http.requests.isEmpty)
    }

    @Test func namesTheAccountInUseFromTheHelperPriorities() {
        let members = [
            member("a@example.com", priority: 2), member("b@example.com", priority: 9, disabled: true),
            member("c@example.com", priority: 5, status: "error"), member("d@example.com", priority: 2),
            member("e@example.com", kind: .codex, priority: 1),
        ]
        #expect(PoolOrder.inUse(kind: .claude, members: members)?.credential.email == "a@example.com")
        #expect(PoolOrder.inUse(kind: .claude, members: Array(members.dropFirst().prefix(2))) == nil)
        #expect(PoolOrder.inUse(kind: .codex, members: members)?.credential.email == "e@example.com")
        let raised = members + [member("f@example.com", priority: 3)]
        #expect(PoolOrder.inUse(kind: .claude, members: raised)?.credential.email == "f@example.com")
        #expect(PoolOrder.inUse(kind: .claude, members: []) == nil)
    }
}
