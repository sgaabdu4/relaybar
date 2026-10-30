import Foundation

public struct PoolAccountInput: Equatable, Sendable {
    public let id: String
    public let kind: PoolKind
    public let name: String
    public let email: String?

    public init(id: String, kind: PoolKind, name: String, email: String?) {
        self.id = id
        self.kind = kind
        self.name = name
        self.email = email
    }
}

public enum PoolAccountState: Equatable, Sendable {
    case active
    case paused
    case signedOut
    case notInHelper
}

public struct PoolAccountRow: Equatable, Sendable {
    public let account: PoolAccountInput
    public let state: PoolAccountState
    public let credential: PoolCredential?
    public let canPause: Bool
}

public enum PoolAccountAction: Equatable, Sendable {
    case pause(String)
    case resume(String)
    case signIn(PoolKind)
    case blocked(String)
}

public struct PoolAccountOffer: Equatable, Sendable {
    public let account: PoolAccountInput
    public let title: String
    public let addButton = "Add"
    public let declineButton = "Not now"
}

public enum PoolAccounts {
    public static func rows(accounts: [PoolAccountInput], members: [PoolMember]) -> [PoolAccountRow] {
        let matched: [(PoolAccountInput, PoolMember?)] = accounts.map { account in
            (
                account,
                members.first {
                    $0.credential.kind == account.kind && !$0.credential.email.isEmpty
                        && $0.credential.email.lowercased() == account.email?.lowercased()
                }
            )
        }
        func state(_ member: PoolMember?) -> PoolAccountState {
            guard let member else { return .notInHelper }
            switch member.state {
            case .paused: return .paused
            case .signedOut: return .signedOut
            case .active, .unavailable: return .active
            }
        }
        return matched.map { account, member in
            let activeInKind = matched.filter { $0.0.kind == account.kind && state($0.1) == .active }.count
            return PoolAccountRow(
                account: account, state: state(member), credential: member?.credential,
                canPause: state(member) == .active && activeInKind > 1)
        }
    }

    public static func toggle(_ row: PoolAccountRow) -> PoolAccountAction {
        switch row.state {
        case .notInHelper, .signedOut: return .signIn(row.account.kind)
        case .paused: return .resume(row.credential?.name ?? "")
        case .active:
            guard row.canPause, let name = row.credential?.name else {
                return .blocked("This is the last \(row.account.kind.rawValue.capitalized) account in use. Keep at least one account on.")
            }
            return .pause(name)
        }
    }

    public static func apply(_ action: PoolAccountAction, management: PoolManagement) async throws {
        switch action {
        case .pause(let name): try await management.setPaused(name: name, paused: true)
        case .resume(let name): try await management.setPaused(name: name, paused: false)
        case .signIn, .blocked: break
        }
    }

    public static func offers(known: Set<String>, current: [PoolAccountInput]) -> [PoolAccountOffer] {
        current.filter { !known.contains($0.id) }.map {
            PoolAccountOffer(account: $0, title: "Add \($0.name) to All accounts?")
        }
    }
}
