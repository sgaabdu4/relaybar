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
    case oldStillAnswers

    public var errorDescription: String? {
        switch self {
        case .joined: return "Only the Mac that set up the helper can move it."
        case .unfinished: return "An earlier move has not finished. Restart Relaybar, or choose Stop combining, then try again."
        case .alreadyHere(let host): return "The helper already runs on \(host). Pick another computer."
        case .addedComputer(let host): return "Remove \(host) from Computers first, then move."
        case .oldStillAnswers: return "The old helper did not stop, so Relaybar did not switch. Nothing was changed. Try again."
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
            if let computer = state.linuxClients.first { throw PoolMoveError.addedComputer(computer.host) }
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

public struct PoolMoveReport: Equatable, Sendable {
    public var sleep: PoolSleep?
    public var left: String?
    public var needsPassword: String?
    public var computersLeft: [String] = []

    public init() {}
}

extension PoolSetup {
    func updateState(_ change: (inout PoolState) -> Void) throws {
        guard var state = PoolState.load(env.paths) else { return }
        change(&state)
        try state.save(env.paths)
    }

    public func move(
        to target: PoolMoveTarget, sudoPassword: String? = nil, progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> PoolMoveReport {
        guard let script = env.script else { throw PoolSetupError.missingScript }
        let host = try checkMove(to: target)
        guard let access = accessKey(), let management = env.keychain.read(service: Pool.managementService) else {
            throw PoolSetupError.accessKeyMissing
        }
        let secrets = PoolSecrets(accessKey: access, managementSecret: management)
        try updateState { state in
            state.move = PoolMove(
                target: host, phase: .preparing,
                old: PoolMoveOld(ssh: state.ssh, tailscale: state.tailscale, keepOn: state.keepOn))
        }
        var report = PoolMoveReport()
        do {
            report.sleep = try await prepareNewHelper(
                host: host, secrets: secrets, script: script, sudoPassword: sudoPassword, progress: progress)
            progress(host.map { "Switching this Mac to \($0)" } ?? "Switching this Mac to its own helper")
            try await switchHolder(host: host, secrets: secrets, progress: progress)
        } catch {
            _ = await undoMove(sudoPassword: nil)
            throw error
        }
        try updateState { state in
            guard var move = state.move else { return }
            let steps = PoolMove.steps(after: state.steps, move: move)
            state.ssh = host
            state.tailscale = nil
            state.keepOn = move.newKeepOn
            state.steps = steps
            for index in state.linuxClients.indices { state.linuxClients[index].needsRepoint = true }
            move.phase = .switched
            state.move = move
        }
        let finished = await settleMove(sudoPassword: sudoPassword, progress: progress)
        var done = finished
        done.sleep = report.sleep
        return done
    }

    public func settleMove(sudoPassword: String? = nil, progress: @Sendable (String) -> Void = { _ in }) async -> PoolMoveReport {
        guard let state = PoolState.load(env.paths) else { return PoolMoveReport() }
        switch PoolMove.action(for: state) {
        case .undo: return await undoMove(sudoPassword: sudoPassword)
        case .none:
            var report = PoolMoveReport()
            report.computersLeft = repointComputers(progress: progress)
            return report
        case .finish:
            let left = repointComputers(progress: progress)
            var report = await finishMove(sudoPassword: sudoPassword, progress: progress)
            report.computersLeft = left
            return report
        }
    }

    private func finishMove(sudoPassword: String?, progress: @Sendable (String) -> Void) async -> PoolMoveReport {
        var report = PoolMoveReport()
        guard let state = PoolState.load(env.paths), let move = state.move else { return report }
        if state.runsOnThisMac, FileManager.default.fileExists(atPath: env.paths.agent(Pool.tunnelLabel).path) {
            try? PoolTeardown.undo(.tunnelAgent, state: state, env)
        }
        guard let old = move.old else {
            try? updateState { $0.move = nil }
            return report
        }
        progress(old.ssh.map { "Removing the helper from \($0)" } ?? "Removing the helper from this Mac")
        if old.runsOnThisMac {
            for step in PoolMove.localSteps.reversed() { try? PoolTeardown.undo(step, state: PoolState(), env) }
        } else {
            let oldState = old.asState
            do {
                try PoolTeardown.undo(.remoteHelper, state: oldState, env)
                try PoolTeardown.undo(.keepOn, state: oldState, env, sudoPassword: sudoPassword)
            } catch PoolKeepOnError.needsPassword(let host) {
                report.needsPassword = host
                return report
            } catch {
                report.left = old.ssh
                return report
            }
        }
        try? updateState { $0.move = nil }
        return report
    }

    @discardableResult
    func undoMove(sudoPassword: String?) async -> PoolMoveReport {
        var report = PoolMoveReport()
        guard let state = PoolState.load(env.paths), let move = state.move else { return report }
        if move.target == nil, move.claimed {
            for step in PoolMove.localSteps.reversed() { try? PoolTeardown.undo(step, state: state, env) }
        }
        if let old = move.old { await putBack(old, state: state) }
        if let target = move.target, move.claimed {
            let removal = env.run(PoolSSH.command(host: target, script: PoolTeardown.remoteRemoval))
            guard removal.succeeded else {
                report.left = target
                return report
            }
            try? updateState { $0.move?.claimed = false }
        }
        if let target = move.target, !move.newKeepOn.isEmpty {
            let restore = env.run(PoolRemote.restoreSleepCommand(host: target, keep: move.newKeepOn, password: sudoPassword))
            guard restore.succeeded else {
                if restore.status == PoolRemote.needsPasswordStatus { report.needsPassword = target } else { report.left = target }
                return report
            }
        }
        try? updateState { $0.move = nil }
        return report
    }

    private func putBack(_ old: PoolMoveOld, state: PoolState) async {
        let api = PoolManagement(secret: "", http: env.http)
        if old.runsOnThisMac {
            if FileManager.default.fileExists(atPath: env.paths.agent(Pool.tunnelLabel).path) {
                try? PoolTeardown.undo(.tunnelAgent, state: state, env)
            }
            let answering = await api.isUp()
            if !answering {
                load(Pool.helperLabel)
                load(Pool.updateLabel)
            }
        } else if let route = old.asState.tunnelRoute {
            let expected = PoolTunnel.plist(paths: env.paths, destination: route.host, hostName: route.hostName)
            let answering = await api.isUp()
            if PoolFile.contents(env.paths.agent(Pool.tunnelLabel)) != expected || !answering {
                try? PoolFile.write(Data(expected.utf8), to: env.paths.agent(Pool.tunnelLabel), backup: false)
                load(Pool.tunnelLabel)
            }
        }
    }

    private func prepareNewHelper(
        host: String?, secrets: PoolSecrets, script: Data, sudoPassword: String?, progress: @Sendable (String) -> Void
    ) async throws -> PoolSleep? {
        guard let host else {
            progress("Setting up the helper on this Mac")
            try makeHelperFolders()
            try updateState { $0.move?.claimed = true }
            try writeHelperFiles(secrets: secrets, script: script)
            return nil
        }
        progress("Setting up the helper on \(host)")
        let remote = PoolRemote(host: host, run: env.run)
        try remote.claim()
        try updateState { $0.move?.claimed = true }
        try remote.install(secrets: secrets, script: script, progress: progress)
        let kept = remote.keepOn(password: sudoPassword)
        try updateState { $0.move?.newKeepOn.add(kept.changes) }
        return kept.sleep
    }

    private func isDown() async -> Bool {
        let api = PoolManagement(secret: "", http: env.http)
        for _ in 0..<10 {
            if !(await api.isUp()) { return true }
            await env.pause(1)
        }
        return false
    }

    private func bootOut(_ label: String) {
        _ = env.run(Command("/bin/launchctl", ["bootout", "\(env.domain)/\(label)"], limit: 30))
    }

    private func switchHolder(host: String?, secrets: PoolSecrets, progress: @Sendable (String) -> Void) async throws {
        guard let move = PoolState.load(env.paths)?.move, let old = move.old else { return }
        if old.runsOnThisMac {
            bootOut(Pool.helperLabel)
            bootOut(Pool.updateLabel)
        } else {
            bootOut(Pool.tunnelLabel)
        }
        guard await isDown() else { throw PoolMoveError.oldStillAnswers }
        if let host {
            try PoolFile.write(
                Data(PoolTunnel.plist(paths: env.paths, destination: host).utf8), to: env.paths.agent(Pool.tunnelLabel), backup: false)
            load(Pool.tunnelLabel)
        } else {
            progress("Downloading and checking the helper")
            try PoolInstall.install(paths: env.paths, run: env.run)
            load(Pool.helperLabel)
            load(Pool.updateLabel)
        }
        try await waitForHelper(secrets)
        try await confirmHelper(secrets, host: host ?? "this Mac")
    }
}

extension PoolMove {
    public static func pausedEmails(in members: [PoolMember]) -> [String] {
        members.compactMap { member in
            guard case .paused = member.state, !member.credential.email.isEmpty else { return nil }
            return member.credential.email.lowercased()
        }
    }
}

extension PoolSetup {
    public func pauseAgain(emails: [String]) async throws {
        guard let management else { return }
        let wanted = Set(emails.map { $0.lowercased() })
        var credentials = try await management.credentials()
        for credential in credentials where wanted.contains(credential.email.lowercased()) && !credential.disabled {
            guard PoolAccounts.canPause(credential.name, in: credentials) else { continue }
            try await management.setPaused(name: credential.name, paused: true)
            credentials = try await management.credentials()
        }
        _ = try await updateOrder(members: credentials.map { PoolUsage.member($0, result: nil) })
    }
}

extension PoolJoin {
    static func repointLinuxClient(_ client: PoolLinuxClient, hub: PoolRemote, facts: PoolHubFacts, run: @escaping CommandRunner) throws
        -> PoolLinuxClient
    {
        let remote = PoolRemote(host: client.host, run: run)
        let home = try remote.remoteHome()
        let made = try remote.execute("cut -d' ' -f1,2 \"\(clientConfig)/hub_key.pub\"")
        guard let publicKey = made.split(whereSeparator: \.isNewline).map(String.init).first(where: { $0.hasPrefix("ssh-ed25519 ") }),
            publicKey.dropFirst(12).allSatisfy({ $0.isLetter || $0.isNumber || "+/=".contains($0) })
        else { throw PoolClientError.noKeyTool(client.host) }
        let created = try addHubKey(hub, publicKey: publicKey, host: client.host)
        let lines = created.split(whereSeparator: \.isNewline).map(String.init)
        if lines.contains("link") { throw PoolFileError.link("\(hub.host):.ssh/authorized_keys") }
        let key = home + "/.config/relaybar/hub_key"
        let knownHosts = home + "/.config/relaybar/known_hosts"
        try remote.execute("umask 077; cat > \"\(clientConfig)/known_hosts\"", stdin: Data(facts.knownHosts().utf8))
        let address = try chooseAddress(remote, hub: hub.host, facts: facts, key: key, knownHosts: knownHosts)
        let found = try remote.execute("command -v ssh").trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = try PoolTunnel.linuxUnit(
            user: facts.user, addresses: facts.routes(worked: address), key: key, knownHosts: knownHosts, port: facts.port,
            ssh: found.hasPrefix("/") ? found : "/usr/bin/ssh")
        try remote.execute("cat > \"$HOME/.config/systemd/user/relaybar-tunnel.service\"", stdin: Data(unit.utf8))
        try startTunnel(remote, label: hub.host)
        var updated = client
        updated.hubKey = true
        updated.hubCreated = lines.filter { $0.hasPrefix("created:") }.map { String($0.dropFirst(8)) }
        updated.needsRepoint = false
        return updated
    }
}

extension PoolSetup {
    func repointComputers(progress: @Sendable (String) -> Void) -> [String] {
        guard let state = PoolState.load(env.paths), !state.joined, let route = state.tunnelRoute else { return [] }
        let pending = state.linuxClients.filter(\.needsRepoint)
        guard !pending.isEmpty else { return [] }
        let hub = PoolRemote(host: route.host, hostName: route.hostName, run: env.run)
        var left: [String] = []
        let facts = try? PoolJoin.hubFacts(hub)
        for client in pending {
            progress("Pointing \(client.host) at \(route.host)")
            guard let facts, let updated = try? PoolJoin.repointLinuxClient(client, hub: hub, facts: facts, run: env.run) else {
                left.append(client.host)
                continue
            }
            try? updateState { latest in
                if let index = latest.linuxClients.firstIndex(where: { $0.host == client.host }) { latest.linuxClients[index] = updated }
            }
        }
        return left
    }
}

public enum PoolMoveAction: Equatable, Sendable {
    case none
    case undo
    case finish
}

extension PoolMove {
    public static func action(for state: PoolState) -> PoolMoveAction {
        guard let move = state.move else { return .none }
        return move.phase == .preparing ? .undo : .finish
    }

    static let remoteSteps: [PoolStep] = [.remoteHelper, .keepOn]
    static let localSteps: [PoolStep] = [.helperFolder, .helperAgent, .updateAgent]

    static func steps(after steps: [PoolStep], move: PoolMove) -> [PoolStep] {
        let owned: [PoolStep] = remoteSteps + localSteps + [.tunnelAgent]
        var kept = steps.filter { !owned.contains($0) }
        var fresh: [PoolStep]
        if move.target == nil {
            fresh = localSteps
        } else {
            fresh = [.remoteHelper] + (move.newKeepOn.isEmpty ? [] : [.keepOn]) + [.tunnelAgent]
        }
        let index = (kept.lastIndex { $0 == .keychainAccessKey || $0 == .keychainManagementSecret }).map { $0 + 1 } ?? 0
        kept.insert(contentsOf: fresh, at: index)
        return kept
    }
}
