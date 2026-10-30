import CryptoKit
import Foundation

public struct PoolKeptFile: Codable, Equatable, Sendable {
    public var path: String
    public var existed: Bool
    public var edited: Bool
    public var hash: String?

    public init(path: String, existed: Bool, edited: Bool, hash: String? = nil) {
        self.path = path
        self.existed = existed
        self.edited = edited
        self.hash = hash
    }
}

public enum PoolReplace {
    public static let claudeSettings = ".claude/settings.json"
    public static let claudeLogin = ".claude/.credentials.json"
    public static let codexConfig = ".codex/config.toml"
    public static let codexLogin = ".codex/auth.json"
    static let keptFolder = ".config/relaybar/kept"
    static let names = [
        claudeSettings: "claude-settings.json", claudeLogin: "claude-credentials.json", codexConfig: "codex-config.toml",
        codexLogin: "codex-auth.json",
    ]

    static let probe =
        "{ [ -s \"$HOME/.claude/.credentials.json\" ] || grep -q '\"oauthAccount\"' \"$HOME/.claude.json\" 2>/dev/null; } && echo login:claude; "
        + "[ -s \"$HOME/.codex/auth.json\" ] && echo login:codex; "
        + "for p in .claude .claude/settings.json .claude/.credentials.json .codex .codex/config.toml .codex/auth.json \(keptFolder); do "
        + "[ -L \"$HOME/$p\" ] && echo link:$p; done; "
        + "[ -e \"$HOME/.claude\" ] || echo claudedir:new; "
        + "grep -q '\"primaryApiKey\"' \"$HOME/.claude.json\" 2>/dev/null && echo setup:claude; "

    static func hasLogin(_ lines: [String]) -> Bool { lines.contains("login:claude") || lines.contains("login:codex") }

    static func hasSetup(_ lines: [String]) -> Bool { hasLogin(lines) || lines.contains("setup:claude") }

    static func ownClaudeSetup(_ settings: String?) -> Bool {
        guard let settings, let root = try? JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any] else { return false }
        let env = root["env"] as? [String: Any] ?? [:]
        return root["apiKeyHelper"] != nil || envKeys.contains { env[$0] != nil }
    }

    static func ownCodexSetup(_ config: String?) -> Bool {
        guard let config else { return false }
        return codexLines(config).contains { $0.table.isEmpty && ($0.key == ["model_provider"] || $0.key == ["profile"]) }
    }

    static func blockedByLink(_ lines: [String]) -> Bool { lines.contains { $0.hasPrefix("link:") } }

    static func claudeSettings(existing: Data?, home: String) -> Data? {
        var root: [String: Any] = [:]
        if let existing {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else { return nil }
            root = parsed
        }
        var env = root["env"] as? [String: Any] ?? [:]
        env["ANTHROPIC_BASE_URL"] = Pool.base.absoluteString
        for name in ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"] { env[name] = nil }
        root["env"] = env
        root["apiKeyHelper"] = "/bin/cat " + Shell.quote(home + "/.config/relaybar/access-key")
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static let envKeys = ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"]

    static func claudeWithout(current: Data, original: Data?) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: current) as? [String: Any] else { return nil }
        let before = original.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var env = root["env"] as? [String: Any] ?? [:]
        if env["ANTHROPIC_BASE_URL"] as? String == Pool.base.absoluteString { env["ANTHROPIC_BASE_URL"] = nil }
        if (root["apiKeyHelper"] as? String)?.contains("/.config/relaybar/access-key") == true { root["apiKeyHelper"] = nil }
        let earlier = before["env"] as? [String: Any] ?? [:]
        for name in envKeys where env[name] == nil { env[name] = earlier[name] }
        if root["apiKeyHelper"] == nil { root["apiKeyHelper"] = before["apiKeyHelper"] }
        root["env"] = env.isEmpty ? nil : env
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func codexWithout(current: String, original: String?) -> String {
        let now = codexKept(current, ownProviderOnly: true)
        var kept = now.kept
        let hasProvider = codexKept(current, ownProviderOnly: false).provider != nil && now.provider == nil
        if !hasProvider, let line = original.flatMap({ codexKept($0).provider }) { kept.insert(line, at: 0) }
        while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
        while kept.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeFirst() }
        return kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
    }

    static func codexConfig(existing: String, keyFile: String) -> String {
        var kept = codexKept(existing).kept
        while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
        let provider = PoolConfig.codexProvider(keyCommand: ["/bin/cat", keyFile])
        func table(_ prefix: String) -> [String] {
            provider.filter { $0.0.hasPrefix(prefix) && !$0.0.dropFirst(prefix.count).contains(".") }.map {
                "\($0.0.dropFirst(prefix.count)) = \($0.1)"
            }
        }
        let lines =
            ["model_provider = \"relaybar\""] + kept + [""] + ["[model_providers.relaybar]"]
            + table("model_providers.relaybar.") + ["", "[model_providers.relaybar.auth]"] + table("model_providers.relaybar.auth.")
        return lines.joined(separator: "\n") + "\n"
    }
}

extension PoolJoin {
    static func readFile(_ remote: PoolRemote, _ path: String) throws -> String? {
        let output = try remote.execute("f=\"$HOME/\(path)\"; if [ -f \"$f\" ]; then echo yes; cat \"$f\"; else echo no; fi")
        guard output.hasPrefix("yes\n") else { return nil }
        return String(output.dropFirst(4))
    }

    static func decideReplace(
        _ remote: PoolRemote, lines: [String], hooks: PoolAddHooks, progress: (String) -> Void
    ) async throws -> Bool {
        if PoolReplace.blockedByLink(lines) {
            progress("A Claude Code or Codex file on \(remote.host) is a link, so Relaybar will not change them")
            return false
        }
        if let settings = try readFile(remote, PoolReplace.claudeSettings),
            PoolReplace.claudeSettings(existing: Data(settings.utf8), home: "/home") == nil
        {
            progress("The Claude Code settings on \(remote.host) are not valid JSON, so Relaybar will not change them")
            return false
        }
        let claude = try readFile(remote, PoolReplace.claudeSettings)
        let codex = try readFile(remote, PoolReplace.codexConfig)
        guard PoolReplace.hasSetup(lines) || PoolReplace.ownClaudeSetup(claude) || PoolReplace.ownCodexSetup(codex) else { return true }
        return await hooks.replaceLogins(remote.host)
    }

    static func replaceLogins(
        _ remote: PoolRemote, home: String, lines: [String], client: inout PoolLinuxClient, checkpoint: (PoolLinuxClient?) -> Void
    ) throws {
        let kept = "$HOME/\(PoolReplace.keptFolder)"
        try remote.execute("umask 077; mkdir -p \"\(kept)\"")
        if lines.contains("claudedir:new") { client.createdFolders.append(".claude") }
        if lines.contains("codexdir:new") { client.createdFolders.append(".codex") }
        checkpoint(client)
        try remote.execute("mkdir -p \"$HOME/.claude\" \"$HOME/.codex\"")
        for (path, present) in [
            (PoolReplace.claudeLogin, lines.contains("login:claude")), (PoolReplace.codexLogin, lines.contains("login:codex")),
        ] where present {
            client.kept.append(PoolKeptFile(path: path, existed: true, edited: false))
            checkpoint(client)
            let name = PoolReplace.names[path] ?? ""
            try remote.execute(
                "f=\"$HOME/\(path)\"; if [ -f \"$f\" ] && [ ! -L \"$f\" ]; then mv \"$f\" \"\(kept)/\(name)\"; fi; true")
        }
        let settings = try readFile(remote, PoolReplace.claudeSettings)
        guard let json = PoolReplace.claudeSettings(existing: settings.map { Data($0.utf8) }, home: home) else {
            throw PoolSSHError.failed("The Claude Code settings on \(remote.host) are not valid JSON.")
        }
        try edit(remote, path: PoolReplace.claudeSettings, existed: settings != nil, content: json, client: &client, checkpoint: checkpoint)
        let config = try readFile(remote, PoolReplace.codexConfig)
        let text = PoolReplace.codexConfig(existing: config ?? "", keyFile: home + "/.config/relaybar/access-key")
        try edit(
            remote, path: PoolReplace.codexConfig, existed: config != nil, content: Data(text.utf8), client: &client, checkpoint: checkpoint
        )
    }

    private static func edit(
        _ remote: PoolRemote, path: String, existed: Bool, content: Data, client: inout PoolLinuxClient,
        checkpoint: (PoolLinuxClient?) -> Void
    ) throws {
        let hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        client.kept.append(PoolKeptFile(path: path, existed: existed, edited: true, hash: hash))
        checkpoint(client)
        let name = PoolReplace.names[path] ?? ""
        let copy = "$HOME/\(PoolReplace.keptFolder)/\(name)"
        let backup = existed ? "[ -e \"\(copy)\" ] || cp -p \"$f\" \"\(copy)\" || exit 1; cp -p \"$f\" \"$t\" || exit 1; " : ""
        try remote.execute(
            "f=\"$HOME/\(path)\"; t=\"$f.relaybar-new\"; \(backup)cat > \"$t\" && mv \"$t\" \"$f\" || { rm -f \"$t\"; exit 1; }",
            stdin: content)
    }
}
