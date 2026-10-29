import Foundation

public enum PoolSetupError: Error, Equatable, LocalizedError {
    case conflict(PoolConflict)
    case missingScript
    case keychain
    case notAnswering
    case hubExists(String)

    public var errorDescription: String? {
        switch self {
        case .conflict(let conflict): return conflict.message
        case .missingScript: return "Relaybar's helper installer is missing from the app. Reinstall Relaybar, then try again."
        case .keychain: return "Relaybar could not save a key in the Keychain. Unlock the Keychain, then try again."
        case .notAnswering:
            return "The helper did not start. Nothing was kept. Check the internet connection and try again."
        case .hubExists(let host):
            return "\(host) already combines accounts. Relaybar left it alone. Use it from this Mac instead."
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

    public func useOnLinux(host typed: String, progress: @Sendable (String) -> Void = { _ in }) throws {
        guard var state = PoolState.load(env.paths), let hub = state.tunnelDestination, let access = accessKey(),
            let secret = env.keychain.read(service: Pool.managementService)
        else { throw PoolSetupError.notAnswering }
        let host = try PoolHubPicker.validate(typed)
        progress("Setting up \(host)")
        let client = try PoolJoin.linuxClient(
            host: host, hub: hub, secrets: PoolSecrets(accessKey: access, managementSecret: secret), run: env.run)
        state.linuxClients.removeAll { $0.host == host }
        state.linuxClients.append(client)
        state.record(.linuxClient)
        try state.save(env.paths)
    }

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

    public static func linuxClient(host: String, hub: String, secrets: PoolSecrets, run: @escaping CommandRunner) throws -> PoolLinuxClient
    {
        let remote = PoolRemote(host: host, run: run)
        let hubName = try PoolHubPicker.validate(hub)
        let home = try remote.remoteHome()
        let marker = PoolFile.marker
        let probe = try remote.execute(
            "for d in \(clientFolders.joined(separator: " ")); do [ -e \"$HOME/$d\" ] || echo new:$d; done; "
                + "for f in \(clientCommands.joined(separator: " ")); do p=\"$HOME/.local/bin/$f\"; "
                + "if [ -e \"$p\" ] && ! grep -q '\(marker)' \"$p\" 2>/dev/null; then echo foreign:$f; fi; done; "
                + "[ \"$(loginctl show-user \"$(id -un)\" -p Linger --value 2>/dev/null)\" = yes ] || echo linger:off")
        let lines = probe.split(whereSeparator: \.isNewline).map(String.init)
        if let foreign = lines.first(where: { $0.hasPrefix("foreign:") }) {
            throw PoolFileError.notRelaybars("\(host):.local/bin/\(foreign.dropFirst(8))")
        }
        var client = PoolLinuxClient(
            host: host, folders: lines.filter { $0.hasPrefix("new:") }.map { String($0.dropFirst(4)) })
        let keyFile = "$HOME/.config/relaybar/access-key"
        do {
            try remote.execute(
                "umask 077; mkdir -p \"$HOME/.config/relaybar\" \"$HOME/.config/systemd/user\"; cat > \"\(keyFile)\"",
                stdin: Data(secrets.accessKey.utf8))
            try remote.execute("mkdir -p \"$HOME/.claude-hub\" \"$HOME/.codex-hub\" \"$HOME/.local/bin\"")
            let config = PoolConfig.codexHubConfig(keyCommand: ["/bin/cat", home + "/.config/relaybar/access-key"])
            try remote.execute("cat > \"$HOME/.codex-hub/config.toml\"", stdin: Data(config.utf8))
            let read = "cat \"\(keyFile)\""
            for (name, claude) in [("claude-all", true), ("codex-all", false)] {
                try remote.execute(
                    "cat > \"$HOME/.local/bin/\(name)\"; chmod 755 \"$HOME/.local/bin/\(name)\"",
                    stdin: Data(PoolConfig.terminalCommand(claude: claude, keyCommand: read).utf8))
            }
            try remote.execute(
                "cat > \"$HOME/.config/systemd/user/relaybar-tunnel.service\"",
                stdin: Data(PoolTunnel.linuxUnit(destination: hubName).utf8))
            if lines.contains("linger:off") {
                let enabled = try remote.execute(
                    "u=$(id -un); { loginctl enable-linger \"$u\" 2>/dev/null || sudo -n loginctl enable-linger \"$u\" 2>/dev/null; } "
                        + "&& echo changed:linger; true")
                client.linger = enabled.contains("changed:linger")
            }
            try remote.execute("systemctl --user daemon-reload && systemctl --user enable --now relaybar-tunnel.service")
            let answer = try remote.execute(
                "i=0; while [ $i -lt 15 ]; do c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:\(Pool.port)/v1/models); "
                    + "[ \"$c\" = 401 ] && { echo up; exit 0; }; sleep 1; i=$((i+1)); done; echo down")
            guard answer.trimmingCharacters(in: .whitespacesAndNewlines) == "up" else {
                throw PoolSSHError.failed(
                    "\(host) could not reach \(hubName). Add the SSH key of \(host) to \(hubName), then try again.")
            }
        } catch {
            try? removeLinuxClient(client, run: run)
            throw error
        }
        return client
    }

    public static func removeLinuxClient(_ client: PoolLinuxClient, run: @escaping CommandRunner) throws {
        var steps = [
            "systemctl --user disable --now relaybar-tunnel.service >/dev/null 2>&1",
            "rm -f \"$HOME/.config/systemd/user/relaybar-tunnel.service\" \"$HOME/.config/relaybar/access-key\" \"$HOME/.codex-hub/config.toml\"",
            "for f in \(clientCommands.joined(separator: " ")); do p=\"$HOME/.local/bin/$f\"; grep -q '\(PoolFile.marker)' \"$p\" 2>/dev/null && rm -f \"$p\"; done",
            "systemctl --user daemon-reload >/dev/null 2>&1",
        ]
        for folder in client.folders where clientFolders.contains(folder) {
            steps.append("rmdir \"$HOME/\(folder)\" 2>/dev/null")
        }
        if client.linger {
            steps.append("u=$(id -un); loginctl disable-linger \"$u\" 2>/dev/null || sudo -n loginctl disable-linger \"$u\" 2>/dev/null")
        }
        let result = run(PoolSSH.command(host: client.host, script: steps.joined(separator: "; ") + "; true"))
        guard result.succeeded else { throw PoolSSHError.failed(PoolHubPicker.explain(result.error, host: client.host)) }
    }
}
