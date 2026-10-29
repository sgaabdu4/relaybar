import Foundation
import Testing

@testable import RelaybarCore

struct PoolAPITests {
    private func api(_ http: FakeHTTP) -> PoolManagement { PoolManagement(secret: "msecret", http: http.client) }

    @Test func listsCredentialsFromTheRealShape() async throws {
        let http = FakeHTTP()
        http.handler = { _ in ok(sampleCredentials) }
        let list = try await api(http).credentials()
        #expect(list.count == 2)
        #expect(
            list[0]
                == PoolCredential(
                    name: "claude-ann@example.com.json", authIndex: "idx-ann", email: "ann@example.com", kind: .claude,
                    disabled: false,
                    status: "active", modified: "2026-10-29T07:20:14.948138439Z"))
        #expect(list[1].kind == .codex)
        #expect(list[1].disabled)
        #expect(list.map(\.priority) == [0, 7])
        let request = try #require(http.requests.first)
        #expect(request.url.absoluteString == "http://127.0.0.1:8317/v8/management/credentials")
        #expect(request.headers["Authorization"] == "Bearer msecret")
    }

    @Test func skipsLoginsOfOtherProviders() async throws {
        let http = FakeHTTP()
        http.handler = { _ in ok(["files": [["name": "x.json", "auth_index": "1", "provider": "kimi"], ["name": "y"]]]) }
        #expect(try await api(http).credentials().isEmpty)
    }

    @Test func pausesResumesAndSignsOut() async throws {
        let http = FakeHTTP()
        http.handler = { _ in ok(["status": "ok"]) }
        let management = api(http)
        try await management.setPaused(name: "claude-ann@example.com.json", paused: true)
        try await management.setPaused(name: "claude-ann@example.com.json", paused: false)
        try await management.signOut(name: "claude-ann@example.com.json")
        let requests = http.requests
        #expect(requests[0].method == "PATCH")
        #expect(requests[0].url.path == "/v8/management/credentials/status")
        let first = try #require(try JSONSerialization.jsonObject(with: requests[0].body ?? Data()) as? [String: Any])
        #expect(first["name"] as? String == "claude-ann@example.com.json")
        #expect(first["disabled"] as? Bool == true)
        let second = try #require(try JSONSerialization.jsonObject(with: requests[1].body ?? Data()) as? [String: Any])
        #expect(second["disabled"] as? Bool == false)
        #expect(requests[2].method == "DELETE")
        #expect(requests[2].url.query == "name=claude-ann@example.com.json")
    }

    @Test func readsUsageThroughTheRequestCall() async throws {
        let http = FakeHTTP()
        let body =
            #"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":40,"resets_at":"2099-01-02T00:00:00Z"}}"#
        http.handler = { _ in ok(["status_code": 200, "header": ["Content-Type": ["application/json"]], "body": body]) }
        let credential = PoolCredential(
            name: "n", authIndex: "idx", email: "a@example.com", kind: .claude, disabled: false, status: "active")
        let result = await api(http).usage(of: credential)
        guard case .ok(let session, let weekly) = result else {
            Issue.record("not ok: \(result)")
            return
        }
        #expect(session?.left == 75)
        #expect(weekly?.left == 60)
        let sent = try #require(try JSONSerialization.jsonObject(with: http.requests[0].body ?? Data()) as? [String: Any])
        #expect(sent["auth_index"] as? String == "idx")
        #expect(sent["url"] as? String == "https://api.anthropic.com/api/oauth/usage")
        let headers = try #require(sent["header"] as? [String: String])
        #expect(headers["Authorization"] == "Bearer $TOKEN$")
        #expect(headers["anthropic-beta"] == "oauth-2025-04-20")
    }

    @Test func readsCodexUsageAndErrors() async {
        let http = FakeHTTP()
        let codex = PoolCredential(name: "n", authIndex: "idx", email: "a@example.com", kind: .codex, disabled: false, status: "active")
        let body = #"{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":4070908800,"limit_window_seconds":18000}}}"#
        http.handler = { _ in ok(["status_code": 200, "body": body]) }
        let result = await api(http).usage(of: codex)
        if case .ok(let session, _) = result { #expect(session?.left == 90) } else { Issue.record("not ok") }
        #expect(http.requests[0].url.path == "/v8/management/requests/api-call")
        let sent = (try? JSONSerialization.jsonObject(with: http.requests[0].body ?? Data())) as? [String: Any]
        #expect(sent?["url"] as? String == "https://chatgpt.com/backend-api/wham/usage")
        http.handler = { _ in ok(["status_code": 401, "body": "{}"]) }
        #expect(await api(http).usage(of: codex) == .expired)
        http.handler = { _ in ok(["status_code": 429, "header": ["Retry-After": ["30"]], "body": "{}"]) }
        #expect(await api(http).usage(of: codex) == .rateLimited(retryAfter: 30))
        http.handler = { _ in nil }
        #expect(await api(http).usage(of: codex) == .failed)
    }

    @Test func checksTheHelperIsUp() async {
        let http = FakeHTTP()
        http.handler = { $0.headers["Authorization"] == nil ? HTTPResponse(status: 401) : HTTPResponse(status: 200) }
        let management = api(http)
        #expect(await management.isUp())
        #expect(await management.modelsAnswer(accessKey: "k"))
        http.handler = { _ in nil }
        #expect(await !management.isUp())
        #expect(await !management.modelsAnswer(accessKey: "k"))
    }

    @Test func explainsFailures() async {
        let http = FakeHTTP()
        http.handler = { _ in nil }
        await #expect(throws: PoolError.unreachable) { try await api(http).credentials() }
        http.handler = { _ in HTTPResponse(status: 401, body: Data()) }
        await #expect(throws: PoolError.rejected(401)) { try await api(http).signOut(name: "x") }
        http.handler = { _ in HTTPResponse(status: 200, body: Data("nope".utf8)) }
        await #expect(throws: PoolError.badAnswer) { try await api(http).credentials() }
        http.handler = { _ in ok(["files": "no"]) }
        await #expect(throws: PoolError.badAnswer) { try await api(http).credentials() }
        for error in [PoolError.unreachable, .rejected(500), .badAnswer] { #expect(error.errorDescription?.isEmpty == false) }
    }

    @Test func signInStatusAnswers() async throws {
        let http = FakeHTTP()
        let management = api(http)
        http.handler = { _ in ok(["status": "wait"]) }
        #expect(try await management.signInStatus(state: "s") == .wait)
        http.handler = { _ in ok(["status": "ok"]) }
        #expect(try await management.signInStatus(state: "s") == .ok)
        http.handler = { _ in HTTPResponse(status: 400, body: json(["status": "error", "error": "unknown or expired state"])) }
        #expect(try await management.signInStatus(state: "s") == .error("unknown or expired state"))
        http.handler = { _ in ok(["status": "weird"]) }
        await #expect(throws: PoolError.badAnswer) { try await management.signInStatus(state: "s") }
        await management.cancelSignIn(state: "s")
        #expect(http.requests.last?.method == "DELETE")
        #expect(http.requests.last?.url.path == "/v8/management/oauth/session")
    }

    @Test func callbackPostCarriesNoManagementKey() async throws {
        let http = FakeHTTP()
        http.handler = { _ in ok(["status": "ok"]) }
        try await api(http).submitCallback(kind: .codex, code: "c", state: "s")
        let request = try #require(http.requests.first)
        #expect(request.headers["Authorization"] == nil)
        let sent = try #require(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: String])
        #expect(sent == ["provider": "codex", "code": "c", "state": "s"])
    }
}
