import Foundation
import Testing

@testable import RelaybarCore

final class MoveTunnels: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [String: Process] = [:]

    func start(label: String, plist: URL, port: Int, config: String) -> CommandResult {
        guard let data = try? Data(contentsOf: plist),
            let found = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
            let words = found["ProgramArguments"] as? [String]
        else { return CommandResult(status: 1, error: "cannot read \(plist.path)") }
        let arguments =
            ["-F", config] + words.dropFirst().map { $0 == "127.0.0.1:8317:127.0.0.1:8317" ? "127.0.0.1:\(port):127.0.0.1:8317" : $0 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: words[0])
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return CommandResult(status: 1, error: "\(error)") }
        lock.withLock { running[label] = process }
        return CommandResult()
    }

    func stop(label: String) {
        let process = lock.withLock { running.removeValue(forKey: label) }
        process?.terminate()
        process?.waitUntilExit()
    }

    func stopAll() {
        for label in lock.withLock({ Array(running.keys) }) { stop(label: label) }
    }
}

enum MoveE2E {
    static let tunnels = MoveTunnels()
    static var environment: [String: String] { ClientE2E.environment }
    static var home: URL { URL(fileURLWithPath: environment["RELAYBAR_E2E_HOME"] ?? "") }
    static var port: Int { Int(environment["RELAYBAR_E2E_LOCAL_PORT"] ?? "") ?? 0 }
    static var keychainFolder: URL { home.appendingPathComponent("keychain") }
    static var paths: PoolPaths { PoolPaths(home: home) }

    static func read(_ name: String) -> String {
        ((try? String(contentsOfFile: environment[name] ?? "", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func service(in command: Command) -> String? {
        guard let index = command.arguments.firstIndex(of: "-s"), command.arguments.indices.contains(index + 1) else { return nil }
        return command.arguments[index + 1]
    }

    static func keychain(_ command: Command) -> CommandResult {
        let file = { (service: String) in keychainFolder.appendingPathComponent(service.replacingOccurrences(of: " ", with: "-")) }
        if command.arguments == ["-i"], let line = command.stdin.map({ String(decoding: $0, as: UTF8.self) }) {
            let parts = line.components(separatedBy: "\"")
            guard parts.count > 5 else { return CommandResult(status: 1) }
            try? FileManager.default.createDirectory(at: keychainFolder, withIntermediateDirectories: true)
            return (try? Data(parts[5].utf8).write(to: file(parts[3]))) == nil ? CommandResult(status: 1) : CommandResult()
        }
        guard let service = service(in: command) else { return CommandResult(status: 1) }
        switch command.arguments.first {
        case "find-generic-password":
            guard let text = try? String(contentsOf: file(service), encoding: .utf8) else { return CommandResult(status: 44) }
            return CommandResult(output: text + "\n")
        case "delete-generic-password":
            try? FileManager.default.removeItem(at: file(service))
            return CommandResult()
        default: return CommandResult(status: 1)
        }
    }

    static func launchctl(_ command: Command) -> CommandResult {
        guard let target = command.arguments.last else { return CommandResult(status: 1) }
        if command.arguments.first == "bootout" {
            tunnels.stop(label: URL(fileURLWithPath: target).lastPathComponent)
            return CommandResult()
        }
        guard command.arguments.first == "bootstrap" else { return CommandResult() }
        let plist = URL(fileURLWithPath: target)
        let name = plist.lastPathComponent
        guard name.hasPrefix(Pool.tunnelLabel) else { return CommandResult() }
        return tunnels.start(
            label: Pool.tunnelLabel, plist: plist, port: port, config: environment["RELAYBAR_E2E_SSH_CONFIG"] ?? "")
    }

    static var runner: CommandRunner {
        { command in
            switch command.executable {
            case "/usr/bin/security": return keychain(command)
            case "/bin/launchctl": return launchctl(command)
            default: return ClientE2E.run(command)
            }
        }
    }

    static var http: HTTPClient {
        { request in
            var request = request
            if request.url.port == Pool.port, var parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false) {
                parts.port = port
                request.url = parts.url ?? request.url
            }
            return await PoolHTTP.live(request)
        }
    }

    static func env() -> PoolEnvironment {
        let script = try? Data(contentsOf: URL(fileURLWithPath: environment["RELAYBAR_E2E_SCRIPT_FILE"] ?? ""))
        return PoolEnvironment(
            home: home, uid: 501, run: runner, http: http, trash: { try FileManager.default.removeItem(at: $0) }, script: script,
            t3Installed: false)
    }

    static func start(from host: String) async throws {
        let env = env()
        if !FileManager.default.fileExists(atPath: env.paths.state.path) {
            for (service, name) in [
                (Pool.accessService, "RELAYBAR_E2E_ACCESS_KEY_FILE"), (Pool.managementService, "RELAYBAR_E2E_MGMT_FILE"),
            ] {
                #expect(env.keychain.store(service: service, secret: read(name)))
            }
            var state = PoolState(ssh: host)
            state.steps = [.keychainAccessKey, .keychainManagementSecret, .remoteHelper, .tunnelAgent, .linuxClient]
            state.linuxClients = [try JSONDecoder().decode(PoolLinuxClient.self, from: Data(contentsOf: ClientE2E.clientFile))]
            try state.save(env.paths)
        }
        let current = try #require(PoolState.load(env.paths))
        let route = try #require(current.tunnelRoute)
        try PoolFile.write(
            Data(PoolTunnel.plist(paths: env.paths, destination: route.host, hostName: route.hostName).utf8),
            to: env.paths.agent(Pool.tunnelLabel), backup: false)
        _ = env.run(Command("/bin/launchctl", ["bootstrap", env.domain, env.paths.agent(Pool.tunnelLabel).path]))
        let api = PoolManagement(secret: "", http: env.http)
        var up = false
        for _ in 0..<20 where !up {
            up = await api.isUp()
            if !up { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        #expect(up)
    }

    static func write(_ report: PoolMoveReport) throws {
        let text =
            "left=\(report.left ?? "")\ncomputers=\(report.computersLeft.joined(separator: ","))\npassword=\(report.needsPassword ?? "")\n"
        try Data(text.utf8).write(to: URL(fileURLWithPath: environment["RELAYBAR_E2E_REPORT"] ?? ""))
    }
}

struct PoolMoveE2ETests {
    @Test(.enabled(if: ClientE2E.step == "move"))
    func e2eMovesTheHelper() async throws {
        defer { MoveE2E.tunnels.stopAll() }
        try await MoveE2E.start(from: MoveE2E.environment["RELAYBAR_E2E_MOVE_FROM"] ?? "")
        let target = MoveE2E.environment["RELAYBAR_E2E_MOVE_TO"] ?? ""
        let stop = MoveE2E.environment["RELAYBAR_E2E_STOP_AFTER_SWITCH"]
        let setup = PoolSetup(env: MoveE2E.env())
        let report = try await setup.move(
            to: .computer(target),
            afterSwitch: {
                guard let stop else { return }
                _ = PoolProcess.run(Command("/usr/bin/env", ["docker", "stop", stop], limit: 120))
            })
        try MoveE2E.write(report)
        let state = try #require(PoolState.load(MoveE2E.paths))
        #expect(state.ssh == target && state.tailscale == nil && state.linuxClients.count == 1)
    }

    @Test(.enabled(if: ClientE2E.step == "settle"))
    func e2eSettlesTheMove() async throws {
        let report = await PoolSetup(env: MoveE2E.env()).settleMove()
        try MoveE2E.write(report)
        let state = try #require(PoolState.load(MoveE2E.paths))
        #expect(state.move == nil)
    }
}
