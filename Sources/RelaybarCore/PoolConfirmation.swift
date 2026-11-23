public struct PoolConfirmation: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case openT3
        case tailscale
        case undo
        case dismiss
    }

    public let title: String
    public let detail: String
    public let primary: Action?
    public let secondary: Action?
    public let closesAfter: Double?
    public let warning: String?

    public static func combined(host: String?, accounts: [String], t3: Bool, note: String?, tailscale: Bool) -> PoolConfirmation {
        let first = t3 ? "New chats in T3 Code now use Claude+." : "Use claude+ and codex+ in a terminal."
        let offer = tailscale && host != nil
        return make(
            title: "\(who(accounts)) combined on \(host ?? "this Mac")",
            detail: offer ? askAway : first, offer: offer,
            primary: t3 ? .openT3 : nil, secondary: .undo, seconds: 10, warning: note)
    }

    public static func names(for accounts: [(kind: PoolKind, tag: String)]) -> [String] {
        let bases = accounts.map { account in
            let kind = account.kind == .claude ? "Claude" : "Codex"
            return account.tag.isEmpty ? kind : kind + " " + account.tag
        }
        var seen: [String: Int] = [:]
        return zip(accounts, bases).map { account, base in
            guard account.tag.isEmpty, bases.filter({ $0 == base }).count > 1 else { return base }
            seen[base, default: 0] += 1
            return "\(base) \(seen[base] ?? 0)"
        }
    }

    private static func who(_ accounts: [String]) -> String {
        guard !accounts.isEmpty else { return "Your accounts are" }
        let more = accounts.count > 3 ? ["\(accounts.count - 3) more"] : []
        return PoolMove.list(Array(accounts.prefix(3)) + more) + (accounts.count == 1 ? " is" : " are")
    }

    public static func moved(
        host: String?, computers: [String], old: String?, pending: Bool, note: String?, tailscale: Bool
    ) -> PoolConfirmation {
        let done = PoolMove.doneText(target: host, computers: computers, old: old, pending: pending)
        let offer = tailscale && host != nil
        return make(
            title: "Your accounts now run on \(host ?? "this Mac")", detail: offer ? done + "\n" + askAway : done, offer: offer,
            primary: nil, secondary: nil, seconds: 12, warning: note)
    }

    private static let askAway = "Use it away from home too?"

    private static func make(
        title: String, detail: String, offer: Bool, primary: Action?, secondary: Action?, seconds: Double, warning: String?
    ) -> PoolConfirmation {
        guard offer else {
            return PoolConfirmation(
                title: title, detail: detail, primary: primary, secondary: secondary, closesAfter: seconds, warning: warning)
        }
        return PoolConfirmation(
            title: title, detail: detail, primary: .tailscale, secondary: .dismiss, closesAfter: nil, warning: warning)
    }
}
