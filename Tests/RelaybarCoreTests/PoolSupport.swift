import Foundation

@testable import RelaybarCore

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Command] = []
    private var kept: [String: String] = [:]
    var remembersKeys = true
    var respond: @Sendable (Command) -> CommandResult = { _ in CommandResult() }

    var commands: [Command] {
        lock.withLock { log }
    }

    var runner: CommandRunner {
        { [self] command in
            lock.withLock { log.append(command) }
            let result = respond(command)
            return remembersKeys ? keychain(command, result) : result
        }
    }

    private func keychain(_ command: Command, _ result: CommandResult) -> CommandResult {
        guard command.executable == "/usr/bin/security" else { return result }
        if command.arguments == ["-i"], result.succeeded, let line = command.stdin.map({ String(decoding: $0, as: UTF8.self) }) {
            let parts = line.components(separatedBy: "\"")
            if parts.count > 5 { lock.withLock { kept[parts[3]] = parts[5] } }
        } else if command.arguments.first == "delete-generic-password", let service = command.arguments.last {
            lock.withLock { kept[service] = nil }
        } else if command.arguments.first == "find-generic-password", let service = command.arguments.dropFirst(2).first,
            let secret = lock.withLock({ kept[service] })
        {
            return CommandResult(output: secret + "\n")
        }
        return result
    }

    func ran(_ executable: String, containing text: String) -> Bool {
        commands.contains { $0.executable == executable && $0.arguments.joined(separator: " ").contains(text) }
    }
}

final class FakeHTTP: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [HTTPRequest] = []
    var handler: @Sendable (HTTPRequest) -> HTTPResponse? = { _ in nil }

    var requests: [HTTPRequest] {
        lock.withLock { log }
    }

    var client: HTTPClient {
        { [self] request in
            lock.withLock { log.append(request) }
            return handler(request)
        }
    }
}

func json(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

func ok(_ object: Any) -> HTTPResponse {
    HTTPResponse(status: 200, body: json(object))
}

final class Trashed: @unchecked Sendable {
    var urls: [URL] = []
}

struct Harness {
    let home: Fixture
    let recorder = Recorder()
    let http = FakeHTTP()
    let trashed = Trashed()
    let script = Data("#!/bin/sh\necho script\n".utf8)

    init() throws {
        home = try Fixture()
    }

    func env(
        t3: Bool = true, script: Bool = true, openURL: @escaping @Sendable (URL) -> Void = { _ in },
        pause: @escaping @Sendable (TimeInterval) async -> Void = { _ in }
    ) -> PoolEnvironment {
        let trashed = trashed
        return PoolEnvironment(
            home: home.root, uid: 501, run: recorder.runner, http: http.client,
            trash: { url in
                trashed.urls.append(url)
                try FileManager.default.removeItem(at: url)
            }, script: script ? self.script : nil, t3Installed: t3, openURL: openURL, pause: pause)
    }

    var paths: PoolPaths { PoolPaths(home: home.root) }
}

let sampleCredentials: [String: Any] = [
    "files": [
        [
            "account": "ann@example.com", "account_type": "oauth", "auth_index": "idx-ann", "disabled": false,
            "email": "ann@example.com", "id": "claude-ann@example.com.json", "label": "ann@example.com",
            "modtime": "2026-10-29T07:20:14.948138439Z", "name": "claude-ann@example.com.json", "provider": "claude",
            "runtime_only": false, "source": "file", "status": "active", "type": "claude", "unavailable": false,
        ],
        [
            "account": "bob@example.com", "account_type": "oauth", "auth_index": "idx-bob", "disabled": true,
            "email": "bob@example.com", "id": "codex-bob@example.com-plus.json", "modtime": "2026-10-29T07:20:14.950270646Z",
            "name": "codex-bob@example.com-plus.json", "provider": "codex", "runtime_only": false, "source": "file",
            "status": "disabled", "priority": 7, "type": "codex", "unavailable": false,
        ],
    ],
    "observed_at": "2026-10-29T07:20:19.0148Z",
]

func plainScript(_ command: Command) -> String {
    remoteScript(command).replacingOccurrences(of: "'\\''", with: "'")
}

struct FakeClientHost: Sendable {
    static let hubFacts =
        "user=sam\nid=hubid\nport=22\naddr=192.168.1.20\naddr=172.17.0.1\nts=100.64.0.7\nhostkey=ssh-ed25519 AAAAhubkey root@hub\n"
    static let probe = "new:.claude-hub\nnew:.codex-hub\nnew:.config/relaybar\nlinger:off\nid=laptopid"

    var system = "Linux\n"
    var probe = Self.probe
    var facts = Self.hubFacts
    var route = "ok:192.168.1.20\n"
    var tunnel = "up\n"
    var settings = ""
    var hubAdds = ""

    func answer(_ command: Command) -> CommandResult? {
        guard command.executable == "/usr/bin/ssh" else { return nil }
        let text = remoteScript(command)
        if text.contains("uname -s") { return CommandResult(output: system) }
        if text.contains("printf %s \"$HOME\"") { return CommandResult(output: "/home/sam") }
        if text.contains("for d in") { return CommandResult(output: probe) }
        if text.contains("hostkey=") { return CommandResult(output: facts) }
        if text.contains("ssh-keygen") { return CommandResult(output: "ssh-ed25519 AAAAclientkey\n") }
        if text.contains("authorized_keys"), text.contains("cat >> ") { return CommandResult(output: hubAdds) }
        if text.contains("echo ok:$a") { return CommandResult(output: route) }
        if text.contains("&& echo changed:linger") { return CommandResult(output: "changed:linger\n") }
        if text.contains("http_code") { return CommandResult(output: tunnel) }
        if text.contains("[ -f \"$f\" ] && cat") { return CommandResult(output: settings) }
        return nil
    }
}

extension Harness {
    func answerHomeAndComputers(_ host: FakeClientHost = FakeClientHost()) {
        let up = Flag()
        recorder.respond = { command in
            let text = command.executable == "/usr/bin/ssh" ? remoteScript(command) : ""
            if text.contains("join.json\" ]") { return CommandResult(output: "000") }
            if text.contains("mkdir -m 700") { return CommandResult(output: "claimed") }
            if command.executable == "/bin/launchctl", command.arguments.first == "bootstrap" { up.on = true }
            return host.answer(command) ?? CommandResult()
        }
        http.handler = { request in
            guard request.url.path == "/v1/models", up.on else { return nil }
            return HTTPResponse(status: request.headers["Authorization"] == nil ? 401 : 200)
        }
    }
}
