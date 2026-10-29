import Foundation
import Testing

@testable import RelaybarCore

final class FakeSource: CallbackSource, @unchecked Sendable {
    var requests: [SignInRequest?]
    private(set) var closed = false

    init(_ requests: [SignInRequest?]) {
        self.requests = requests
    }

    func next(timeout: TimeInterval) async -> SignInRequest? {
        requests.isEmpty ? nil : requests.removeFirst()
    }

    func close() { closed = true }
}

final class Replies: @unchecked Sendable {
    var texts: [String] = []
}

let claudeAuthURL =
    "https://claude.ai/oauth/authorize?client_id=abc&code=true&code_challenge=xyz&code_challenge_method=S256&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&response_type=code&scope=user%3Aprofile&state=st123"
let codexAuthURL =
    "https://auth.openai.com/oauth/authorize?client_id=app&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&response_type=code&state=st456"

struct PoolSignInTests {
    private func flow(
        kind: PoolKind = .claude, source: CallbackSource?, listenError: Error? = nil, statuses: [String] = ["wait", "ok"],
        before: [[String: Any]] = [], after: [[String: Any]]? = nil, base: URL = Pool.base, run: CommandRunner? = nil
    ) -> (PoolSignIn, FakeHTTP, Recorder, Opened) {
        let http = FakeHTTP()
        let recorder = Recorder()
        let opened = Opened()
        let remaining = Counter(statuses)
        let listCalls = Counter([])
        http.handler = { request in
            switch request.url.path {
            case "/v8/management/credentials":
                listCalls.count += 1
                let files = listCalls.count == 1 ? before : (after ?? before)
                return ok(["files": files])
            case "/v8/management/oauth/auth-url":
                let url = kind == .claude ? claudeAuthURL : codexAuthURL
                return ok(["status": "ok", "state": kind == .claude ? "st123" : "st456", "url": url])
            case "/v8/management/oauth/callback": return ok(["status": "ok"])
            case "/v8/management/oauth/status": return ok(["status": remaining.next()])
            default: return ok(["status": "ok"])
            }
        }
        let management = PoolManagement(base: base, secret: "s", http: http.client)
        let signIn = PoolSignIn(
            management: management, run: run ?? recorder.runner, open: { opened.urls.append($0) },
            listen: { _, _ in
                if let listenError { throw listenError }
                return source!
            }, pause: { _ in }, waitForBrowser: 5, waitForHelper: 5)
        return (signIn, http, recorder, opened)
    }

    private func credential(_ email: String, modified: String) -> [String: Any] {
        [
            "name": "claude-\(email).json", "auth_index": email, "provider": "claude", "email": email, "disabled": false,
            "status": "active",
            "modtime": modified,
        ]
    }

    @Test func readsTheSignInLink() throws {
        let claude = try #require(PoolSignInLink(kind: .claude, answer: ["status": "ok", "state": "st123", "url": claudeAuthURL]))
        #expect(claude.port == 54545)
        #expect(claude.path == "/callback")
        #expect(claude.state == "st123")
        #expect(claude.url.absoluteString == claudeAuthURL)
        let codex = try #require(PoolSignInLink(kind: .codex, answer: ["state": "st456", "url": codexAuthURL]))
        #expect(codex.port == 1455)
        #expect(codex.path == "/auth/callback")
        #expect(
            PoolSignInLink(
                kind: .claude, answer: ["state": "s", "url": "https://x.example/auth?redirect_uri=https%3A%2F%2Fevil.example%2Fcb"]) == nil)
        #expect(PoolSignInLink(kind: .claude, answer: ["url": claudeAuthURL]) == nil)
        #expect(PoolSignInLink(kind: .claude, answer: [:]) == nil)
        #expect(PoolKind.claude.callbackPort == 54545 && PoolKind.codex.callbackPort == 1455)
        #expect(PoolKind.codex.callbackPath == "/auth/callback" && PoolKind.claude.callbackPath == "/callback")
    }

    @Test func parsesTheBrowserReturn() {
        let head = "GET /callback?code=abc%20def&state=st123 HTTP/1.1\r\nHost: localhost:54545\r\n\r\n"
        #expect(SignInCallback.parse(head: head, path: "/callback") == SignInCallback(code: "abc def", state: "st123", error: nil))
        #expect(SignInCallback.parse(head: head, path: "/auth/callback") == nil)
        #expect(SignInCallback.parse(head: "POST /callback?state=s HTTP/1.1", path: "/callback") == nil)
        #expect(SignInCallback.parse(head: "GET /callback?code=c HTTP/1.1", path: "/callback") == nil)
        #expect(SignInCallback.parse(head: "", path: "/callback") == nil)
        #expect(
            SignInCallback.parse(head: "GET /callback?state=s&error=access_denied HTTP/1.1", path: "/callback")?.error == "access_denied")
        #expect(SignInCallback.parse(head: "GET", path: "/callback") == nil)
    }

    @Test func forwardsTheCallback() async throws {
        let replies = Replies()
        let request = SignInRequest(
            callback: SignInCallback(code: "the-code", state: "st123", error: nil), reply: { replies.texts.append($0) })
        let source = FakeSource([request])
        let new = credential("ann@example.com", modified: "t1")
        let (signIn, http, _, opened) = flow(source: source, after: [new])
        let outcome = await signIn.signIn(kind: .claude)
        #expect(outcome == .signedIn(email: "ann@example.com"))
        #expect(opened.urls.map(\.absoluteString) == [claudeAuthURL])
        let post = try #require(http.requests.first { $0.url.path == "/v8/management/oauth/callback" })
        #expect(post.method == "POST")
        let body = try #require(try JSONSerialization.jsonObject(with: post.body ?? Data()) as? [String: String])
        #expect(body == ["provider": "claude", "code": "the-code", "state": "st123"])
        #expect(post.headers["Authorization"] == nil)
        #expect(replies.texts == ["Signed in. You can close this tab."])
        #expect(source.closed)
        #expect(outcome.message == "Signed in as ann@example.com.")
    }

    @Test func forwardsTheCallbackThroughATunnelAddress() async {
        let replies = Replies()
        let request = SignInRequest(callback: SignInCallback(code: "c", state: "st456", error: nil), reply: { replies.texts.append($0) })
        let (signIn, http, _, _) = flow(
            kind: .codex, source: FakeSource([request]), after: [credential("cat@example.com", modified: "t")],
            base: URL(string: "http://127.0.0.1:8317")!)
        _ = await signIn.signIn(kind: .codex)
        #expect(http.requests.allSatisfy { $0.url.host == "127.0.0.1" && $0.url.port == 8317 })
        #expect(http.requests.contains { $0.url.query == "provider=codex" })
    }

    @Test func spotsTheSameAccountTwice() async {
        let replies = Replies()
        let request = SignInRequest(callback: SignInCallback(code: "c", state: "st123", error: nil), reply: { replies.texts.append($0) })
        let (signIn, _, _, _) = flow(
            source: FakeSource([request]), before: [credential("ann@example.com", modified: "t1")],
            after: [credential("ann@example.com", modified: "t2")])
        let outcome = await signIn.signIn(kind: .claude)
        #expect(outcome == .sameAccount(email: "ann@example.com"))
        #expect(outcome.message.contains("sign out in the browser"))
        #expect(PoolSignIn.outcome(before: [], after: [], kind: .claude) == .sameAccount(email: ""))
        #expect(SignInOutcome.sameAccount(email: "").message.contains("This account"))
    }

    @Test func ignoresAnOldLinkAndWaits() async {
        let replies = Replies()
        let old = SignInRequest(callback: SignInCallback(code: "c", state: "stale", error: nil), reply: { replies.texts.append($0) })
        let good = SignInRequest(callback: SignInCallback(code: "c", state: "st123", error: nil), reply: { replies.texts.append($0) })
        let (signIn, _, _, _) = flow(source: FakeSource([old, good]), after: [credential("ann@example.com", modified: "t")])
        let outcome = await signIn.signIn(kind: .claude)
        #expect(outcome == .signedIn(email: "ann@example.com"))
        #expect(replies.texts.first?.contains("old") == true)
    }

    @Test func reportsBrowserErrorsAndTimeouts() async {
        let replies = Replies()
        let denied = SignInRequest(
            callback: SignInCallback(code: nil, state: "st123", error: "access_denied"), reply: { replies.texts.append($0) })
        let (first, http, _, _) = flow(source: FakeSource([denied]))
        #expect(await first.signIn(kind: .claude) == .failed("The browser said: access_denied"))
        #expect(http.requests.contains { $0.method == "DELETE" })
        let (second, _, _, _) = flow(source: FakeSource([nil]))
        #expect(await second.signIn(kind: .claude) == .timedOut)
        #expect(SignInOutcome.timedOut.message.contains("too long"))
    }

    @Test func reportsHelperErrors() async {
        let request = SignInRequest(callback: SignInCallback(code: "c", state: "st123", error: nil), reply: { _ in })
        let (signIn, _, _, _) = flow(source: FakeSource([request]), statuses: ["error"])
        let outcome = await signIn.signIn(kind: .claude)
        #expect(outcome == .failed("The helper could not finish the sign-in: Sign-in failed."))
        let again = SignInRequest(callback: SignInCallback(code: "c", state: "st123", error: nil), reply: { _ in })
        let (_, slowHTTP, _, _) = flow(source: FakeSource([again]), statuses: Array(repeating: "wait", count: 100))
        let quick = PoolSignIn(
            management: PoolManagement(secret: "s", http: slowHTTP.client), open: { _ in }, listen: { _, _ in FakeSource([again]) },
            pause: { _ in }, waitForBrowser: 5,
            waitForHelper: 0)
        #expect(await quick.signIn(kind: .claude) == .timedOut)
    }

    @Test func saysWhichAppHoldsThePort() async {
        let recorder = Recorder()
        recorder.respond = { _ in CommandResult(output: "p4242\ncclaude\n") }
        let (signIn, http, _, _) = flow(source: nil, listenError: LoopbackError.busy, run: recorder.runner)
        let outcome = await signIn.signIn(kind: .claude)
        #expect(outcome == .portBusy(port: 54545, holder: "claude"))
        #expect(outcome.message == "Port 54545 is in use by claude. Finish that sign-in or quit that app, then try again.")
        #expect(http.requests.contains { $0.method == "DELETE" })
        #expect(recorder.ran("/usr/sbin/lsof", containing: "-iTCP:54545"))
        #expect(SignInOutcome.portBusy(port: 1455, holder: nil).message.contains("another app"))
        let (other, _, _, _) = flow(source: nil, listenError: LoopbackError.failed)
        #expect(await other.signIn(kind: .claude) == .failed("Relaybar could not listen for the browser on port 54545. Try again."))
    }

    @Test func failsCleanlyWhenTheHelperIsDown() async {
        let http = FakeHTTP()
        let signIn = PoolSignIn(management: PoolManagement(secret: "s", http: http.client), open: { _ in })
        let outcome = await signIn.signIn(kind: .claude)
        #expect(outcome == .failed(PoolError.unreachable.localizedDescription))
    }

    @Test func theRealListenerAnswersTheBrowser() async throws {
        let listener = try await LoopbackListener.start(port: 0, path: "/callback")
        let port = listener.port
        #expect(port != 0)
        let url = URL(string: "http://127.0.0.1:\(port)/callback?code=abc&state=st1")!
        let task = Task { try await URLSession(configuration: .ephemeral).data(from: url) }
        let request = await listener.next(timeout: 10)
        #expect(request?.callback == SignInCallback(code: "abc", state: "st1", error: nil))
        request?.reply("Signed in. You can close this tab.")
        let (data, response) = try await task.value
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "Signed in. You can close this tab.")
        let (_, missing) = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
        #expect(await listener.next(timeout: 0.1) == nil)
        listener.close()
    }

    @Test func theRealListenerSaysWhenThePortIsTaken() async throws {
        let first = try await LoopbackListener.start(port: 0, path: "/callback")
        await #expect(throws: LoopbackError.busy) { try await LoopbackListener.start(port: first.port, path: "/callback") }
        first.close()
    }
}

final class Opened: @unchecked Sendable {
    var urls: [URL] = []
}

final class Counter: @unchecked Sendable {
    var count = 0
    private var items: [String]

    init(_ items: [String]) {
        self.items = items
    }

    func next() -> String { items.isEmpty ? "wait" : items.removeFirst() }
}
