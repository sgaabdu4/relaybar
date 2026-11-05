import Foundation

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(_ method: String = "GET", _ url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }
}

public typealias HTTPClient = @Sendable (HTTPRequest) async -> HTTPResponse?

public enum PoolHTTP {
    private static let session = URLSession(configuration: .ephemeral)

    public static let live: HTTPClient = { request in
        var built = URLRequest(url: request.url)
        built.httpMethod = request.method
        built.httpBody = request.body
        built.timeoutInterval = 20
        for (name, value) in request.headers { built.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await session.data(for: built), let http = response as? HTTPURLResponse else { return nil }
        return HTTPResponse(status: http.statusCode, body: data)
    }
}

public enum PoolKind: String, Codable, Sendable {
    case claude
    case codex

    public var callbackPort: UInt16 { self == .claude ? 54545 : 1455 }
    public var callbackPath: String { self == .claude ? "/callback" : "/auth/callback" }
}

public struct PoolCredential: Equatable, Sendable {
    public let name: String
    public let authIndex: String
    public let email: String
    public let kind: PoolKind
    public let disabled: Bool
    public let status: String
    public let modified: String
    public let priority: Int

    public init(
        name: String, authIndex: String, email: String, kind: PoolKind, disabled: Bool, status: String, modified: String = "",
        priority: Int = 0
    ) {
        self.name = name
        self.authIndex = authIndex
        self.email = email
        self.kind = kind
        self.disabled = disabled
        self.status = status
        self.modified = modified
        self.priority = priority
    }

    public var needsSignIn: Bool { ["error", "expired", "unauthorized", "invalid"].contains(status) }
}

public enum OAuthStatus: Equatable, Sendable {
    case wait
    case ok
    case error(String)
}

public enum PoolError: Error, Equatable, LocalizedError {
    case unreachable
    case rejected(Int)
    case badAnswer

    public var errorDescription: String? {
        switch self {
        case .unreachable: return "Relaybar cannot reach the helper. Check that it runs, then try again."
        case .rejected(let status): return "The helper refused the request (code \(status)). Try again."
        case .badAnswer: return "The helper gave an answer Relaybar does not understand. Update Relaybar, then try again."
        }
    }
}

public struct PoolManagement: Sendable {
    public let base: URL
    private let secret: String
    private let http: HTTPClient

    public init(base: URL = Pool.base, secret: String, http: @escaping HTTPClient) {
        self.base = base
        self.secret = secret
        self.http = http
    }

    private func call(
        _ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil, signed: Bool = true
    ) async throws -> [String: Any] {
        var parts = URLComponents(url: base.appendingPathComponent("v8/management/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var headers: [String: String] = [:]
        if signed { headers["Authorization"] = "Bearer " + secret }
        var data: Data?
        if let body {
            headers["Content-Type"] = "application/json"
            data = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let response = await http(HTTPRequest(method, parts.url!, headers: headers, body: data)) else { throw PoolError.unreachable }
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        guard (200..<300).contains(response.status) else {
            if path == "oauth/status", let json { return json }
            throw PoolError.rejected(response.status)
        }
        guard let json else { throw PoolError.badAnswer }
        return json
    }

    public func isUp() async -> Bool {
        let request = HTTPRequest("GET", base.appendingPathComponent("v1/models"))
        return await http(request)?.status == 401
    }

    public func modelsAnswer(accessKey: String) async -> Bool {
        let request = HTTPRequest("GET", base.appendingPathComponent("v1/models"), headers: ["Authorization": "Bearer " + accessKey])
        return await http(request)?.status == 200
    }

    public func credentials() async throws -> [PoolCredential] {
        let json = try await call("GET", "credentials")
        guard let files = json["files"] as? [[String: Any]] else { throw PoolError.badAnswer }
        return files.compactMap { file in
            guard let name = file["name"] as? String, let authIndex = file["auth_index"] as? String,
                let kind = (file["provider"] as? String).flatMap(PoolKind.init(rawValue:))
            else { return nil }
            let email = (file["email"] as? String) ?? (file["account"] as? String) ?? ""
            return PoolCredential(
                name: name, authIndex: authIndex, email: email, kind: kind, disabled: file["disabled"] as? Bool ?? false,
                status: file["status"] as? String ?? "", modified: file["modtime"] as? String ?? "",
                priority: (file["priority"] as? NSNumber)?.intValue ?? 0)
        }
    }

    public func setPaused(name: String, paused: Bool) async throws {
        _ = try await call("PATCH", "credentials/status", body: ["name": name, "disabled": paused])
    }

    public func setPriority(name: String, priority: Int) async throws {
        _ = try await call("PATCH", "credentials/fields", body: ["name": name, "priority": priority])
    }

    public func signOut(name: String) async throws {
        _ = try await call("DELETE", "credentials", query: ["name": name])
    }

    public func usage(of credential: PoolCredential) async -> FetchResult {
        let url =
            credential.kind == .claude ? "https://api.anthropic.com/api/oauth/usage" : "https://chatgpt.com/backend-api/wham/usage"
        var headers = ["Authorization": "Bearer $TOKEN$", "User-Agent": "Relaybar/1.0"]
        if credential.kind == .claude { headers["anthropic-beta"] = "oauth-2025-04-20" }
        let body: [String: Any] = ["auth_index": credential.authIndex, "method": "GET", "url": url, "header": headers]
        guard let json = try? await call("POST", "requests/api-call", body: body), let status = json["status_code"] as? Int else {
            return .failed
        }
        let retry = ((json["header"] as? [String: Any])?["Retry-After"] as? [String])?.first
        return UsageParser.response(
            status: status, body: Data((json["body"] as? String ?? "").utf8), retryAfter: retry,
            parse: credential.kind == .claude ? UsageParser.claude : UsageParser.codex)
    }

    public func authLink(for kind: PoolKind) async throws -> PoolSignInLink {
        let json = try await call("GET", "oauth/auth-url", query: ["provider": kind.rawValue])
        guard let link = PoolSignInLink(kind: kind, answer: json) else { throw PoolError.badAnswer }
        return link
    }

    public func submitCallback(kind: PoolKind, code: String, state: String) async throws {
        _ = try await call("POST", "oauth/callback", body: ["provider": kind.rawValue, "code": code, "state": state], signed: false)
    }

    public func signInStatus(state: String) async throws -> OAuthStatus {
        let json = try await call("GET", "oauth/status", query: ["state": state])
        switch json["status"] as? String {
        case "wait": return .wait
        case "ok": return .ok
        case "error": return .error(json["error"] as? String ?? "Sign-in failed.")
        default: throw PoolError.badAnswer
        }
    }

    public func cancelSignIn(state: String) async {
        _ = try? await call("DELETE", "oauth/session", query: ["state": state])
    }
}
