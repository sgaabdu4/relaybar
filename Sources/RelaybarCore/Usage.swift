import Foundation

struct Window: Sendable {
    let used: Double
    let resetsAt: Date?

    var left: Int {
        if let resetsAt, resetsAt < Date() { return 100 }
        return max(0, 100 - Int(used.rounded()))
    }
}

enum FetchResult: Sendable {
    case ok(session: Window?, weekly: Window?)
    case expired
    case rateLimited(retryAfter: TimeInterval?)
    case failed
}

enum Fetch {
    private static let http = URLSession(configuration: .ephemeral)

    static func claude(service: String) async -> FetchResult {
        guard let secret = await Task.detached(operation: { keychainSecret(service) }).value,
              let root = try? JSONSerialization.jsonObject(with: secret) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return .failed }
        if let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           expiresAt / 1000 < Date().timeIntervalSince1970 {
            return .expired
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return await get(request) { json in
            let limits = json["limits"] as? [[String: Any]] ?? []
            func window(_ kind: String, legacy: String) -> Window? {
                if let limit = limits.first(where: { $0["kind"] as? String == kind }),
                   let percent = (limit["percent"] as? NSNumber)?.doubleValue {
                    return Window(used: percent, resetsAt: isoDate(limit["resets_at"]))
                }
                if let limit = json[legacy] as? [String: Any],
                   let percent = (limit["utilization"] as? NSNumber)?.doubleValue {
                    return Window(used: percent, resetsAt: isoDate(limit["resets_at"]))
                }
                return nil
            }
            return .ok(session: window("session", legacy: "five_hour"),
                       weekly: window("weekly_all", legacy: "seven_day"))
        }
    }

    static func codex(authFile: URL) async -> FetchResult {
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
        return await get(request) { json in
            let limits = json["rate_limit"] as? [String: Any]
            let windows: [(seconds: Double, window: Window)] = ["primary_window", "secondary_window"]
                .compactMap { limits?[$0] as? [String: Any] }
                .compactMap { entry in
                    guard let used = (entry["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                    let seconds = (entry["limit_window_seconds"] as? NSNumber)?.doubleValue ?? 604_800
                    let reset = (entry["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    return (seconds, Window(used: used, resetsAt: reset))
                }
            return .ok(session: windows.first { $0.seconds <= 6 * 3600 }?.window,
                       weekly: windows.first { $0.seconds > 6 * 3600 }?.window)
        }
    }

    static func codexLog(_ file: URL) -> FetchResult? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let marker = Data("\"rate_limits\"".utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let limits = (entry["payload"] as? [String: Any])?["rate_limits"] as? [String: Any],
                  (limits["limit_id"] as? String ?? "codex") == "codex"
            else { continue }
            let windows: [(minutes: Double, window: Window)] = ["primary", "secondary"]
                .compactMap { limits[$0] as? [String: Any] }
                .compactMap { entry in
                    guard let used = (entry["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                    let minutes = (entry["window_minutes"] as? NSNumber)?.doubleValue ?? 10_080
                    let reset = (entry["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    return (minutes, Window(used: used, resetsAt: reset))
                }
            guard !windows.isEmpty else { continue }
            return .ok(session: windows.first { $0.minutes <= 360 }?.window,
                       weekly: windows.first { $0.minutes > 360 }?.window)
        }
        return nil
    }

    private static func get(_ request: URLRequest, parse: ([String: Any]) -> FetchResult) async -> FetchResult {
        var request = request
        request.timeoutInterval = 20
        request.setValue("Relaybar/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await http.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return .failed }
        switch status {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failed }
            return parse(json)
        case 401, 403:
            return .expired
        case 429:
            let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init).flatMap { $0 > 0 ? $0 : nil }
            return .rateLimited(retryAfter: retry)
        default:
            return .failed
        }
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

    private static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
