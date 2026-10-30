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

    private func attempt(host: String?, title: String, panel: some PoolWorkPanel, _ work: () async throws -> Void) async -> Bool {
        while true {
            do {
                try await work()
                return true
            } catch is CancellationError {
                panel.close()
                return false
            } catch {
                panel.close()
                let message = error.localizedDescription
                guard let host, error is PoolSSHError || (error as? PoolClientError)?.offersRetry == true else {
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
            let text = "T3 Code still starts new chats with its own default. Pick Claude+ in its model menu."
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
            let result = PoolOrderDialog(
                lists: lists, live: orderLists(live: true), mode: state?.orderMode ?? .automatic,
                logos: [.claude: app.claudeLogo, .codex: app.codexLogo]
            ).run()
        else { return }
        let setup = PoolSetup(env: environment())
        do {
            try setup.setOrderMode(result.mode)
            for (kind, emails) in result.orders { try setup.setOrder(kind: kind, emails: emails) }
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
        guard !busy, PoolDialogs.stopFirst(joined: state?.joined ?? false, host: state?.ssh), PoolDialogs.stopSecond() else { return }
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
        let hub = state?.ssh ?? "the home computer"
        var keysLeft: [String] = []
        var lingerStays: [String] = []
        var t3LinkStays: [String] = []
        var keptBackups: [String] = []
        var leftAlone: Set<String> = []
        while true {
            let attempt = password
            report = await Task.detached {
                setup.stop(sudoPassword: attempt, progress: { step in Task { @MainActor in panel.update(message: Self.words(step)) } })
            }.value
            UserDefaults.standard.removeObject(forKey: knownKey)
            clearCache()
            keysLeft += report.keysLeft
            lingerStays += report.lingerStays
            t3LinkStays += report.t3LinkStays
            keptBackups += report.keptBackups
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
            var again = false
            var forgot = false
            for host in report.unreachableComputers where !leftAlone.contains(host) {
                panel.close()
                switch PoolDialogs.unreachable(host: host, reason: report.failed.first { $0.step == .linuxClient }?.reason ?? "") {
                case .again: again = true
                case .forget:
                    let removal = await Task.detached { try? setup.forgetComputer(host: host) }.value
                    if removal?.hubKeyProblem != nil { keysLeft.append(host) }
                    forgot = true
                case .leave: leftAlone.insert(host)
                }
            }
            if again || forgot {
                panel.showSetup(title: "Stopping", message: "Trying again")
                continue
            }
            break
        }
        panel.close()
        generation += 1
        clearCache()
        if joined, !keysLeft.isEmpty { showKeysLeft(hub: hub, names: keysLeft) }
        await releaseLinger(lingerStays)
        showT3LinkStays(t3LinkStays)
        showKeptBackups(keptBackups)
        let hubLeft = report.unreachable != nil
        let computersLeft = !report.unreachableComputers.isEmpty
        let others = report.failed.filter { entry in
            !(hubLeft && entry.step == PoolStep.remoteHelper) && !(computersLeft && entry.step == PoolStep.linuxClient)
        }
        guard !others.isEmpty else { return }
        let lines = others.map { "\(Self.words($0.step)): \($0.reason)" }.joined(separator: "\n")
        app.show("Some steps could not be undone", lines + "\n\nFix that, then choose Stop combining again to finish.")
    }

    @objc func addComputer() {
        guard !busy, let state else { return }
        let config = paths.home.appendingPathComponent(".ssh/config")
        let names = PoolHubPicker.parseSSHConfig((try? String(contentsOf: config, encoding: .utf8)) ?? "")
        let skip = [state.ssh, state.tailscale].compactMap { $0 } + state.linuxClients.map(\.host)
        busy = true
        Task {
            defer { busy = false }
            let hosts = await Task.detached { PoolHubPicker.addable(hosts: names, excluding: skip, run: PoolProcess.run) }.value
            let tailscale = tailscaleOnThisMac || state.onTailscale
            guard let choice = AddComputerDialog(hosts: hosts, t3: T3Code.isInstalled, tailscale: tailscale).run() else { return }
            await setUpLinux(choice)
        }
    }

    private func setUpLinux(_ choice: AddComputerDialog.Choice) async {
        let host = choice.host
        let panel = PoolAddPanel(host: host, hub: state?.ssh ?? "the home computer")
        panel.show()
        let setup = PoolSetup(env: environment())
        let options = PoolAddOptions(t3Channel: choice.t3 ? T3Code.channel : nil, tailscale: choice.tailscale)
        let hooks = PoolAddHooks(
            plan: { stages in DispatchQueue.main.async { MainActor.assumeIsolated { panel.plan(stages) } } },
            report: { stage, stageState in DispatchQueue.main.async { MainActor.assumeIsolated { panel.set(stage, stageState) } } },
            password: { wrong, why in
                await MainActor.run { PoolDialogs.computerPassword(host: host, wrong: wrong, why: why) }
            },
            signIn: { link in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        panel.showSignIn(link)
                        NSWorkspace.shared.open(link)
                    }
                }
            },
            pair: { link in
                guard PoolJoin.isPairLink(link) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        panel.rememberPairLink(link)
                        _ = NSWorkspace.shared.open(link)
                    }
                }
            },
            linkFailed: { name in await MainActor.run { PoolDialogs.linkFailed(host: name) } },
            replaceLogins: { name in await MainActor.run { PoolDialogs.replaceLogins(host: name) } })
        var added: PoolAddResult?
        let worked = await attempt(host: host, title: "Setting up \(host)", panel: panel) {
            let work = Task.detached { try await setup.useOnLinux(host: host, options: options, hooks: hooks) }
            panel.onCancel = { work.cancel() }
            added = try await work.value
        }
        panel.close()
        guard worked, let added else { return }
        PoolDialogs.addedComputer(host: host, result: added)
    }

    @objc func removeComputer(_ sender: NSMenuItem) {
        guard !busy, let host = sender.representedObject as? String,
            PoolDialogs.removeComputerFirst(host: host, client: state?.linuxClients.first { $0.host == host }),
            PoolDialogs.removeComputerSecond(host: host)
        else { return }
        Task { await performRemoveComputer(host) }
    }

    private func performRemoveComputer(_ host: String) async {
        busy = true
        defer { busy = false }
        let title = "Removing \(host)"
        let panel = PoolProgressPanel()
        panel.showSetup(title: title, message: "Starting")
        let setup = PoolSetup(env: environment())
        var removal: PoolClientRemoval?
        while removal == nil {
            do {
                removal = try await Task.detached { try setup.removeComputer(host: host) }.value
            } catch {
                panel.close()
                switch PoolDialogs.unreachable(host: host, reason: error.localizedDescription) {
                case .again: panel.showSetup(title: title, message: "Trying again")
                case .forget: removal = await Task.detached { (try? setup.forgetComputer(host: host)) ?? PoolClientRemoval() }.value
                case .leave: return
                }
            }
        }
        panel.close()
        if removal?.hubKeyProblem != nil { showKeysLeft(hub: state?.ssh ?? "the home computer", names: [host]) }
        if removal?.lingerStays == true { await releaseLinger([host]) }
        if removal?.t3LinkStays == true { showT3LinkStays([host]) }
        showKeptBackups((removal?.keptBackups ?? []).map { "\(host): \($0)" })
    }

    private func showKeptBackups(_ files: [String]) {
        guard !files.isEmpty else { return }
        app.show(
            "Relaybar kept some old files",
            "You changed these files after Relaybar switched them, so Relaybar took out only its own lines and kept your changes. The old copy of each is still there:\n"
                + files.joined(separator: "\n"))
    }

    private func showT3LinkStays(_ hosts: [String]) {
        guard !hosts.isEmpty else { return }
        app.show(
            "T3 Code still trusts this Mac at \(hosts.joined(separator: ", "))",
            "Relaybar could not end the link between this Mac and T3 Code there. To end it, open T3 Code there, go to its sessions and revoke the one called Relaybar."
        )
    }

    private func releaseLinger(_ hosts: [String]) async {
        let setup = PoolSetup(env: environment())
        var stuck: [String] = []
        for host in hosts {
            let off = await Task.detached {
                await setup.releaseLinger(host: host) { wrong, why in
                    await MainActor.run { PoolDialogs.computerPassword(host: host, wrong: wrong, why: why) }
                }
            }.value
            if !off { stuck.append(host) }
        }
        guard !stuck.isEmpty else { return }
        app.show(
            "A setting stays on at \(stuck.joined(separator: ", "))",
            "Relaybar set it to keep programs running after you log out. It could not undo that. To undo it, run this on the computer: sudo loginctl disable-linger $(id -un)"
        )
    }

    private func showKeysLeft(hub: String, names: [String]) {
        app.show(
            "Some keys are still on \(hub)",
            "Relaybar could not reach \(hub) to remove the keys of \(names.joined(separator: ", ")). They can only open the helper port. Remove the lines that end in relaybar-client:<name> from ~/.ssh/authorized_keys on \(hub), or stop combining on the Mac that set it up."
        )
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
        case .linuxClient: "Removing the setup from the other computers"
        case .hubFolders: "Moving the old all accounts folders to the Trash"
        case .terminalCommands: "Removing claude+ and codex+"
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
