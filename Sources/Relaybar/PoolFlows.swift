import AppKit
import RelaybarCore

extension PoolController {
    private var knownKey: String { "poolKnown" }

    private func markKnown() {
        UserDefaults.standard.set(app.accounts.map(\.id), forKey: knownKey)
    }

    private func progress(_ panel: PoolProgressPanel) -> @Sendable (String) -> Void {
        { text in Task { @MainActor in panel.update(message: text) } }
    }

    @objc func combineAccounts() {
        guard !busy else { return }
        let env = environment()
        let config = paths.home.appendingPathComponent(".ssh/config")
        let hosts = PoolHubPicker.parseSSHConfig((try? String(contentsOf: config, encoding: .utf8)) ?? "")
        let services = CombineDialog.Services(
            discover: { await PoolHubPicker.discover(hosts: hosts, env: env) },
            check: { try await PoolHubPicker.check(typed: $0, env: env) },
            setUp: { [weak self] host in self?.setUpSSH(host) })
        guard let choice = CombineDialog(services: services).run() else { return }
        Task {
            if case .computer(let host) = choice {
                guard let exists = await hasRelaybarHub(host) else { return }
                if exists {
                    guard PoolDialogs.useExistingHub(host: host) else { return }
                    if await join(host) { setUpTailscale() }
                    return
                }
            }
            if await combine(on: choice) { setUpTailscale() }
        }
    }

    private func hasRelaybarHub(_ host: String) async -> Bool? {
        busy = true
        defer { busy = false }
        let title = "Checking \(host)"
        let panel = PoolProgressPanel()
        panel.showSetup(title: title, message: "Looking for a helper there")
        let setup = PoolSetup(env: environment())
        var status = PoolRemoteStatus.free
        let worked = await attempt(host: host, title: title, panel: panel) {
            status = try await Task.detached { try setup.homeStatus(host: host) }.value
        }
        panel.close()
        return worked ? status == .relaybarHub : nil
    }

    func setUpSSH(_ host: String) {
        guard PoolSSHSetup.prepare(home: paths.home, run: PoolProcess.run), let command = try? PoolSSHSetup.copyCommand(host: host) else {
            return app.show(
                "Relaybar could not make an SSH key", "Run ssh-keygen -t ed25519 in Terminal, then click Try Again.")
        }
        app.openTerminal(
            command + "\necho\necho 'Done. Go back to Relaybar and click Try Again.'\nprintf 'Press Return to close this window. '\nread _")
    }

    private func attempt(host: String?, title: String, panel: PoolProgressPanel, _ work: () async throws -> Void) async -> Bool {
        while true {
            do {
                try await work()
                return true
            } catch {
                panel.close()
                let message = error.localizedDescription
                guard let host, error is PoolSSHError else {
                    app.show("Relaybar could not finish", message)
                    return false
                }
                let retry = PoolDialogs.failure(host: host, message: message, setUp: { self.setUpSSH(host) })
                guard retry == .again else { return false }
                panel.showSetup(title: title, message: "Trying again")
            }
        }
    }

    private func combine(on choice: CombineDialog.Choice) async -> Bool {
        busy = true
        defer { busy = false }
        let title = "Combining your accounts"
        let panel = PoolProgressPanel()
        panel.showSetup(title: title, message: "Starting")
        let setup = PoolSetup(env: environment())
        let report = progress(panel)
        var host: String?
        var sleep: PoolSleep?
        if case .computer(let name) = choice { host = name }
        let worked = await attempt(host: host, title: title, panel: panel) {
            if let host {
                sleep = try await setup.combineOnHome(host: host, progress: report)
            } else {
                try await setup.combineOnThisMac(progress: report)
            }
        }
        guard worked else { return false }
        var note: String?
        if sleep == .needsPassword, let host { note = await keepOn(host: host, setup: setup) }
        let ended = await signInAll(panel: panel, setup: setup)
        panel.close()
        if ended.stopped {
            await performStop(joined: false)
            return false
        }
        markKnown()
        await fetch()
        await checkTailscale(host: host, panel: panel, title: title)
        if !ended.unsigned.isEmpty {
            let text =
                "These accounts are not signed in yet: " + ended.unsigned.joined(separator: ", ")
                + ". Click them in All accounts to sign in."
            note = [note, text].compactMap { $0 }.joined(separator: "\n\n")
        }
        return finish(host: host, note: note)
    }

    private func keepOn(host: String, setup: PoolSetup) async -> String? {
        var wrong = false
        while let password = PoolDialogs.sudoPassword(host: host, wrong: wrong) {
            let result = await Task.detached { setup.keepOn(password: password) }.value
            if result == .off { return nil }
            wrong = true
        }
        return "Sleep is still on for \(host). Turn it off there so the helper keeps running."
    }

    private func finish(host: String?, note: String?) -> Bool {
        let offer = host != nil && state?.needsTailscale == true
        var note = note
        if state?.defaultKept == true, T3Code.isInstalled {
            let text = "T3 Code still starts new chats with its own default. Pick Claude, all accounts in its model menu."
            note = [note, text].compactMap { $0 }.joined(separator: "\n\n")
        }
        switch PoolDialogs.done(host: host, t3: T3Code.isInstalled, note: note, tailscale: offer) {
        case .openT3: T3Code.open()
        case .tailscale: return true
        case .close: break
        }
        return false
    }

    private func checkTailscale(host: String?, panel: PoolProgressPanel, title: String) async {
        guard host != nil, state?.needsTailscale == true, tailscaleOnThisMac else { return }
        panel.showSetup(title: title, message: "Checking Tailscale")
        await autoSwitch()
        panel.close()
    }

    private func signInAll(panel: PoolProgressPanel, setup: PoolSetup) async -> SignInEnd {
        guard let management = await Task.detached(operation: { setup.management }).value else {
            return SignInEnd(stopped: false, unsigned: app.accounts.map(\.menuName))
        }
        let current = SignInSession(pool: self, panel: panel, management: management)
        session = current
        defer { session = nil }
        return await current.run()
    }

    @objc func useOffer(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String, !busy else { return }
        Task {
            if await join(host) { setUpTailscale() }
        }
    }

    private func join(_ host: String) async -> Bool {
        busy = true
        defer { busy = false }
        let title = "Connecting this Mac"
        let panel = PoolProgressPanel()
        panel.showSetup(title: title, message: "Starting")
        let setup = PoolSetup(env: environment())
        let report = progress(panel)
        let worked = await attempt(host: host, title: title, panel: panel) { try await setup.join(host: host, progress: report) }
        guard worked else { return false }
        panel.close()
        markKnown()
        await fetch()
        await checkTailscale(host: host, panel: panel, title: title)
        return finish(host: host, note: nil)
    }

    @objc func toggleAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let row = PoolAccounts.rows(accounts: inputs(), members: members).first(where: { $0.account.id == id })
        else { return }
        switch PoolAccounts.toggle(row) {
        case .blocked(let message): app.show("It cannot be paused", message)
        case .signIn: Task { await signIn(row.account) }
        case let action:
            let setup = PoolSetup(env: environment())
            Task {
                do {
                    guard let management = await Task.detached(operation: { setup.management }).value else { throw PoolError.unreachable }
                    try await PoolAccounts.apply(action, management: management)
                } catch {
                    app.show("Relaybar could not change the account", error.localizedDescription)
                }
                await fetch()
            }
        }
    }

    func signIn(_ account: PoolAccountInput) async {
        guard !signing, session?.active != true else {
            return app.show("A sign-in is already open", "Finish it in the browser, then try again.")
        }
        let setup = PoolSetup(env: environment())
        guard let management = await Task.detached(operation: { setup.management }).value else {
            return app.show("Relaybar cannot reach the helper", PoolError.unreachable.localizedDescription)
        }
        let panel = PoolProgressPanel()
        let current = SignInSession(pool: self, panel: panel, management: management, only: account.id)
        session = current
        _ = await current.run()
        if session === current { session = nil }
        panel.close()
        await fetch()
    }

    @objc func addAnAccount() {
        app.chooseAndAddAccount()
    }

    func accountAppeared() {
        if let session, session.active { session.accountsChanged() } else { accountsAdded() }
    }

    @objc func changeOrder() {
        let lists = orderLists()
        guard !lists.isEmpty,
            let result = PoolOrderDialog(lists: lists, logos: [.claude: app.claudeLogo, .codex: app.codexLogo]).run()
        else { return }
        let setup = PoolSetup(env: environment())
        do {
            for (kind, emails) in result { try setup.setOrder(kind: kind, emails: emails) }
        } catch {
            return app.show("Relaybar could not save the order", error.localizedDescription)
        }
        let current = members
        Task {
            _ = try? await setup.updateOrder(members: current)
            await fetch()
        }
    }

    @objc func stopCombining() {
        guard !busy, PoolDialogs.stopFirst(joined: state?.joined ?? false), PoolDialogs.stopSecond() else { return }
        Task { await performStop(joined: state?.joined ?? false) }
    }

    func performStop(joined: Bool) async {
        busy = true
        defer { busy = false }
        generation += 1
        let panel = PoolProgressPanel()
        panel.showSetup(title: "Stopping", message: "Starting")
        let setup = PoolSetup(env: environment())
        var password: String?
        var wrong = false
        var report = PoolTeardownReport()
        while true {
            let attempt = password
            report = await Task.detached {
                setup.stop(sudoPassword: attempt, progress: { step in Task { @MainActor in panel.update(message: Self.words(step)) } })
            }.value
            UserDefaults.standard.removeObject(forKey: knownKey)
            clearCache()
            if let host = report.needsPassword {
                panel.close()
                password = PoolDialogs.restoreSleepPassword(host: host, wrong: wrong)
                guard password != nil else { break }
                wrong = true
                panel.showSetup(title: "Stopping", message: "Starting")
                continue
            }
            if let host = report.unreachable {
                panel.close()
                switch PoolDialogs.unreachable(host: host) {
                case .again:
                    panel.showSetup(title: "Stopping", message: "Trying again")
                    continue
                case .forget:
                    report = setup.forgetRemote()
                case .leave:
                    break
                }
            }
            break
        }
        panel.close()
        generation += 1
        clearCache()
        let left = report.unreachable != nil
        let others = report.failed.filter { entry in !(left && entry.step == PoolStep.remoteHelper) }
        guard !others.isEmpty else { return }
        let lines = others.map { "\(Self.words($0.step)): \($0.reason)" }.joined(separator: "\n")
        app.show("Some steps could not be undone", lines + "\n\nFix that, then choose Stop combining again to finish.")
    }

    @objc func useOnLinux() {
        guard !busy, let hub = state?.tunnelDestination else { return }
        var text = ""
        var problem: String?
        var host: String?
        while let typed = PoolDialogs.address(
            text: text, error: problem, title: "Which Linux computer should use your accounts?",
            message: "Relaybar adds claude-all and codex-all there. That computer also needs SSH access to \(hub).",
            accept: "Set Up")
        {
            do {
                host = try PoolHubPicker.validate(typed)
                break
            } catch {
                text = typed
                problem = error.localizedDescription
            }
        }
        guard let host else { return }
        Task { await setUpLinux(host) }
    }

    private func setUpLinux(_ host: String) async {
        busy = true
        defer { busy = false }
        let title = "Setting up \(host)"
        let panel = PoolProgressPanel()
        panel.showSetup(title: title, message: "Starting")
        let setup = PoolSetup(env: environment())
        let report = progress(panel)
        let worked = await attempt(host: host, title: title, panel: panel) {
            try await Task.detached { try setup.useOnLinux(host: host, progress: report) }.value
        }
        guard worked else { return }
        panel.close()
        app.show(
            "\(host) can use your accounts",
            "Run claude-all or codex-all there. Stop combining removes them again.")
    }

    private static func words(_ step: PoolStep) -> String {
        switch step {
        case .keychainAccessKey, .keychainManagementSecret: "Removing the keys from the Keychain"
        case .helperFolder: "Removing the helper's files"
        case .helperAgent: "Stopping the helper"
        case .updateAgent: "Removing the nightly update"
        case .tunnelAgent: "Removing the connection to the home computer"
        case .remoteHelper: "Removing the helper from the home computer"
        case .keepOn: "Turning sleep back on at the home computer"
        case .linuxClient: "Removing the setup from the Linux computers"
        case .hubFolders: "Moving the all accounts folders to the Trash"
        case .terminalCommands: "Removing claude-all and codex-all"
        case .t3Entries: "Removing the entries from T3 Code"
        case .t3UsageSource: "Removing the usage source from T3 Code"
        case .t3Default: "Putting back your T3 Code default"
        }
    }

    func accountsAdded() {
        guard state != nil, !busy else { return }
        Task {
            await fetch()
            let current = inputs()
            guard let saved = UserDefaults.standard.stringArray(forKey: knownKey) else { return markKnown() }
            let missing = Set(PoolAccounts.rows(accounts: current, members: members).filter { $0.state == .notInHelper }.map(\.account.id))
            let offers = PoolAccounts.offers(known: Set(saved), current: current).filter { missing.contains($0.account.id) }
            markKnown()
            for offer in offers where PoolDialogs.offer(offer) { await signIn(offer.account) }
        }
    }
}
