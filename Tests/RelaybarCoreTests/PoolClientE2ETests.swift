import Foundation
import Testing

@testable import RelaybarCore

enum ClientE2E {
    static let environment = ProcessInfo.processInfo.environment
    static let step = environment["RELAYBAR_E2E_STEP"]

    static var run: CommandRunner {
        let config = environment["RELAYBAR_E2E_SSH_CONFIG"] ?? ""
        return { command in
            var command = command
            if command.executable == "/usr/bin/ssh" { command.arguments = ["-F", config] + command.arguments }
            return PoolProcess.run(command)
        }
    }

    static var clientFile: URL { URL(fileURLWithPath: environment["RELAYBAR_E2E_CLIENT_FILE"] ?? "") }
}

struct PoolClientE2ETests {
    @Test(.enabled(if: ClientE2E.step == "add"))
    func e2eAddsTheClient() async throws {
        let key = try String(contentsOfFile: ClientE2E.environment["RELAYBAR_E2E_ACCESS_KEY_FILE"] ?? "", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let client = try await PoolJoin.linuxClient(host: "e2e-client", hub: "e2e-hub", accessKey: key, run: ClientE2E.run)
        try JSONEncoder().encode(client.client).write(to: ClientE2E.clientFile)
    }

    @Test(.enabled(if: ClientE2E.step == "addInstalls"))
    func e2eAddsTheClientWithInstalls() async throws {
        let key = try String(contentsOfFile: ClientE2E.environment["RELAYBAR_E2E_ACCESS_KEY_FILE"] ?? "", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = URL(fileURLWithPath: ClientE2E.environment["RELAYBAR_E2E_PAIR_FILE"] ?? "")
        let hooks = PoolAddHooks(pair: { url in
            try? Data("\(url.scheme ?? "")://\(url.host ?? "")".utf8).write(to: marker)
        })
        let client = try await PoolJoin.linuxClient(
            host: "e2e-client", hub: "e2e-hub", accessKey: key, options: PoolAddOptions(t3Channel: .nightly), hooks: hooks,
            run: ClientE2E.run)
        try JSONEncoder().encode(client.client).write(to: ClientE2E.clientFile)
    }

    @Test(.enabled(if: ClientE2E.step == "remove"))
    func e2eRemovesTheClient() throws {
        let client = try JSONDecoder().decode(PoolLinuxClient.self, from: Data(contentsOf: ClientE2E.clientFile))
        try PoolJoin.removeLinuxClient(client, hubRoutes: ["e2e-hub"], run: ClientE2E.run)
    }
}
