import Foundation

public struct PoolTeardownReport: Equatable, Sendable {
    public var undone: [PoolStep] = []
    public var failed: [(step: PoolStep, reason: String)] = []
    public var unreachable: String?
    public var needsPassword: String?

    public init() {}

    public static func == (left: PoolTeardownReport, right: PoolTeardownReport) -> Bool {
        left.undone == right.undone && left.failed.map(\.step) == right.failed.map(\.step)
            && left.unreachable == right.unreachable && left.needsPassword == right.needsPassword
    }

    public var finished: Bool { failed.isEmpty }
}

public enum PoolTeardown {
    public static let remoteRemoval =
        "for u in relaybar-helper.service relaybar-helper-update.timer relaybar-tunnel.service; do "
        + "systemctl --user disable --now \"$u\" >/dev/null 2>&1; done; "
        + "rm -f \"$HOME/.config/systemd/user/relaybar-helper.service\" \"$HOME/.config/systemd/user/relaybar-helper-update.service\" "
        + "\"$HOME/.config/systemd/user/relaybar-helper-update.timer\" \"$HOME/.config/systemd/user/relaybar-tunnel.service\"; "
        + "systemctl --user daemon-reload >/dev/null 2>&1; rm -rf \"$HOME/.local/share/relaybar-helper\" \"$HOME/.local/share/relaybar\"; true"

    public static func run(
        _ env: PoolEnvironment, sudoPassword: String? = nil, progress: (PoolStep) -> Void = { _ in }
    ) -> PoolTeardownReport {
        var report = PoolTeardownReport()
        guard var state = PoolState.load(env.paths) else { return report }
        let reversed = Array(state.steps.reversed())
        for step in reversed.filter({ $0 == .linuxClient }) + reversed.filter({ $0 != .linuxClient }) {
            progress(step)
            do {
                try undo(step, state: state, env, sudoPassword: sudoPassword)
                state.steps.removeAll { $0 == step }
                report.undone.append(step)
                try state.save(env.paths)
            } catch {
                report.failed.append((step, error.localizedDescription))
                if step == .remoteHelper { report.unreachable = state.ssh }
                if case PoolKeepOnError.needsPassword(let host) = error { report.needsPassword = host }
            }
        }
        if state.steps.isEmpty { PoolFile.remove(env.paths.state) }
        return report
    }

    public static func forgetRemote(_ env: PoolEnvironment) -> PoolTeardownReport {
        guard var state = PoolState.load(env.paths) else { return PoolTeardownReport() }
        state.steps.removeAll { $0.isRemote }
        state.keepOn = PoolKeepOn()
        state.linuxClients = []
        if state.steps.isEmpty {
            PoolFile.remove(env.paths.state)
            return PoolTeardownReport()
        }
        try? state.save(env.paths)
        return run(env)
    }

    private static func viaRoutes(_ state: PoolState, _ env: PoolEnvironment, _ command: (String) -> Command) -> CommandResult {
        var first: CommandResult?
        for route in [state.tailscale, state.ssh].compactMap({ $0 }) {
            let result = env.run(command(route))
            if result.succeeded { return result }
            first = first ?? result
        }
        return first ?? CommandResult()
    }

    static func undo(_ step: PoolStep, state: PoolState, _ env: PoolEnvironment, sudoPassword: String? = nil) throws {
        let paths = env.paths
        switch step {
        case .keychainAccessKey: env.keychain.delete(service: Pool.accessService)
        case .keychainManagementSecret: env.keychain.delete(service: Pool.managementService)
        case .helperFolder: PoolFile.remove(paths.helper)
        case .helperAgent: unload(Pool.helperLabel, env)
        case .updateAgent:
            unload(Pool.updateLabel, env)
            PoolFile.remove(paths.updateScript)
        case .tunnelAgent: unload(Pool.tunnelLabel, env)
        case .remoteHelper:
            guard state.ssh != nil else { return }
            let result = viaRoutes(state, env) { PoolSSH.command(host: $0, script: remoteRemoval) }
            guard result.succeeded else { throw PoolSSHError.failed(PoolHubPicker.explain(result.error, host: state.ssh ?? "")) }
        case .keepOn:
            guard state.ssh != nil, !state.keepOn.isEmpty else { return }
            let result = viaRoutes(state, env) {
                PoolRemote.restoreSleepCommand(host: $0, keep: state.keepOn, password: sudoPassword)
            }
            guard result.succeeded else {
                let host = state.ssh ?? ""
                if result.status == PoolRemote.needsPasswordStatus { throw PoolKeepOnError.needsPassword(host) }
                throw PoolSSHError.failed(PoolHubPicker.explain(result.error, host: host))
            }
        case .linuxClient:
            let routes = [state.tailscale, state.ssh].compactMap { $0 }
            for client in state.linuxClients { try PoolJoin.removeLinuxClient(client, hubRoutes: routes, run: env.run) }
        case .hubFolders:
            for name in state.hubFolders {
                let folder = paths.home.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: folder.path) { try env.trash(folder) }
            }
        case .terminalCommands:
            for file in [paths.claudeAll, paths.codexAll] where PoolFile.isOwned(file) { PoolFile.remove(file) }
        case .t3Entries: try env.t3.removePoolEntries()
        case .t3UsageSource: try env.t3.removeUsageSource()
        case .t3Default:
            try env.t3.restoreDefault(to: state.previousSelection)
        }
    }

    private static func unload(_ label: String, _ env: PoolEnvironment) {
        _ = env.run(Command("/bin/launchctl", ["bootout", "\(env.domain)/\(label)"], limit: 30))
        PoolFile.remove(env.paths.agent(label))
    }
}

public enum PoolKeepOnError: Error, Equatable, LocalizedError {
    case needsPassword(String)

    public var errorDescription: String? {
        switch self {
        case .needsPassword(let host):
            return "Sleep is still off on \(host). Relaybar needs your password there to turn it back on."
        }
    }
}

public enum PoolSSHError: Error, Equatable, LocalizedError {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}
