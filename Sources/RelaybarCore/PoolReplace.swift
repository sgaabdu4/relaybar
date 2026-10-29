import Foundation

public struct PoolKeptFile: Codable, Equatable, Sendable {
    public var path: String
    public var existed: Bool
    public var edited: Bool

    public init(path: String, existed: Bool, edited: Bool) {
        self.path = path
        self.existed = existed
        self.edited = edited
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

    static func hasLogin(_ lines: [String]) -> Bool { lines.contains("login:claude") || lines.contains("login:codex") }

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

    static func codexConfig(existing: String, keyFile: String) -> String {
        var kept: [String] = []
        var inTable = false
        var dropping = false
        for line in existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("[") {
                inTable = true
                let name = text.drop { $0 == "[" || $0 == " " }.prefix { $0 != "]" }.trimmingCharacters(in: .whitespaces)
                dropping = name == "model_providers.relaybar" || name.hasPrefix("model_providers.relaybar.")
                if dropping { continue }
            } else if dropping {
                continue
            } else if !inTable, isProviderKey(text) {
                continue
            }
            kept.append(line)
        }
        while kept.last?.isEmpty == true { kept.removeLast() }
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

    private static func isProviderKey(_ text: String) -> Bool {
        if text.hasPrefix("model_providers.relaybar.") { return true }
        guard text.hasPrefix("model_provider") else { return false }
        return text.dropFirst("model_provider".count).drop { $0 == " " || $0 == "\t" }.first == "="
    }

    static func restoreScript(_ kept: [PoolKeptFile], createdFolders: [String]) -> String? {
        let folder = "$HOME/\(keptFolder)"
        var steps: [String] = []
        for file in kept {
            guard let name = names[file.path] else { continue }
            let source = "\"\(folder)/\(name)\""
            let target = "\"$HOME/\(file.path)\""
            if file.edited && file.existed {
                steps.append("[ -e \(source) ] && [ ! -L \(target) ] && cp -p \(source) \(target) && rm -f \(source)")
            } else if file.edited {
                steps.append("[ -f \(target) ] && [ ! -L \(target) ] && rm -f \(target)")
            } else {
                steps.append("[ -e \(source) ] && [ ! -e \(target) ] && [ ! -L \(target) ] && mv \(source) \(target)")
            }
        }
        guard !steps.isEmpty else { return nil }
        steps.append("rmdir \"\(folder)\" 2>/dev/null")
        for created in createdFolders where [".claude", ".codex"].contains(created) {
            steps.append("rmdir \"$HOME/\(created)\" 2>/dev/null")
        }
        return steps.joined(separator: "; ") + "; true"
    }
}

extension PoolJoin {
    private static func readFile(_ remote: PoolRemote, _ path: String) throws -> String? {
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
        guard PoolReplace.hasLogin(lines) else { return true }
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
        client.kept.append(PoolKeptFile(path: path, existed: existed, edited: true))
        checkpoint(client)
        let name = PoolReplace.names[path] ?? ""
        let copy = "$HOME/\(PoolReplace.keptFolder)/\(name)"
        let backup = existed ? "[ -e \"\(copy)\" ] || cp -p \"$f\" \"\(copy)\" || exit 1; cp -p \"$f\" \"$t\" || exit 1; " : ""
        try remote.execute(
            "f=\"$HOME/\(path)\"; t=\"$f.relaybar-new\"; \(backup)cat > \"$t\" && mv \"$t\" \"$f\" || { rm -f \"$t\"; exit 1; }",
            stdin: content)
    }
}
