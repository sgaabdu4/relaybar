import Foundation

public struct PoolPriority: Equatable, Sendable {
    public let name: String
    public let priority: Int
}

public struct PoolPlan: Equatable, Sendable {
    public let kind: PoolKind
    public let savedOrder: [String]
    public let effective: [PoolMember]
    public let inUse: PoolMember?
    public let changes: [PoolPriority]
}

public enum PoolOrder {
    public static let lowPercent = 10

    public static func nearlyUsedUp(_ member: PoolMember) -> Bool {
        guard case .active(let session, let weekly) = member.state else { return false }
        return [session, weekly].contains { ($0?.left ?? 100) < lowPercent }
    }

    public static func plan(kind: PoolKind, members: [PoolMember], saved: [String]) -> PoolPlan {
        let mine = members.filter { $0.credential.kind == kind }
        let rank = Dictionary(
            saved.enumerated().map { ($1.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let known = mine.filter { rank[$0.credential.email.lowercased()] != nil }
            .sorted { rank[$0.credential.email.lowercased()]! < rank[$1.credential.email.lowercased()]! }
        let added = mine.filter { rank[$0.credential.email.lowercased()] == nil }.sorted { $0.credential.name < $1.credential.name }
        let base = known + added
        let effective = base.filter { !nearlyUsedUp($0) } + base.filter(nearlyUsedUp)
        let changes = effective.enumerated().compactMap { index, member -> PoolPriority? in
            let target = effective.count - index
            return member.credential.priority == target ? nil : PoolPriority(name: member.credential.name, priority: target)
        }
        let inUse = effective.first {
            switch $0.state {
            case .active, .unavailable: return true
            case .paused, .signedOut: return false
            }
        }
        return PoolPlan(
            kind: kind, savedOrder: base.map { $0.credential.email.lowercased() }, effective: effective, inUse: inUse, changes: changes)
    }

    public static func move(_ email: String, to index: Int, in order: [String]) -> [String] {
        var result = order.filter { $0.lowercased() != email.lowercased() }
        result.insert(email.lowercased(), at: min(max(index, 0), result.count))
        return result
    }

    public static func apply(_ plan: PoolPlan, management: PoolManagement) async throws {
        for change in plan.changes { try await management.setPriority(name: change.name, priority: change.priority) }
    }
}

extension PoolSetup {
    public func updateOrder(members: [PoolMember]) async throws -> [PoolPlan] {
        guard var state = PoolState.load(env.paths), let management else { return [] }
        var plans: [PoolPlan] = []
        for kind in [PoolKind.claude, .codex] {
            let plan = PoolOrder.plan(kind: kind, members: members, saved: state.order[kind.rawValue] ?? [])
            state.order[kind.rawValue] = plan.savedOrder
            try await PoolOrder.apply(plan, management: management)
            plans.append(plan)
        }
        guard var latest = PoolState.load(env.paths) else { return plans }
        latest.order = state.order
        try latest.save(env.paths)
        return plans
    }

    public func setOrder(kind: PoolKind, emails: [String]) throws {
        guard var state = PoolState.load(env.paths) else { return }
        state.order[kind.rawValue] = emails.map { $0.lowercased() }
        try state.save(env.paths)
    }
}
