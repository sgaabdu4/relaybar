import Foundation

public enum MemberState: Equatable, Sendable {
    case active(session: Window?, weekly: Window?)
    case paused
    case signedOut
    case unavailable
}

public struct PoolMember: Equatable, Sendable {
    public let credential: PoolCredential
    public let state: MemberState

    public init(credential: PoolCredential, state: MemberState) {
        self.credential = credential
        self.state = state
    }
}

public struct CombinedWindow: Equatable, Sendable {
    public let left: Int
    public let resetsAt: Date?
}

public struct PoolCard: Equatable, Sendable {
    public let kind: PoolKind
    public let session: CombinedWindow?
    public let weekly: CombinedWindow?
    public let members: [PoolMember]
    public let counted: Int
}

public enum PoolUsage {
    public static func member(_ credential: PoolCredential, result: FetchResult?) -> PoolMember {
        if credential.disabled { return PoolMember(credential: credential, state: .paused) }
        if credential.needsSignIn { return PoolMember(credential: credential, state: .signedOut) }
        switch result {
        case .ok(let session, let weekly): return PoolMember(credential: credential, state: .active(session: session, weekly: weekly))
        case .expired: return PoolMember(credential: credential, state: .signedOut)
        default: return PoolMember(credential: credential, state: .unavailable)
        }
    }

    public static func card(kind: PoolKind, members: [PoolMember], now: Date = Date()) -> PoolCard {
        let mine = members.filter { $0.credential.kind == kind }
        var sessions: [Window] = []
        var weeklies: [Window] = []
        var counted = 0
        for case .active(let session, let weekly) in mine.map(\.state) {
            counted += 1
            if let session { sessions.append(session) }
            if let weekly { weeklies.append(weekly) }
        }
        return PoolCard(
            kind: kind, session: combine(sessions, now: now), weekly: combine(weeklies, now: now), members: mine, counted: counted)
    }

    private static func combine(_ windows: [Window], now: Date) -> CombinedWindow? {
        guard !windows.isEmpty else { return nil }
        let total = windows.reduce(0) { $0 + $1.left }
        let soonest = windows.compactMap(\.resetsAt).filter { $0 > now }.min()
        return CombinedWindow(left: (total + windows.count / 2) / windows.count, resetsAt: soonest)
    }

    public static func fetch(management: PoolManagement, credentials: [PoolCredential]) async -> [PoolMember] {
        await withTaskGroup(of: (Int, PoolMember).self) { group in
            for (index, credential) in credentials.enumerated() {
                group.addTask {
                    guard !credential.disabled, !credential.needsSignIn else { return (index, member(credential, result: nil)) }
                    return (index, member(credential, result: await management.usage(of: credential)))
                }
            }
            var found: [(Int, PoolMember)] = []
            for await item in group { found.append(item) }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
