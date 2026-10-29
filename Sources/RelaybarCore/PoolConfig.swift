import Foundation

public struct PoolSecrets: Equatable, Sendable {
    public let accessKey: String
    public let managementSecret: String

    public init(accessKey: String, managementSecret: String) {
        self.accessKey = accessKey
        self.managementSecret = managementSecret
    }

    public static func generate(random: () -> Data = { PoolSecrets.systemRandom(32) }) -> PoolSecrets {
        PoolSecrets(accessKey: hex(random()), managementSecret: hex(random()))
    }

    public static func systemRandom(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

public enum PoolConflict: Equatable, Sendable {
    case foreignHelperFolder(String)
    case portInUse(Int)

    public var message: String {
        switch self {
        case .foreignHelperFolder(let path):
            return
                "A CLIProxyAPI setup that Relaybar did not make already exists at \(path). Relaybar left it alone. Stop that setup or move it, then try again."
        case .portInUse(let port):
            return
                "Another program already answers on port \(port), so Relaybar left it alone. Stop that program (for example a Homebrew CLIProxyAPI), then try again."
        }
    }
}

public enum PoolConfig {
    public static func conflict(paths: PoolPaths, portAnswers: Bool) -> PoolConflict? {
        if FileManager.default.fileExists(atPath: paths.state.path) { return nil }
        if FileManager.default.fileExists(atPath: paths.config.path) { return .foreignHelperFolder(paths.helper.path) }
        return portAnswers ? .portInUse(Pool.port) : nil
    }

    public static func helperYAML(secrets: PoolSecrets, authDir: String, port: Int = Pool.port) -> String {
        """
        # \(PoolFile.marker). Relaybar replaces this file when it sets the helper up again.
        config-version: 8
        server:
          host: "127.0.0.1"
          port: \(port)
        management:
          allow-remote: false
          secret-key: "\(secrets.managementSecret)"
          disable-control-panel: true
        access:
          api-keys:
            - "\(secrets.accessKey)"
        routing:
          strategy: "round-robin"
          session-affinity: true
          session-affinity-ttl: "1h"
          session-affinity-subagents: true
          session-affinity-rebind-on: "quota"
          retry:
            request-retry: 3
            max-retry-interval: 30
        oauth:
          auth-dir: "\(escape(authDir))"
        observability:
          logs:
            logging-to-file: false
            request-log: false
          usage:
            usage-statistics-enabled: false
        plugins:
          enabled: false

        """
    }

    public static func codexHubConfig(keyCommand: [String]? = nil) -> String {
        let command = keyCommand ?? ["/usr/bin/security", "find-generic-password", "-s", Pool.accessService, "-w"]
        let arguments = command.dropFirst().map { "\"\(escape($0))\"" }.joined(separator: ", ")
        return """
            # \(PoolFile.marker).
            model_provider = "relaybar"

            [model_providers.relaybar]
            name = "All accounts"
            base_url = "http://127.0.0.1:\(Pool.port)/v1"
            wire_api = "responses"
            requires_openai_auth = false
            supports_websockets = true

            [model_providers.relaybar.auth]
            command = "\(escape(command[0]))"
            args = [\(arguments)]

            """
    }

    public static func terminalCommand(claude: Bool, keyCommand: String? = nil) -> String {
        let read = keyCommand ?? "/usr/bin/security find-generic-password -s \"\(Pool.accessService)\" -w"
        let launch =
            claude
            ? "CLAUDE_CONFIG_DIR=\"$HOME/.claude-hub\" ANTHROPIC_BASE_URL=\"http://127.0.0.1:\(Pool.port)\" ANTHROPIC_AUTH_TOKEN=\"$key\" exec claude \"$@\""
            : "CODEX_HOME=\"$HOME/.codex-hub\" exec codex \"$@\""
        let key =
            claude
            ? "key=$(\(read)) || { echo \"Relaybar could not read its access key.\" >&2; exit 1; }\n"
            : ""
        return "#!/bin/sh\n# \(PoolFile.marker).\n\(key)\(launch)\n"
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public struct PoolKeychain: Sendable {
    public let run: CommandRunner

    public init(run: @escaping CommandRunner) {
        self.run = run
    }

    public func store(service: String, secret: String) -> Bool {
        guard secret.allSatisfy({ $0.isHexDigit }), !secret.isEmpty else { return false }
        delete(service: service)
        let line =
            "add-generic-password -a \"\(Pool.keychainAccount)\" -s \"\(service)\" -w \"\(secret)\"\n"
        return run(Command("/usr/bin/security", ["-i"], stdin: Data(line.utf8))).succeeded
    }

    public func read(service: String) -> String? {
        let result = run(Command("/usr/bin/security", ["find-generic-password", "-s", service, "-w"]))
        let secret = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !secret.isEmpty ? secret : nil
    }

    public func delete(service: String) {
        _ = run(Command("/usr/bin/security", ["delete-generic-password", "-s", service]))
    }
}
