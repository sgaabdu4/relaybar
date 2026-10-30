import Foundation
import Network

public struct PoolSignInLink: Equatable, Sendable {
    public let kind: PoolKind
    public let url: URL
    public let state: String
    public let port: UInt16
    public let path: String

    public init?(kind: PoolKind, answer: [String: Any]) {
        guard let text = answer["url"] as? String, let url = URL(string: text), let state = answer["state"] as? String,
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let redirect = items.first(where: { $0.name == "redirect_uri" })?.value.flatMap(URLComponents.init(string:)),
            ["localhost", "127.0.0.1"].contains(redirect.host ?? ""), let port = redirect.port.flatMap(UInt16.init(exactly:))
        else { return nil }
        self.kind = kind
        self.url = url
        self.state = state
        self.port = port
        self.path = redirect.path
    }
}

public struct SignInCallback: Equatable, Sendable {
    public let code: String?
    public let state: String
    public let error: String?

    public static func parse(head: String, path: String) -> SignInCallback? {
        guard let line = head.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let target = URLComponents(string: String(parts[1])), target.path == path else {
            return nil
        }
        let items = Dictionary(
            (target.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard let state = items["state"] else { return nil }
        return SignInCallback(code: items["code"], state: state, error: items["error_description"] ?? items["error"])
    }
}

public struct SignInRequest: Sendable {
    public let callback: SignInCallback
    public let reply: @Sendable (String) -> Void

    public init(callback: SignInCallback, reply: @escaping @Sendable (String) -> Void) {
        self.callback = callback
        self.reply = reply
    }
}

public protocol CallbackSource: Sendable {
    func next(timeout: TimeInterval) async -> SignInRequest?
    func close()
}

public enum LoopbackError: Error, Equatable {
    case busy
    case failed
}

public final class LoopbackListener: CallbackSource, @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "relaybar.loopback")
    private let stream: AsyncStream<SignInRequest>
    private let output: AsyncStream<SignInRequest>.Continuation
    public private(set) var port: UInt16 = 0

    private init(listener: NWListener, path: String) {
        self.listener = listener
        (stream, output) = AsyncStream<SignInRequest>.makeStream()
        listener.newConnectionHandler = { [output, queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let head = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let reply: @Sendable (String, Int) -> Void = { text, status in
                    let body = Data(text.utf8)
                    let header =
                        "HTTP/1.1 \(status) OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(
                        content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                }
                if let callback = SignInCallback.parse(head: head, path: path) {
                    output.yield(SignInRequest(callback: callback, reply: { reply($0, 200) }))
                } else {
                    reply("Not found", 404)
                }
            }
        }
    }

    public static func start(port: UInt16, path: String) async throws -> LoopbackListener {
        let parameters = NWParameters.tcp
        guard let number = NWEndpoint.Port(rawValue: port) else { throw LoopbackError.failed }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: number)
        guard let listener = try? NWListener(using: parameters) else { throw LoopbackError.failed }
        let server = LoopbackListener(listener: listener, path: path)
        try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.first() { waiting.resume() }
                case .failed(let error):
                    if once.first() {
                        waiting.resume(throwing: error == .posix(.EADDRINUSE) ? LoopbackError.busy : LoopbackError.failed)
                    }
                default:
                    break
                }
            }
            listener.start(queue: server.queue)
        }
        server.port = listener.port?.rawValue ?? port
        return server
    }

    public func next(timeout: TimeInterval) async -> SignInRequest? {
        await withTaskGroup(of: SignInRequest?.self) { group in
            group.addTask { [stream] in
                for await request in stream { return request }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    public func close() {
        listener.cancel()
        output.finish()
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

public enum SignInOutcome: Equatable, Sendable {
    case signedIn(email: String)
    case sameAccount(email: String)
    case portBusy(port: UInt16, holder: String?)
    case timedOut
    case failed(String)

    public var message: String {
        switch self {
        case .signedIn(let email): return "Signed in as \(email)."
        case .sameAccount(let email):
            let name = email.isEmpty ? "This account" : email
            return "\(name) was already signed in. To add a different account, sign out in the browser first, then try again."
        case .portBusy(let port, let holder):
            return "Port \(port) is in use by \(holder ?? "another app"). Finish that sign-in or quit that app, then try again."
        case .timedOut: return "Sign-in took too long. Click the account again to try once more."
        case .failed(let reason): return reason
        }
    }
}

public enum SignInResult: Equatable, Sendable {
    case credited(String)
    case wrong(email: String)
    case unfinished(SignInOutcome)
}

public struct PoolSignIn: Sendable {
    public let management: PoolManagement
    public let run: CommandRunner
    public let open: @Sendable (URL) -> Void
    public let listen: @Sendable (UInt16, String) async throws -> CallbackSource
    public let pause: @Sendable (TimeInterval) async -> Void
    public let waitForBrowser: TimeInterval
    public let waitForHelper: TimeInterval

    public init(
        management: PoolManagement, run: @escaping CommandRunner = PoolProcess.run, open: @escaping @Sendable (URL) -> Void,
        listen: @escaping @Sendable (UInt16, String) async throws -> CallbackSource = { port, path in
            try await LoopbackListener.start(port: port, path: path)
        },
        pause: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        waitForBrowser: TimeInterval = 300, waitForHelper: TimeInterval = 60
    ) {
        self.management = management
        self.run = run
        self.open = open
        self.listen = listen
        self.pause = pause
        self.waitForBrowser = waitForBrowser
        self.waitForHelper = waitForHelper
    }

    public static func portHolder(port: UInt16, run: CommandRunner) -> String? {
        let result = run(Command("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fc"], limit: 15))
        return result.output.split(separator: "\n").first { $0.hasPrefix("c") }.map { String($0.dropFirst()) }
    }

    public func signIn(kind: PoolKind) async -> SignInOutcome {
        let before: [PoolCredential]
        let link: PoolSignInLink
        do {
            before = try await management.credentials()
            link = try await management.authLink(for: kind)
        } catch {
            return .failed(error.localizedDescription)
        }
        let source: CallbackSource
        do {
            source = try await listen(link.port, link.path)
        } catch LoopbackError.busy {
            await management.cancelSignIn(state: link.state)
            return .portBusy(port: link.port, holder: Self.portHolder(port: link.port, run: run))
        } catch {
            await management.cancelSignIn(state: link.state)
            return .failed("Relaybar could not listen for the browser on port \(link.port). Try again.")
        }
        defer { source.close() }
        open(link.url)
        let deadline = Date().addingTimeInterval(waitForBrowser)
        while Date() < deadline {
            guard let request = await source.next(timeout: deadline.timeIntervalSinceNow) else { break }
            guard request.callback.state == link.state else {
                request.reply("This sign-in link is old. Go back to Relaybar and start again.")
                continue
            }
            if let reason = request.callback.error {
                request.reply("Sign-in failed. Go back to Relaybar.")
                await management.cancelSignIn(state: link.state)
                return .failed("The browser said: \(reason)")
            }
            return await finish(request, link: link, before: before)
        }
        await management.cancelSignIn(state: link.state)
        return .timedOut
    }

    private func finish(_ request: SignInRequest, link: PoolSignInLink, before: [PoolCredential]) async -> SignInOutcome {
        do {
            try await management.submitCallback(kind: link.kind, code: request.callback.code ?? "", state: link.state)
            let deadline = Date().addingTimeInterval(waitForHelper)
            while Date() < deadline {
                switch try await management.signInStatus(state: link.state) {
                case .wait:
                    await pause(1)
                case .ok:
                    request.reply("Signed in. You can close this tab.")
                    return Self.outcome(before: before, after: try await management.credentials(), kind: link.kind)
                case .error(let reason):
                    request.reply("Sign-in failed. Go back to Relaybar.")
                    return .failed("The helper could not finish the sign-in: \(reason)")
                }
            }
            request.reply("Sign-in took too long. Go back to Relaybar.")
            return .timedOut
        } catch {
            request.reply("Sign-in failed. Go back to Relaybar.")
            return .failed(error.localizedDescription)
        }
    }

    public func isLive(_ link: URL) async -> Bool {
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems
        guard let state = items?.first(where: { $0.name == "state" })?.value else { return false }
        if case .wait? = try? await management.signInStatus(state: state) { return true }
        return false
    }

    public static func verdict(
        _ outcome: SignInOutcome, for row: PoolAccountInput, in accounts: [PoolAccountInput], done: Set<String>
    ) -> SignInResult {
        let email: String
        switch outcome {
        case .signedIn(let found), .sameAccount(let found): email = found
        default: return .unfinished(outcome)
        }
        let key = email.lowercased()
        guard !key.isEmpty else { return .unfinished(outcome) }
        if row.email?.lowercased() == key { return .credited(row.id) }
        let other = accounts.first { $0.kind == row.kind && !done.contains($0.id) && $0.email?.lowercased() == key }
        return other.map { .credited($0.id) } ?? .wrong(email: email)
    }

    public func settle(
        _ outcome: SignInOutcome, for row: PoolAccountInput, in accounts: [PoolAccountInput], done: Set<String>
    ) async -> SignInResult {
        let result = Self.verdict(outcome, for: row, in: accounts, done: done)
        guard case .wrong(let email) = result, case .signedIn = outcome else { return result }
        let key = email.lowercased()
        guard !accounts.contains(where: { $0.kind == row.kind && $0.email?.lowercased() == key }),
            let logins = try? await management.credentials()
        else { return result }
        for login in logins where login.kind == row.kind && login.email.lowercased() == key {
            try? await management.signOut(name: login.name)
        }
        return result
    }

    public static func outcome(before: [PoolCredential], after: [PoolCredential], kind: PoolKind) -> SignInOutcome {
        let known = Set(before.map(\.name))
        if let added = after.first(where: { $0.kind == kind && !known.contains($0.name) }) { return .signedIn(email: added.email) }
        let changed = after.first { current in
            current.kind == kind && before.first { $0.name == current.name }.map { $0.modified != current.modified } == true
        }
        if let changed { return .sameAccount(email: changed.email) }
        return .sameAccount(email: "")
    }
}
