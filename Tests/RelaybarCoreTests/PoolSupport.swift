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
