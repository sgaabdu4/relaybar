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

    private func runLauncher(_ script: String, tool: String, arguments: [String], environment: [String: String] = [:]) throws -> (
        output: [String], home: Fixture
    ) {
        let home = try Fixture()
        try home.write(
            "bin/\(tool)",
            "#!/bin/sh\necho \"BASE=${ANTHROPIC_BASE_URL-unset}\"\necho \"TOKEN=${ANTHROPIC_AUTH_TOKEN-unset}\"\necho \"CLAUDE_DIR=${CLAUDE_CONFIG_DIR-unset}\"\necho \"CODEX_HOME=${CODEX_HOME-unset}\"\nfor a in \"$@\"; do echo \"ARG=$a\"; done\n"
        )
        try home.write("bin/\(tool)+", script)
        for name in [tool, tool + "+"] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: home.root.appendingPathComponent("bin/\(name)").path)
        }
        let process = Process()
        process.executableURL = home.root.appendingPathComponent("bin/\(tool)+")
        process.arguments = arguments
        var env = ["PATH": home.root.appendingPathComponent("bin").path + ":/usr/bin:/bin", "HOME": home.root.path]
        env.merge(environment) { $1 }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return (String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init), home)
    }

    @Test func launchersSetTheProviderOnlyAtStart() throws {
        let claudeScript = PoolConfig.claudePlus(keyCommand: "echo fixture-key")
        #expect(!claudeScript.contains("CLAUDE_CONFIG_DIR") && !claudeScript.contains("claude-hub"))
        let claude = try runLauncher(claudeScript, tool: "claude", arguments: ["--version"])
        #expect(
            claude.output == ["BASE=http://127.0.0.1:8317", "TOKEN=fixture-key", "CLAUDE_DIR=unset", "CODEX_HOME=unset", "ARG=--version"])
        let written = try FileManager.default.subpathsOfDirectory(atPath: claude.home.root.path).sorted()
        #expect(written == ["bin", "bin/claude", "bin/claude+"])
        let keychain = PoolConfig.claudePlus()
        #expect(keychain.contains("key=$(/usr/bin/security find-generic-password -s \"Relaybar access key\" -w)"))
        #expect(keychain.contains("exec claude \"$@\""))

        let codexScript = PoolConfig.codexPlus()
        #expect(!codexScript.contains("CODEX_HOME") && !codexScript.contains("codex-hub") && !codexScript.contains("Bearer"))
        let codex = try runLauncher(
            codexScript, tool: "codex", arguments: ["app-server", "--listen", "stdio"], environment: ["CODEX_HOME": "/t3/own"])
        let expected = [
            "model_provider=\"relaybar\"", "model_providers.relaybar.name=\"All accounts\"",
            "model_providers.relaybar.base_url=\"http://127.0.0.1:8317/v1\"", "model_providers.relaybar.wire_api=\"responses\"",
            "model_providers.relaybar.requires_openai_auth=false", "model_providers.relaybar.supports_websockets=true",
            "model_providers.relaybar.auth.command=\"/usr/bin/security\"",
            "model_providers.relaybar.auth.args=[\"find-generic-password\",\"-s\",\"Relaybar access key\",\"-w\"]",
        ]
        #expect(Array(codex.output.prefix(4)) == ["BASE=unset", "TOKEN=unset", "CLAUDE_DIR=unset", "CODEX_HOME=/t3/own"])
        #expect(
            Array(codex.output.dropFirst(4)) == expected.flatMap { ["ARG=-c", "ARG=\($0)"] } + [
                "ARG=app-server", "ARG=--listen", "ARG=stdio",
            ])
        #expect(try FileManager.default.subpathsOfDirectory(atPath: codex.home.root.path).sorted() == ["bin", "bin/codex", "bin/codex+"])

        let linux = PoolConfig.codexPlus(
            keyCommand: ["/bin/cat", "/home/sam/.config/relaybar/access-key"], binary: "/home/sam/.local/bin/codex")
        #expect(linux.contains("model_providers.relaybar.auth.command=\"/bin/cat\""))
        #expect(linux.contains("model_providers.relaybar.auth.args=[\"/home/sam/.config/relaybar/access-key\"]"))
        #expect(linux.contains("exec \"/home/sam/.local/bin/codex\" -c"))
        #expect(!linux.contains("fixture-key"))
    }

    @Test func settingsAndConfigPointAtTheHelper() throws {
        let fresh = try #require(PoolReplace.claudeSettings(existing: nil, home: "/home/sam"))
        let root = try #require(try JSONSerialization.jsonObject(with: fresh) as? [String: Any])
        #expect(root["apiKeyHelper"] as? String == "/bin/cat '/home/sam/.config/relaybar/access-key'")
        #expect((root["env"] as? [String: String]) == ["ANTHROPIC_BASE_URL": "http://127.0.0.1:8317"])
        #expect(PoolReplace.claudeSettings(existing: Data("{ nope".utf8), home: "/home/sam") == nil)
        #expect(PoolReplace.claudeSettings(existing: Data("[1]".utf8), home: "/home/sam") == nil)
        let text = PoolReplace.codexConfig(existing: "", keyFile: "/home/sam/.config/relaybar/access-key")
        #expect(text.hasPrefix("model_provider = \"relaybar\"\n\n[model_providers.relaybar]\nname = \"All accounts\"\n"))
        #expect(!text.contains("Bearer") && text.hasSuffix("args = [\"/home/sam/.config/relaybar/access-key\"]\n"))
        let dotted = PoolReplace.codexConfig(
            existing:
                "model_providers.relaybar.name = \"x\"\n  model_provider=\"y\"\nmodel_provider_extra = 1\n[a]\nmodel_provider = \"keep\"\n",
            keyFile: "/k")
        #expect(dotted.contains("model_provider_extra = 1") && dotted.contains("[a]\nmodel_provider = \"keep\""))
        #expect(!dotted.contains("= \"x\"") && !dotted.contains("model_provider=\"y\""))
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
