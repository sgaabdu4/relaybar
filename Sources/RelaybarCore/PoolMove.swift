import Foundation

public enum PoolMoveTarget: Equatable, Sendable {
    case thisMac
    case computer(String)
}

public enum PoolMoveError: Error, Equatable, LocalizedError {
    case joined
    case unfinished
    case alreadyHere(String)
    case addedComputer(String)

    public var errorDescription: String? {
        switch self {
        case .joined: return "Only the Mac that set up the helper can move it."
        case .unfinished: return "An earlier move has not finished. Restart Relaybar, or choose Stop combining, then try again."
        case .alreadyHere(let host): return "The helper already runs on \(host). Pick another computer."
        case .addedComputer(let host): return "Remove \(host) from Computers first, then move."
        }
    }
}

extension PoolState {
    public var canMoveHelper: Bool { !joined && move == nil }
}

extension PoolSetup {
    @discardableResult
    public func checkMove(to target: PoolMoveTarget) throws -> String? {
        guard let state = PoolState.load(env.paths) else { throw PoolSetupError.notCombining }
        guard !state.joined else { throw PoolMoveError.joined }
        guard state.move == nil else { throw PoolMoveError.unfinished }
        guard accessKey() != nil, management != nil else { throw PoolSetupError.accessKeyMissing }
        switch target {
        case .thisMac:
            guard !state.runsOnThisMac else { throw PoolMoveError.alreadyHere("this Mac") }
            let paths = env.paths
            if FileManager.default.fileExists(atPath: paths.config.path) || FileManager.default.fileExists(atPath: paths.helper.path) {
                throw PoolSetupError.conflict(.foreignHelperFolder(paths.helper.path))
            }
            return nil
        case .computer(let typed):
            let host = try PoolHubPicker.validate(typed)
            if host == state.ssh || host == state.tailscale { throw PoolMoveError.alreadyHere(host) }
            if state.linuxClients.contains(where: { $0.host == host }) { throw PoolMoveError.addedComputer(host) }
            switch try PoolRemote(host: host, run: env.run).status() {
            case .free: return host
            case .relaybarHub: throw PoolSetupError.hubExists(host)
            case .conflict(let conflict): throw PoolSetupError.conflict(conflict)
            }
        }
    }
}
