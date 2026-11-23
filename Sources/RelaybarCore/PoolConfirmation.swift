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

    public static func combined(host: String?, t3: Bool, note: String?, tailscale: Bool) -> PoolConfirmation {
        let first =
            t3
            ? "New chats in T3 Code now use Claude+."
            : "Use the claude+ and codex+ commands in a terminal to use your combined accounts."
        let more = tailscale ? " It works on your home Wi-Fi." : t3 ? " T3 Code also shows what is left on each account." : ""
        return make(
            title: "Your accounts are combined on \(host ?? "this Mac")", detail: first + more, host: host, offer: tailscale,
            primary: t3 ? .openT3 : nil, secondary: .undo, seconds: 10, warning: note)
    }

    public static func moved(
        host: String?, computers: [String], old: String?, pending: Bool, note: String?, tailscale: Bool
    ) -> PoolConfirmation {
        make(
            title: "Your accounts now run on \(host ?? "this Mac")",
            detail: PoolMove.doneText(target: host, computers: computers, old: old, pending: pending), host: host,
            offer: tailscale, primary: nil, secondary: nil, seconds: 12, warning: note)
    }

    private static func make(
        title: String, detail: String, host: String?, offer: Bool, primary: Action?, secondary: Action?, seconds: Double,
        warning: String?
    ) -> PoolConfirmation {
        guard offer, let host else {
            return PoolConfirmation(
                title: title, detail: detail, primary: primary, secondary: secondary, closesAfter: seconds, warning: warning)
        }
        let ask =
            "Use it away from home too? Relaybar sets up Tailscale on this Mac and on \(host). You type your Mac password, click Allow once and sign in once."
        return PoolConfirmation(
            title: title, detail: detail + "\n" + ask, primary: .tailscale, secondary: .dismiss, closesAfter: nil, warning: warning)
    }
}
