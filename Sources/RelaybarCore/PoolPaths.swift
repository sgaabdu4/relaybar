import Foundation

public enum Pool {
    public static let port = 8317
    public static let base = URL(string: "http://127.0.0.1:8317")!
    public static let major = "8"
    public static let accessService = "Relaybar access key"
    public static let managementService = "Relaybar management secret"
    public static let keychainAccount = "relaybar"
    public static let helperLabel = "com.relaybar.helper"
    public static let updateLabel = "com.relaybar.helper-update"
    public static let tunnelLabel = "com.relaybar.helper-tunnel"
    public static let claudeName = "Claude, all accounts"
    public static let codexName = "Codex, all accounts"
    public static let usageSourceLabel = "All accounts"
    public static func overriddenURL(_ variable: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[variable], value.hasPrefix("https://") || value.hasPrefix("file:///"),
            !value.contains(where: { $0.isWhitespace || "'\"$`\\".contains($0) })
        else { return nil }
        return value
    }

    public static var scriptEnvironment: [String: String] {
        var environment = ["RELAYBAR_MAJOR": major]
        if let list = overriddenURL("RELAYBAR_BLOCKLIST_URL") { environment["RELAYBAR_BLOCKLIST_URL"] = list }
        return environment
    }
}

public struct PoolPaths: Sendable {
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    public var appSupport: URL { home.appendingPathComponent("Library/Application Support/Relaybar") }
    public var helper: URL { appSupport.appendingPathComponent("Helper") }
    public var auth: URL { helper.appendingPathComponent("auth") }
    public var config: URL { helper.appendingPathComponent("config.yaml") }
    public var sandbox: URL { helper.appendingPathComponent("helper.sb") }
    public var binary: URL { helper.appendingPathComponent("current/cli-proxy-api") }
    public var updateScript: URL { appSupport.appendingPathComponent("relaybar-helper.sh") }
    public var state: URL { appSupport.appendingPathComponent("pool.json") }
    public var agents: URL { home.appendingPathComponent("Library/LaunchAgents") }
    public var claudeHub: URL { home.appendingPathComponent(".claude-hub") }
    public var codexHub: URL { home.appendingPathComponent(".codex-hub") }
    public var codexConfig: URL { codexHub.appendingPathComponent("config.toml") }
    public var claudeAll: URL { home.appendingPathComponent(".local/bin/claude-all") }
    public var codexAll: URL { home.appendingPathComponent(".local/bin/codex-all") }

    public func agent(_ label: String) -> URL { agents.appendingPathComponent(label + ".plist") }
}
