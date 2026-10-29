import Foundation

public enum PoolSetupError: Error, Equatable, LocalizedError {
    case conflict(PoolConflict)
    case missingScript
    case keychain
    case notAnswering
    case hubExists(String)
    case helperNotConfirmed(String)
    case notCombining
    case hubIsThisMac
    case accessKeyMissing

    public var errorDescription: String? {
        switch self {
        case .conflict(let conflict): return conflict.message
        case .missingScript: return "Relaybar's helper installer is missing from the app. Reinstall Relaybar, then try again."
        case .keychain: return "Relaybar could not save a key in the Keychain. Unlock the Keychain, then try again."
        case .notAnswering:
            return "The helper did not start. Nothing was kept. Check the internet connection and try again."
        case .hubExists(let host):
            return "\(host) already combines accounts. Relaybar left it alone. Use it from this Mac instead."
        case .notCombining: return "Accounts are not combined yet. Choose Combine accounts first."
        case .hubIsThisMac:
            return
                "The helper runs on this Mac, and other computers cannot reach it from here. Combine accounts on a home computer to use them on other computers."
        case .accessKeyMissing:
            return "Relaybar cannot read the access key from the Keychain. Choose Stop combining, then combine your accounts again."
        case .helperNotConfirmed(let host):
            return
                "Something other than the helper from \(host) answered. Nothing was kept. Check that the helper runs on \(host), then try again."
        }
    }
}

public struct PoolSetup: Sendable {
    public static let combinedColor = "#32ade6"
    public let env: PoolEnvironment

    public init(env: PoolEnvironment) {
        self.env = env
    }

    public var management: PoolManagement? {
        env.keychain.read(service: Pool.managementService).map { PoolManagement(secret: $0, http: env.http) }
    }

    public func accessKey() -> String? { env.keychain.read(service: Pool.accessService) }

    public func inspectThisMac() async -> PoolConflict? {
        let answers = await PoolManagement(secret: "", http: env.http).isUp()
        return PoolConfig.conflict(paths: env.paths, portAnswers: answers)
    }

    public func combineOnThisMac(progress: @Sendable (String) -> Void = { _ in }) async throws {
        guard let script = env.script else { throw PoolSetupError.missingScript }
        try checkT3()
        if let conflict = await inspectThisMac() { throw PoolSetupError.conflict(conflict) }
        try await rollingBack {
            var state = freshState()
            try state.save(env.paths)
            let secrets = try storeSecrets(&state, progress: progress)
            progress("Setting up the helper on this Mac")
            try PoolFile.makeFolder(env.paths.helper, secret: true)
            try PoolFile.makeFolder(env.paths.auth, secret: true)
            state.record(.helperFolder)
            try state.save(env.paths)
            try PoolFile.write(
                Data(PoolConfig.helperYAML(secrets: secrets, authDir: env.paths.auth.path).utf8), to: env.paths.config, secret: true)
            try PoolFile.write(Data(PoolInstall.sandboxProfile(paths: env.paths).utf8), to: env.paths.sandbox, secret: true, backup: false)
            try PoolFile.write(script, to: env.paths.updateScript, executable: true, backup: false)
            try PoolFile.write(
                Data(PoolInstall.helperPlist(paths: env.paths).utf8), to: env.paths.agent(Pool.helperLabel), backup: false)
            try PoolFile.write(
                Data(PoolInstall.updatePlist(paths: env.paths).utf8), to: env.paths.agent(Pool.updateLabel), backup: false)
            state.record(.helperAgent)
            state.record(.updateAgent)
            try state.save(env.paths)
            progress("Downloading and checking the helper")
            try PoolInstall.install(paths: env.paths, run: env.run)
            load(Pool.updateLabel)
            try await waitForHelper(secrets)
            try await finishLocal(secrets: secrets, state: &state, progress: progress)
        }
    }

    public func combineOnHome(
        host typed: String, sudoPassword: String? = nil, progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> PoolSleep? {
        guard let script = env.script else { throw PoolSetupError.missingScript }
        let host = try PoolHubPicker.validate(typed)
        try checkT3()
        let remote = PoolRemote(host: host, run: env.run)
        switch try remote.status() {
        case .free: break
        case .relaybarHub: throw PoolSetupError.hubExists(host)
        case .conflict(let conflict): throw PoolSetupError.conflict(conflict)
        }
        if await PoolManagement(secret: "", http: env.http).isUp() { throw PoolSetupError.conflict(.portInUse(Pool.port)) }
        var sleep: PoolSleep?
        try await rollingBack {
            var state = freshState(ssh: host)
            try state.save(env.paths)
            let secrets = try storeSecrets(&state, progress: progress)
            try remote.claim()
            state.record(.remoteHelper)
            try state.save(env.paths)
            try remote.install(secrets: secrets, script: script, progress: progress)
            let kept = remote.keepOn(password: sudoPassword)
            sleep = kept.sleep
            try recordKeepOn(kept.changes, state: &state)
            progress("Connecting this Mac to \(host)")
            try PoolFile.write(
                Data(PoolTunnel.plist(paths: env.paths, destination: host).utf8), to: env.paths.agent(Pool.tunnelLabel), backup: false)
            state.record(.tunnelAgent)
            try state.save(env.paths)
            load(Pool.tunnelLabel)
            try await waitForHelper(secrets)
            try await finishLocal(secrets: secrets, state: &state, progress: progress)
        }
        return sleep
    }

    public func homeStatus(host typed: String) throws -> PoolRemoteStatus {
        try PoolRemote(host: try PoolHubPicker.validate(typed), run: env.run).status()
    }

    public func keepOn(password: String) -> PoolSleep? {
        guard var state = PoolState.load(env.paths), let host = state.ssh, !state.joined else { return nil }
        let kept = PoolRemote(host: host, run: env.run).keepOn(password: password)
        try? recordKeepOn(kept.changes, state: &state)
        return kept.sleep
    }

    private func recordKeepOn(_ changes: PoolKeepOn, state: inout PoolState) throws {
        guard !changes.isEmpty else { return }
        state.keepOn.linger = state.keepOn.linger || changes.linger
        state.keepOn.masked += changes.masked.filter { !state.keepOn.masked.contains($0) }
        state.record(.keepOn)
        try state.save(env.paths)
    }

    @discardableResult
    public func useOnLinux(
        host typed: String, options: PoolAddOptions = PoolAddOptions(), hooks: PoolAddHooks? = nil,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> PoolLinuxClient {
        guard var state = PoolState.load(env.paths) else { throw PoolSetupError.notCombining }
        guard let hub = state.tunnelDestination else { throw PoolSetupError.hubIsThisMac }
        guard let access = accessKey() else { throw PoolSetupError.accessKeyMissing }
        let host = try PoolHubPicker.validate(typed)
        if let old = state.linuxClients.first(where: { $0.host == host }) {
            progress("Clearing the earlier setup on \(host)")
            try PoolJoin.removeLinuxClient(old, hubRoutes: hubRoutes(state), run: env.run)
            state.linuxClients.removeAll { $0.host == host }
            try state.save(env.paths)
        }
        let paths = env.paths
        let client = try await PoolJoin.linuxClient(
            host: host, hub: hub, hubLabel: state.ssh, accessKey: access, options: options, hooks: hooks ?? PoolAddHooks(pause: env.pause),
            run: env.run, progress: progress,
            checkpoint: { partial in
                state.linuxClients.removeAll { $0.host == host }
                if let partial {
                    state.linuxClients.append(partial)
                    state.record(.linuxClient)
                }
                try? state.save(paths)
            })
        try state.save(paths)
        return client
    }

    @discardableResult
    public func removeComputer(host: String) throws -> PoolClientRemoval {
        guard let state = PoolState.load(env.paths), let client = state.linuxClients.first(where: { $0.host == host }) else {
            return PoolClientRemoval()
        }
        let removal = try PoolJoin.removeLinuxClient(client, hubRoutes: hubRoutes(state), run: env.run)
        try dropComputer(host: host)
        return removal
    }

    public func releaseLinger(host: String, ask: @escaping @Sendable (Bool, String) async -> String?) async -> Bool {
        await PoolJoin.releaseLinger(host: host, ask: ask, run: env.run)
    }

    public func forgetComputer(host: String) throws -> PoolClientRemoval {
        guard let state = PoolState.load(env.paths), let client = state.linuxClients.first(where: { $0.host == host }) else {
            return PoolClientRemoval()
        }
        let removal = PoolJoin.forgetLinuxClient(client, hubRoutes: hubRoutes(state), run: env.run)
        try dropComputer(host: host)
        return removal
    }

    private func dropComputer(host: String) throws {
        guard var state = PoolState.load(env.paths) else { return }
        state.linuxClients.removeAll { $0.host == host }
        if state.linuxClients.isEmpty { state.steps.removeAll { $0 == .linuxClient } }
        try state.save(env.paths)
    }

    func hubRoutes(_ state: PoolState) -> [String] { [state.tailscale, state.ssh].compactMap { $0 } }

    public func join(host typed: String, progress: @Sendable (String) -> Void = { _ in }) async throws {
        let host = try PoolHubPicker.validate(typed)
        try checkT3()
        if await PoolManagement(secret: "", http: env.http).isUp() { throw PoolSetupError.conflict(.portInUse(Pool.port)) }
        let secrets = try PoolJoin.readSecrets(host: host, run: env.run)
        try await rollingBack {
            var state = freshState(ssh: host, joined: true)
            try state.save(env.paths)
            _ = try storeSecrets(&state, secrets: secrets, progress: progress)
            progress("Connecting this Mac to \(host)")
            try PoolFile.write(
                Data(PoolTunnel.plist(paths: env.paths, destination: host).utf8), to: env.paths.agent(Pool.tunnelLabel), backup: false)
            state.record(.tunnelAgent)
            try state.save(env.paths)
            load(Pool.tunnelLabel)
            try await waitForHelper(secrets)
            try await confirmHelper(secrets, host: host)
            try await finishLocal(secrets: secrets, state: &state, progress: progress)
        }
    }

    public func refreshUpdateScript() throws -> Bool {
        guard let script = env.script, let state = PoolState.load(env.paths), !state.joined else { return false }
        if let host = state.tunnelDestination { return try PoolRemote(host: host, run: env.run).refreshScript(script) }
        if (try? Data(contentsOf: env.paths.updateScript)) == script { return false }
        try PoolFile.write(script, to: env.paths.updateScript, executable: true, backup: false)
        return true
    }

    public func stop(sudoPassword: String? = nil, progress: @Sendable (PoolStep) -> Void = { _ in }) -> PoolTeardownReport {
        PoolTeardown.run(env, sudoPassword: sudoPassword, progress: progress)
    }

    public func forgetRemote() -> PoolTeardownReport {
        PoolTeardown.forgetRemote(env)
    }

    private func checkT3() throws {
        if env.t3Installed { try env.t3.validate() }
    }

    private func freshState(ssh: String? = nil, joined: Bool = false) -> PoolState {
        var state = PoolState(ssh: ssh, joined: joined)
        state.usageSourceAdded = PoolState.load(env.paths)?.usageSourceAdded ?? false
        return state
    }

    private func rollingBack(_ work: () async throws -> Void) async throws {
        do {
            try await work()
        } catch {
            _ = PoolTeardown.run(env)
            throw error
        }
    }

    private func storeSecrets(
        _ state: inout PoolState, secrets: PoolSecrets = .generate(), progress: @Sendable (String) -> Void
    ) throws -> PoolSecrets {
        progress("Saving the keys in the Keychain")
        try keep(Pool.accessService, secrets.accessKey, step: .keychainAccessKey, state: &state)
        try keep(Pool.managementService, secrets.managementSecret, step: .keychainManagementSecret, state: &state)
        return secrets
    }

    private func keep(_ service: String, _ secret: String, step: PoolStep, state: inout PoolState) throws {
        guard env.keychain.store(service: service, secret: secret) else { throw PoolSetupError.keychain }
        state.record(step)
        try state.save(env.paths)
        guard env.keychain.read(service: service) == secret else { throw PoolSetupError.keychain }
    }

    private func load(_ label: String) {
        let plist = env.paths.agent(label).path
        _ = env.run(Command("/bin/launchctl", ["bootout", "\(env.domain)/\(label)"], limit: 30))
        _ = env.run(Command("/bin/launchctl", ["bootstrap", env.domain, plist], limit: 30))
    }

    private func waitForHelper(_ secrets: PoolSecrets) async throws {
        let api = PoolManagement(secret: secrets.managementSecret, http: env.http)
        for _ in 0..<20 {
            if await api.modelsAnswer(accessKey: secrets.accessKey) { return }
            await env.pause(1)
        }
        throw PoolSetupError.notAnswering
    }

    private func confirmHelper(_ secrets: PoolSecrets, host: String) async throws {
        do { _ = try await PoolManagement(secret: secrets.managementSecret, http: env.http).credentials() } catch {
            throw PoolSetupError.helperNotConfirmed(host)
        }
    }

    private func finishLocal(secrets: PoolSecrets, state: inout PoolState, progress: @Sendable (String) -> Void) async throws {
        let paths = env.paths
        progress("Making the \"all accounts\" folders")
        for folder in [paths.claudeHub, paths.codexHub] where !FileManager.default.fileExists(atPath: folder.path) {
            try PoolFile.makeFolder(folder)
            state.hubFolders.append(folder.lastPathComponent)
            state.record(.hubFolders)
            try state.save(paths)
        }
        try PoolFile.writeOwned(PoolConfig.codexHubConfig(), to: paths.codexConfig)
        try PoolFile.writeOwned(PoolConfig.terminalCommand(claude: true), to: paths.claudeAll, executable: true)
        try PoolFile.writeOwned(PoolConfig.terminalCommand(claude: false), to: paths.codexAll, executable: true)
        state.record(.terminalCommands)
        try state.save(paths)
        guard env.t3Installed else { return }
        progress("Adding the \"all accounts\" entries to T3 Code")
        let t3 = env.t3
        try t3.validate()
        state.record(.t3Entries)
        try state.save(paths)
        try t3.addPoolEntries(
            accessKey: secrets.accessKey, claudeHome: paths.claudeHub.path, codexHome: paths.codexHub.path, hex: Self.combinedColor)
        switch try t3.setPoolDefault() {
        case .set(let previous):
            state.previousSelection = previous
            state.record(.t3Default)
        case .kept: state.defaultKept = true
        case .alreadyPool: break
        }
        try state.save(paths)
        if try t3.addUsageSource(
            url: Pool.base.absoluteString, managementSecret: secrets.managementSecret, alreadyAdded: state.usageSourceAdded)
        {
            state.usageSourceAdded = true
            state.record(.t3UsageSource)
            try state.save(paths)
        }
    }
}

public struct PoolJoinOffer: Equatable, Sendable {
    public let host: String
}

public enum PoolJoin {
    public static func findPools(hosts: [String], env: PoolEnvironment) async -> [PoolJoinOffer] {
        let run = env.run
        return await withTaskGroup(of: (Int, PoolJoinOffer?).self) { group in
            for (index, host) in hosts.enumerated() where (try? PoolHubPicker.validate(host)) != nil {
                group.addTask {
                    guard PoolHubPicker.isHomeAddress(PoolHubPicker.address(of: host, run: run)) else { return (index, nil) }
                    let result = run(PoolSSH.command(host: host, script: "test -f \"\(PoolRemote.joinFile)\" && echo pool"))
                    return (index, result.output.contains("pool") ? PoolJoinOffer(host: host) : nil)
                }
            }
            var found: [(Int, PoolJoinOffer)] = []
            for await (index, offer) in group { if let offer { found.append((index, offer)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public static func readSecrets(host: String, run: CommandRunner) throws -> PoolSecrets {
        let result = run(PoolSSH.command(host: host, script: "cat \"\(PoolRemote.joinFile)\""))
        guard result.succeeded else { throw PoolSSHError.failed(PoolHubPicker.explain(result.error, host: host)) }
        guard let json = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: String],
            let access = json["accessKey"], let management = json["managementSecret"],
            !access.isEmpty, !management.isEmpty, access.allSatisfy(\.isHexDigit), management.allSatisfy(\.isHexDigit)
        else { throw PoolSSHError.failed("\(host) is not running combined accounts from Relaybar.") }
        return PoolSecrets(accessKey: access, managementSecret: management)
    }

    static let clientFolders = [".claude-hub", ".codex-hub", ".config/relaybar"]
    static let clientCommands = ["claude-all", "codex-all"]
}
