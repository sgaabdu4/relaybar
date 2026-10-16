import CryptoKit
import Foundation

enum Provider {
    case claude(service: String)
    case codex(authFile: URL)
}

@MainActor
final class Account {
    let id: String
    let provider: Provider
    let label: String
    private let defaultTag: String
    private let defaultTint: Tint

    private(set) var session: Window?
    private(set) var weekly: Window?
    private(set) var stale = false
    private(set) var lastFetch = Date.distantPast
    var refreshQueued = false
    private var retryAt = Date.distantPast
    private var backoff: TimeInterval = 120

    init(id: String, provider: Provider, label: String, defaultTag: String, defaultTint: Tint) {
        self.id = id
        self.provider = provider
        self.label = label
        self.defaultTag = defaultTag
        self.defaultTint = defaultTint
        if let saved = UserDefaults.standard.array(forKey: "usage:" + id) as? [Double], saved.count == 4 {
            session = Self.window(saved, 0)
            weekly = Self.window(saved, 2)
        }
    }

    private static func window(_ saved: [Double], _ index: Int) -> Window? {
        guard saved[index] >= 0 else { return nil }
        return Window(used: saved[index], resetsAt: saved[index + 1] > 0 ? Date(timeIntervalSince1970: saved[index + 1]) : nil)
    }

    var isClaude: Bool {
        if case .claude = provider { return true }
        return false
    }

    var watchPath: String {
        let sub = isClaude ? "projects" : "sessions"
        let path = id + "/" + sub
        return FileManager.default.fileExists(atPath: path) ? path : id
    }

    var tag: String {
        get { UserDefaults.standard.string(forKey: "tag:" + id) ?? defaultTag }
        set { UserDefaults.standard.set(newValue, forKey: "tag:" + id) }
    }

    var tint: Tint {
        get { UserDefaults.standard.string(forKey: "color:" + id).flatMap(Tint.init(rawValue:)) ?? defaultTint }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "color:" + id) }
    }

    func refresh() async {
        guard Date() >= retryAt else { return }
        lastFetch = Date()
        let result: FetchResult
        switch provider {
        case .claude(let service): result = await Fetch.claude(service: service)
        case .codex(let authFile): result = await Fetch.codex(authFile: authFile)
        }
        apply(result)
    }

    func apply(_ result: FetchResult) {
        switch result {
        case .ok(let session, let weekly):
            self.session = session
            self.weekly = weekly
            let saved = [session, weekly].flatMap { window -> [Double] in
                [window?.used ?? -1, window?.resetsAt?.timeIntervalSince1970 ?? 0]
            }
            UserDefaults.standard.set(saved, forKey: "usage:" + id)
            stale = false
            backoff = 120
        case .expired:
            stale = true
        case .rateLimited(let retryAfter):
            retryAt = Date().addingTimeInterval(retryAfter ?? backoff)
            backoff = min(backoff * 2, 900)
        case .failed:
            break
        }
    }

    static func discover() -> [Account] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        var claude: [Account] = []
        var codex: [Account] = []
        for name in names.sorted() {
            let dir = home.appendingPathComponent(name)
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if name == ".claude" || name.hasPrefix(".claude-") {
                let isDefault = name == ".claude"
                let config = isDefault ? home.appendingPathComponent(".claude.json") : dir.appendingPathComponent(".claude.json")
                guard let data = try? Data(contentsOf: config),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let oauth = root["oauthAccount"] as? [String: Any],
                      let email = oauth["emailAddress"] as? String
                else { continue }
                let service = isDefault ? "Claude Code-credentials" : "Claude Code-credentials-" + shortHash(dir.path)
                let org = oauth["organizationName"] as? String ?? ""
                let tag = org.isEmpty || org.hasSuffix("'s Organization") ? String(email.prefix(2)).uppercased() : initials(org)
                claude.append(Account(id: dir.path, provider: .claude(service: service), label: email, defaultTag: tag,
                                      defaultTint: Tint.palette[claude.count % Tint.palette.count]))
            } else if name == ".codex" || name.hasPrefix(".codex-") {
                let auth = dir.appendingPathComponent("auth.json")
                guard FileManager.default.fileExists(atPath: auth.path) else { continue }
                let suffix = name.dropFirst(".codex".count).drop { $0 == "-" }
                codex.append(Account(id: dir.path, provider: .codex(authFile: auth),
                                     label: codexEmail(auth) ?? name, defaultTag: String(suffix.prefix(2)).uppercased(),
                                     defaultTint: .plain))
            }
        }
        return claude + codex
    }

    private static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func initials(_ text: String) -> String {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    private static func codexEmail(_ auth: URL) -> String? {
        guard let data = try? Data(contentsOf: auth),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (root["tokens"] as? [String: Any])?["id_token"] as? String
        else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let decoded = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        else { return nil }
        return claims["email"] as? String
    }
}
