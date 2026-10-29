import Foundation

enum PoolPrivileged {
    case done(String)
    case needsPassword
    case failed(String)
}

enum PoolSudo {
    static func attempt(host: String, command: String, password: String?, limit: TimeInterval, run: CommandRunner) -> PoolPrivileged {
        let inner = Shell.quote(command)
        let script = password == nil ? "sudo -n sh -c \(inner)" : "sudo -S -p '' sh -c \(inner)"
        let result = run(PoolSSH.command(host: host, script: script, stdin: password.map { Data(($0 + "\n").utf8) }, limit: limit))
        if result.succeeded { return .done(result.output) }
        let text = result.error.lowercased()
        if text.contains("password is required") || text.contains("try again") || text.contains("incorrect password") {
            return .needsPassword
        }
        return .failed(result.error.split(whereSeparator: \.isNewline).last.map(String.init) ?? "no reason given")
    }
}

final class PoolPasswordSession: @unchecked Sendable {
    private let lock = NSLock()
    private var password: String?
    private let host: String
    private let runner: CommandRunner
    private let ask: @Sendable (Bool, String) async -> String?

    init(host: String, run: @escaping CommandRunner, ask: @escaping @Sendable (Bool, String) async -> String?) {
        self.host = host
        self.runner = run
        self.ask = ask
    }

    func run(_ command: String, why: String, limit: TimeInterval = 600) async throws -> String {
        while true {
            let known = lock.withLock { password }
            switch PoolSudo.attempt(host: host, command: command, password: known, limit: limit, run: runner) {
            case .done(let output): return output
            case .failed(let reason): throw PoolClientError.sudoFailed(host: host, reason: reason)
            case .needsPassword:
                guard let typed = await ask(known != nil, why), !typed.isEmpty else {
                    throw PoolClientError.needsPassword(host: host, why: why)
                }
                lock.withLock { password = typed }
            }
        }
    }

    func forget() {
        lock.withLock { password = nil }
    }
}
