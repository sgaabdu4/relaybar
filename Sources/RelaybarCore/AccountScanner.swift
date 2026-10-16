import CryptoKit
import Foundation

public struct AccountInfo: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case claude(service: String)
        case codex(authFile: URL)
    }

    public let id: String
    public let source: Source
    public let label: String
    public let defaultTag: String
}

public enum AccountScanner {
    public static func scan(home: URL) -> [AccountInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        var claude: [AccountInfo] = []
        var codex: [AccountInfo] = []
        for name in names.sorted() {
            let dir = home.appendingPathComponent(name)
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if name == ".claude" || name.hasPrefix(".claude-") {
                let isDefault = name == ".claude"
                let config = isDefault ? home.appendingPathComponent(".claude.json") : dir.appendingPathComponent(".claude.json")
                guard let oauth = json(config)?["oauthAccount"] as? [String: Any],
                    let email = oauth["emailAddress"] as? String
                else { continue }
                let org = oauth["organizationName"] as? String ?? ""
                let tag = org.isEmpty || org.hasSuffix("'s Organization") ? String(email.prefix(2)).uppercased() : initials(org)
                let service = keychainService(configDir: dir.path, isDefault: isDefault)
                claude.append(AccountInfo(id: dir.path, source: .claude(service: service), label: email, defaultTag: tag))
            } else if name == ".codex" || name.hasPrefix(".codex-") {
                let auth = dir.appendingPathComponent("auth.json")
                guard FileManager.default.fileExists(atPath: auth.path) else { continue }
                let suffix = name.dropFirst(".codex".count).drop { $0 == "-" }
                codex.append(
                    AccountInfo(
                        id: dir.path, source: .codex(authFile: auth), label: codexEmail(auth) ?? name,
                        defaultTag: String(suffix.prefix(2)).uppercased()))
            }
        }
        return claude + codex
    }

    public static func keychainService(configDir: String, isDefault: Bool) -> String {
        guard !isDefault else { return "Claude Code-credentials" }
        return "Claude Code-credentials-" + SHA256.hash(data: Data(configDir.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func initials(_ text: String) -> String {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    private static func codexEmail(_ auth: URL) -> String? {
        guard let token = (json(auth)?["tokens"] as? [String: Any])?["id_token"] as? String else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let decoded = Data(base64Encoded: payload),
            let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        else { return nil }
        return claims["email"] as? String
    }

    private static func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
