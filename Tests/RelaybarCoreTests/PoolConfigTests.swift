import Foundation
import Testing

@testable import RelaybarCore

struct PoolConfigTests {
    private let secrets = PoolSecrets(accessKey: String(repeating: "a", count: 64), managementSecret: String(repeating: "b", count: 64))

    @Test func writesTheAgreedSettings() {
        let text = PoolConfig.helperYAML(secrets: secrets, authDir: "/h/Helper/auth")
        let expected = [
            "config-version: 8", "  host: \"127.0.0.1\"", "  port: 8317", "  allow-remote: false", "  disable-control-panel: true",
            "  strategy: \"round-robin\"", "  session-affinity: true", "  session-affinity-ttl: \"1h\"",
            "  session-affinity-subagents: true", "  session-affinity-rebind-on: \"quota\"", "    request-retry: 3",
            "    max-retry-interval: 30", "    logging-to-file: false", "    request-log: false", "    usage-statistics-enabled: false",
            "  auth-dir: \"/h/Helper/auth\"", "  enabled: false", "    - \"\(secrets.accessKey)\"",
            "  secret-key: \"\(secrets.managementSecret)\"",
        ]
        let lines = text.split(separator: "\n").map(String.init)
        for line in expected { #expect(lines.contains(line), "missing \(line)") }
    }

    @Test func hubNeverListensOnTheNetwork() {
        let text = PoolConfig.helperYAML(secrets: secrets, authDir: "/a")
        #expect(text.contains("host: \"127.0.0.1\""))
        #expect(text.contains("allow-remote: false"))
        #expect(!text.contains("0.0.0.0"))
        #expect(!text.contains("allow-remote: true"))
    }

    @Test func makesNewSecretsEachTime() {
        let first = PoolSecrets.generate()
        let second = PoolSecrets.generate()
        #expect(first != second)
        #expect(first.accessKey != first.managementSecret)
        for value in [first.accessKey, first.managementSecret, second.accessKey] {
            #expect(value.count == 64)
            #expect(value.allSatisfy({ $0.isHexDigit }))
        }
        let fixed = PoolSecrets.generate(random: { Data(repeating: 0xab, count: 32) })
        #expect(fixed.accessKey == String(repeating: "ab", count: 32))
    }

    @Test func refusesSomeoneElsesProxy() throws {
        let home = try Fixture()
        let paths = PoolPaths(home: home.root)
        #expect(PoolConfig.conflict(paths: paths, portAnswers: false) == nil)
        #expect(PoolConfig.conflict(paths: paths, portAnswers: true) == .portInUse(8317))
        try home.write("Library/Application Support/Relaybar/Helper/config.yaml", "port: 8317\n")
        let conflict = PoolConfig.conflict(paths: paths, portAnswers: false)
        #expect(conflict == .foreignHelperFolder(paths.helper.path))
        #expect(conflict?.message.contains("did not make") == true)
        try PoolState().save(paths)
        #expect(PoolConfig.conflict(paths: paths, portAnswers: true) == nil)
        #expect(PoolConflict.portInUse(8317).message.contains("8317"))
    }

    @Test func codexHubConfigHasNoKey() {
        let text = PoolConfig.codexHubConfig()
        #expect(text.contains("model_provider = \"relaybar\""))
        #expect(text.contains("wire_api = \"responses\""))
        #expect(text.contains("requires_openai_auth = false"))
        #expect(text.contains("supports_websockets = true"))
        #expect(text.contains("base_url = \"http://127.0.0.1:8317/v1\""))
        #expect(text.contains("command = \"/usr/bin/security\""))
        #expect(text.contains("args = [\"find-generic-password\", \"-s\", \"Relaybar access key\", \"-w\"]"))
        #expect(!text.contains("Bearer"))
        #expect(!text.lowercased().contains("api_key"))
        let linux = PoolConfig.codexHubConfig(keyCommand: ["/bin/cat", "/home/u/.config/relaybar/access-key"])
        #expect(linux.contains("command = \"/bin/cat\""))
    }

    @Test func terminalCommandsReadTheKeyFromTheKeychain() {
        let claude = PoolConfig.terminalCommand(claude: true)
        #expect(claude.hasPrefix("#!/bin/sh\n"))
        #expect(claude.contains("find-generic-password -s \"Relaybar access key\" -w"))
        #expect(claude.contains("CLAUDE_CONFIG_DIR=\"$HOME/.claude-hub\""))
        #expect(claude.contains("exec claude \"$@\""))
        let codex = PoolConfig.terminalCommand(claude: false)
        #expect(codex.contains("CODEX_HOME=\"$HOME/.codex-hub\" exec codex \"$@\""))
        #expect(!codex.contains("find-generic-password"))
    }

    @Test func keychainWritesGoThroughStandardInput() {
        let recorder = Recorder()
        let keychain = PoolKeychain(run: recorder.runner)
        #expect(keychain.store(service: Pool.accessService, secret: "abcdef0123"))
        let add = recorder.commands.last
        #expect(add?.executable == "/usr/bin/security")
        #expect(add?.arguments == ["-i"])
        let line = String(decoding: add?.stdin ?? Data(), as: UTF8.self)
        #expect(line == "add-generic-password -a \"relaybar\" -s \"Relaybar access key\" -w \"abcdef0123\"\n")
        #expect(recorder.ran("/usr/bin/security", containing: "delete-generic-password -s Relaybar access key"))
        #expect(!keychain.store(service: Pool.accessService, secret: "bad\"quote"))
        #expect(!keychain.store(service: Pool.accessService, secret: ""))
    }

    @Test func keychainReadsAndDeletes() {
        let recorder = Recorder()
        recorder.respond = { _ in CommandResult(output: "secret-value\n") }
        let keychain = PoolKeychain(run: recorder.runner)
        #expect(keychain.read(service: Pool.managementService) == "secret-value")
        recorder.respond = { _ in CommandResult(status: 44) }
        #expect(keychain.read(service: Pool.managementService) == nil)
        keychain.delete(service: Pool.managementService)
        #expect(recorder.ran("/usr/bin/security", containing: "delete-generic-password -s Relaybar management secret"))
    }
}
