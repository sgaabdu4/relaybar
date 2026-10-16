import Foundation

public struct Window: Equatable, Sendable {
    public let used: Double
    public let resetsAt: Date?

    public init(used: Double, resetsAt: Date?) {
        self.used = used
        self.resetsAt = resetsAt
    }

    public var left: Int {
        if let resetsAt, resetsAt < Date() { return 100 }
        return max(0, 100 - Int(used.rounded()))
    }
}

public enum FetchResult: Equatable, Sendable {
    case ok(session: Window?, weekly: Window?)
    case expired
    case rateLimited(retryAfter: TimeInterval?)
    case failed
}

public enum Fetch {
    private static let http = URLSession(configuration: .ephemeral)

    public static func claude(service: String) async -> FetchResult {
        var login = await logins.get(service)
        if login == nil || login.map({ $0.expiresAt < Date().addingTimeInterval(60) }) == true {
            login = await Task.detached(operation: { keychainLogin(service) }).value
            await logins.set(service, login)
        }
        guard let token = login?.token, let expiresAt = login?.expiresAt else { return .failed }
        guard expiresAt > Date() else { return .expired }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let result = await get(request, parse: UsageParser.claude)
        if result == .expired { await logins.set(service, nil) }
        return result
    }

    public static func codex(authFile: URL) async -> FetchResult {
        guard let data = try? Data(contentsOf: authFile),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let token = tokens["access_token"] as? String
        else { return .failed }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountID = tokens["account_id"] as? String {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return await get(request, parse: UsageParser.codex)
    }

    public static func newestCodexLog(in folder: URL) -> FetchResult? {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files.filter { $0.pathExtension == "jsonl" }.max { modified($0) < modified($1) }
        return newest.flatMap(codexLog)
    }

    private static func modified(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    public static func codexLog(_ file: URL) -> FetchResult? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        return (try? handle.readToEnd()).flatMap(UsageParser.codexLog)
    }

    private static func get(_ request: URLRequest, parse: ([String: Any]) -> FetchResult) async -> FetchResult {
        var request = request
        request.timeoutInterval = 20
        request.setValue("Relaybar/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await http.data(for: request), let http = response as? HTTPURLResponse else {
            return .failed
        }
        return UsageParser.response(
            status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"), parse: parse)
    }

    private static let logins = LoginCache()

    private static func keychainLogin(_ service: String) -> Login? {
        guard let secret = keychainSecret(service),
            let oauth = (try? JSONSerialization.jsonObject(with: secret) as? [String: Any])?["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String
        else { return nil }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Login(token: token, expiresAt: expiresAt ?? .distantFuture)
    }

    // Claude Code writes these items with /usr/bin/security, so reading through it avoids a Keychain prompt.
    private static func keychainSecret(_ service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

public enum UsageParser {
    public static func response(
        status: Int, body: Data, retryAfter: String?, parse: ([String: Any]) -> FetchResult
    ) -> FetchResult {
        switch status {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return .failed }
            return parse(json)
        case 401, 403:
            return .expired
        case 429:
            return .rateLimited(retryAfter: retryAfter.flatMap(TimeInterval.init).flatMap { $0 > 0 ? $0 : nil })
        default:
            return .failed
        }
    }

    public static func claude(_ json: [String: Any]) -> FetchResult {
        let limits = json["limits"] as? [[String: Any]] ?? []
        func window(_ kind: String, legacy: String) -> Window? {
            if let limit = limits.first(where: { $0["kind"] as? String == kind }),
                let percent = (limit["percent"] as? NSNumber)?.doubleValue
            {
                return Window(used: percent, resetsAt: isoDate(limit["resets_at"]))
            }
            if let limit = json[legacy] as? [String: Any], let percent = (limit["utilization"] as? NSNumber)?.doubleValue {
                return Window(used: percent, resetsAt: isoDate(limit["resets_at"]))
            }
            return nil
        }
        return .ok(session: window("session", legacy: "five_hour"), weekly: window("weekly_all", legacy: "seven_day"))
    }

    public static func codex(_ json: [String: Any]) -> FetchResult {
        let limits = json["rate_limit"] as? [String: Any] ?? [:]
        return split(
            ["primary_window", "secondary_window"].compactMap { limits[$0] as? [String: Any] },
            used: "used_percent", reset: "reset_at", length: { ($0["limit_window_seconds"] as? NSNumber)?.doubleValue ?? 604_800 })
    }

    public static func codexLog(_ data: Data) -> FetchResult? {
        let marker = Data("\"rate_limits\"".utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let limits = (entry["payload"] as? [String: Any])?["rate_limits"] as? [String: Any],
                (limits["limit_id"] as? String ?? "codex") == "codex"
            else { continue }
            let result = split(
                ["primary", "secondary"].compactMap { limits[$0] as? [String: Any] },
                used: "used_percent", reset: "resets_at",
                length: { (($0["window_minutes"] as? NSNumber)?.doubleValue ?? 10_080) * 60 })
            if result != .ok(session: nil, weekly: nil) { return result }
        }
        return nil
    }

    private static func split(
        _ entries: [[String: Any]], used: String, reset: String, length: ([String: Any]) -> Double
    ) -> FetchResult {
        let windows: [(seconds: Double, window: Window)] = entries.compactMap { entry in
            guard let percent = (entry[used] as? NSNumber)?.doubleValue else { return nil }
            let resetsAt = (entry[reset] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return (length(entry), Window(used: percent, resetsAt: resetsAt))
        }
        return .ok(
            session: windows.first { $0.seconds <= 6 * 3600 }?.window,
            weekly: windows.first { $0.seconds > 6 * 3600 }?.window)
    }

    static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}

struct Login: Sendable {
    let token: String
    let expiresAt: Date
}

actor LoginCache {
    private var logins: [String: Login] = [:]

    func get(_ service: String) -> Login? { logins[service] }

    func set(_ service: String, _ login: Login?) { logins[service] = login }
}
