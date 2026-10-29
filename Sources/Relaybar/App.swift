import AppKit
import RelaybarCore
import ServiceManagement
import Sparkle

@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var accounts: [Account] = []
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var watcher: Watcher?
    private var cards: [AccountCard] = []
    private lazy var pool = PoolController(app: self)
    private var timer: Timer?
    private var waitingForLogin: Timer?
    private var logins: [Process] = []
    private let activeGap: TimeInterval = 60
    private let idleInterval: TimeInterval = 300
    let claudeLogo = App.logo("claude")
    let codexLogo = App.logo("codex")

    private static func logo(_ name: String) -> NSImage {
        Bundle.main.url(forResource: name, withExtension: "svg").flatMap(NSImage.init(contentsOf:)) ?? NSImage()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DesktopApp.logos = [DesktopApp.Kind.claude.tool: claudeLogo, DesktopApp.Kind.codex.tool: codexLogo]
        item.autosaveName = "relaybar"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        reload()
        pool.start()
        timer = Timer.scheduledTimer(withTimeInterval: idleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 30
    }

    private func tick() {
        pool.tick()
        let known = Set(accounts.map(\.id))
        if Set(visibleAccounts().map(\.id)) != known {
            reload()
        } else {
            for account in accounts { refresh(account) }
        }
    }

    private func reload() {
        accounts = visibleAccounts()
        watcher = Watcher(paths: accounts.map(\.watchPath)) { [weak self] paths in
            MainActor.assumeIsolated { self?.filesChanged(paths) }
        }
        redraw()
        for account in accounts { refresh(account) }
    }

    private func filesChanged(_ paths: [String]) {
        for account in accounts {
            let touched = paths.filter { $0.hasPrefix(account.id + "/") }
            guard !touched.isEmpty else { continue }
            if !account.isClaude, let folder = touched.last, let result = Fetch.newestCodexLog(in: URL(fileURLWithPath: folder)) {
                account.apply(result)
                redraw()
            } else if account.isClaude {
                refreshSoon(account)
            }
        }
    }

    private func refreshSoon(_ account: Account) {
        let wait = account.lastFetch.addingTimeInterval(activeGap).timeIntervalSinceNow
        if wait <= 0 {
            refresh(account)
        } else if !account.refreshQueued {
            account.refreshQueued = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                MainActor.assumeIsolated {
                    account.refreshQueued = false
                    self?.refresh(account)
                }
            }
        }
    }

    private func refresh(_ account: Account) {
        Task {
            await account.refresh()
            redraw()
            if account.session == nil, account.weekly == nil {
                try? await Task.sleep(for: .seconds(15))
                if accounts.contains(where: { $0 === account }) { refresh(account) }
            }
        }
    }

    func redraw() {
        let parts = accounts.map { account in
            let lines = [account.session, account.weekly].compactMap { $0.map { ("\($0.left)", account.tint.color(for: $0)) } }
            return Render.image(
                logo: logo(for: account), color: account.tint.color, tag: account.tag,
                lines: lines.isEmpty ? [("…", NSColor.secondaryLabelColor)] : lines)
        }
        item.button?.image = Render.row(parts)
        for card in cards { card.needsDisplay = true }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        cards = []
        pool.menuOpened()
        for item in pool.topItems() { menu.addItem(item) }
        for account in accounts {
            if Date().timeIntervalSince(account.lastFetch) > activeGap { refresh(account) }
            let card = AccountCard(
                account: account, logo: logo(for: account), opens: appToOpen(for: account),
                status: { [pool] in pool.status(for: account) },
                open: { path in
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
                })
            cards.append(card)
            let item = NSMenuItem()
            item.view = card
            menu.addItem(item)
        }
        if menu.items.last?.isSeparatorItem != true { menu.addItem(.separator()) }
        for item in pool.entryItems() { menu.addItem(item) }
        menu.addItem(customizeItem())
        let add = NSMenuItem(title: "Add account", action: nil, keyEquivalent: "")
        add.submenu = NSMenu()
        add.submenu?.addItem(action("Claude…", #selector(addClaude), nil))
        add.submenu?.addItem(action("Codex…", #selector(addCodex), nil))
        menu.addItem(add)
        let login = action("Open at login", #selector(toggleLogin), nil)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let update = NSMenuItem(
            title: "Check for updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updater
        menu.addItem(update)
        menu.addItem(action("Quit Relaybar", #selector(NSApplication.terminate(_:)), nil))
    }

    private func customizeItem() -> NSMenuItem {
        let menu = NSMenu()
        for account in accounts {
            let tag = account.tag.isEmpty ? "" : account.tag + "  "
            let item = NSMenuItem(title: tag + account.label, action: nil, keyEquivalent: "")
            item.image = swatch(Render.tint(logo(for: account), account.tint.color))
            let options = NSMenu()
            options.addItem(action("Rename…", #selector(rename(_:)), account))
            if account.id != home(".claude"), account.id != home(".codex"), !DesktopApp.exists(configDir: account.id) {
                options.addItem(action("Make desktop app…", #selector(makeDesktopApp(_:)), account))
            }
            if account.id != home(".claude"), account.id != home(".codex"), T3Code.isInstalled, !T3Code.contains(homePath: account.id) {
                options.addItem(action("Add to T3 Code…", #selector(addToT3(_:)), account))
            }
            options.addItem(action("Remove…", #selector(remove(_:)), account))
            options.addItem(.separator())
            for (index, tint) in Tint.allCases.enumerated() {
                let choice = action(tint.title, #selector(setTint(_:)), account)
                choice.tag = index
                choice.image = swatch(dot(tint.color))
                choice.state = account.tint == tint ? .on : .off
                options.addItem(choice)
            }
            item.submenu = options
            menu.addItem(item)
        }
        if !hidden.isEmpty {
            menu.addItem(.separator())
            menu.addItem(action("Show hidden accounts", #selector(showHidden), nil))
        }
        let item = NSMenuItem(title: "Customize", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private var hidden: [String] {
        get { UserDefaults.standard.stringArray(forKey: "hidden") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "hidden") }
    }

    private func visibleAccounts() -> [Account] {
        let hidden = Set(hidden)
        return Account.discover().filter { !hidden.contains($0.id) }
    }

    @objc private func showHidden() {
        hidden = []
        reload()
    }

    @objc private func remove(_ sender: NSMenuItem) {
        guard let account = sender.representedObject as? Account else { return }
        let tool = account.isClaude ? "Claude" : "Codex"
        let name = account.tag.isEmpty ? account.label : "\(account.tag) (\(account.label))"
        let isMain = account.id == home(".claude") || account.id == home(".codex")

        let first = NSAlert()
        first.messageText = "Remove \(name)?"
        first.informativeText =
            isMain
            ? "This is your main \(tool) folder, so Relaybar can only hide it. Nothing is deleted."
            : "Hide it from Relaybar, or delete the account from this Mac."
        first.addButton(withTitle: "Hide from Relaybar")
        if !isMain { first.addButton(withTitle: "Delete from this Mac…") }
        first.addButton(withTitle: "Cancel")
        NSApp.activate()
        let choice = first.runModal()
        if choice == .alertFirstButtonReturn {
            hidden += [account.id]
            reload()
            return
        }
        guard !isMain, choice == .alertSecondButtonReturn else { return }

        let targets = deletionTargets(for: account)
        let second = NSAlert()
        second.alertStyle = .critical
        second.messageText = "Delete \(name) from this Mac?"
        var details = "These move to the Trash:\n" + targets.map { "  " + tilde($0) }.joined(separator: "\n")
        if case .claude = account.provider {
            details += "\n\nThe saved login in Keychain is removed too. You would need to log in again to use it."
        }
        if T3Code.contains(homePath: account.id) {
            details += "\n\nIts T3 Code entry and favorites are removed too."
        }
        details += "\n\nClose any \(tool) windows or terminals using this account first."
        second.informativeText = details
        second.addButton(withTitle: "Continue")
        second.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard second.runModal() == .alertFirstButtonReturn else { return }

        let word = account.tag.isEmpty ? URL(fileURLWithPath: account.id).lastPathComponent : account.tag
        let field = NSTextField(string: "")
        field.placeholderString = word
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        let third = NSAlert()
        third.alertStyle = .critical
        third.messageText = "Type \(word) to delete this account"
        third.informativeText = "This is the last step."
        third.accessoryView = field
        let delete = third.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        third.addButton(withTitle: "Cancel")
        third.window.initialFirstResponder = field
        NSApp.activate()
        guard third.runModal() == .alertFirstButtonReturn else { return }
        guard field.stringValue.trimmingCharacters(in: .whitespaces) == word else {
            return show("Nothing was deleted", "The text didn't match \(word).")
        }

        var failed: [String] = []
        for path in targets {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            } catch {
                failed.append(tilde(path))
            }
        }
        if case .claude(let service) = account.provider {
            let keychain = Process()
            keychain.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            keychain.arguments = ["delete-generic-password", "-s", service]
            keychain.standardOutput = FileHandle.nullDevice
            keychain.standardError = FileHandle.nullDevice
            try? keychain.run()
            keychain.waitUntilExit()
        }
        if (try? T3Code.remove(homePath: account.id)) == nil { failed.append("T3 Code entry") }
        for key in ["tag:", "color:", "usage:"] { UserDefaults.standard.removeObject(forKey: key + account.id) }
        reload()
        if !failed.isEmpty { show("Some items could not be removed", failed.joined(separator: "\n")) }
    }

    private func deletionTargets(for account: Account) -> [String] {
        ([account.id] + DesktopApp.targets(configDir: account.id)).filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func tilde(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func appToOpen(for account: Account) -> String? {
        let main = [home(".claude"): DesktopApp.Kind.claude.source, home(".codex"): DesktopApp.Kind.codex.source]
        let path = DesktopApp.launcher(configDir: account.id) ?? main[account.id]
        return path.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    }

    func logo(for account: Account) -> NSImage {
        account.isClaude ? claudeLogo : codexLogo
    }

    private func swatch(_ image: NSImage) -> NSImage {
        let sized = image.copy() as? NSImage ?? image
        sized.size = NSSize(width: 14, height: 14)
        return sized
    }

    private func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
    }

    private func action(_ title: String, _ selector: Selector, _ account: Account?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = selector == #selector(NSApplication.terminate(_:)) ? NSApp : self
        item.representedObject = account
        return item
    }

    @objc private func setTint(_ sender: NSMenuItem) {
        guard let account = sender.representedObject as? Account, Tint.allCases.indices.contains(sender.tag) else { return }
        account.tint = Tint.allCases[sender.tag]
        DesktopApp.updateIcon(configDir: account.id, tag: account.tag, color: iconColor(account.tint))
        redraw()
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard let account = sender.representedObject as? Account else { return }
        let field = NSTextField(string: account.tag)
        field.frame = NSRect(x: 0, y: 0, width: 140, height: 24)
        guard ask("Short name for \(account.label)", "Shown on the icon. Up to 3 letters. Leave empty for none.", field) else { return }
        account.tag = String(field.stringValue.trimmingCharacters(in: .whitespaces).prefix(3))
        DesktopApp.updateIcon(configDir: account.id, tag: account.tag, color: iconColor(account.tint))
        redraw()
    }

    @objc private func addClaude() {
        addAccount(.claude)
    }

    @objc private func addCodex() {
        addAccount(.codex)
    }

    func chooseAndAddAccount() {
        let alert = NSAlert()
        alert.messageText = "Add an account"
        alert.informativeText = "Which tool is the account for?"
        alert.addButton(withTitle: "Claude")
        alert.addButton(withTitle: "Codex")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: addAccount(.claude)
        case .alertSecondButtonReturn: addAccount(.codex)
        default: break
        }
    }

    private func addAccount(_ kind: DesktopApp.Kind) {
        let name = NSTextField(string: "")
        name.placeholderString = "Account name, for example Work"
        let tag = NSTextField(string: "")
        tag.placeholderString = "Short name on the icon, for example WK"
        let used = Set(accounts.map(\.tint))
        let colors = colorPicker(selected: Tint.palette.first { !used.contains($0) } ?? .orange)
        let desktop = NSButton(checkboxWithTitle: "Make a \(kind.tool) desktop app for this account", target: nil, action: nil)
        desktop.state = FileManager.default.fileExists(atPath: kind.source) ? .on : .off
        desktop.isEnabled = desktop.state == .on
        guard ask("Add a \(kind.tool) account", "Your browser opens the \(kind.tool) sign-in page.", stack([name, tag, colors, desktop])),
            let slug = slug(name.stringValue)
        else { return }
        let dir = home(".\(kind.tool.lowercased())-" + slug)
        guard create(dir) else { return }
        saveTag(tag.stringValue, for: dir)
        let tint = Tint.allCases[max(0, colors.indexOfSelectedItem)]
        UserDefaults.standard.set(tint.rawValue, forKey: "color:" + dir)
        let title = name.stringValue.trimmingCharacters(in: .whitespaces)
        if desktop.state == .on {
            let shortName = UserDefaults.standard.string(forKey: "tag:" + dir) ?? ""
            do {
                _ = try DesktopApp.make(kind, name: title, configDir: dir, tag: shortName, color: iconColor(tint))
            } catch {
                show("The account was added, but the desktop app was not made", error.localizedDescription)
            }
        }
        do {
            try T3Code.add(claude: kind.tool == "Claude", name: title, color: iconColor(tint), homePath: dir)
        } catch {
            show("The account was added, but not to T3 Code", error.localizedDescription)
        }
        signIn("export \(kind.variable)=\(quote(dir))\nexec " + (kind.tool == "Claude" ? "claude auth login --claudeai" : "codex login"))
        waitForLogin()
    }

    private func signIn(_ script: String) {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("relaybar-login-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        process.arguments = ["-lc", script]
        process.standardInput = FileHandle.nullDevice
        if let output = try? FileHandle(forWritingTo: log) {
            process.standardOutput = output
            process.standardError = output
        }
        let started = Date()
        process.terminationHandler = { finished in
            let failedFast = finished.terminationStatus != 0 && Date().timeIntervalSince(started) < 10
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.logins.removeAll { $0 === finished }
                    if failedFast { self.openTerminal(script) }
                    try? FileManager.default.removeItem(at: log)
                }
            }
        }
        do {
            try process.run()
            logins.append(process)
            DispatchQueue.main.asyncAfter(deadline: .now() + 900) { if process.isRunning { process.terminate() } }
        } catch {
            openTerminal(script)
        }
    }

    private var loginShell: String {
        getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_shell) } ?? "/bin/zsh"
    }

    @objc private func makeDesktopApp(_ sender: NSMenuItem) {
        guard let account = sender.representedObject as? Account else { return }
        let suffix = URL(fileURLWithPath: account.id).lastPathComponent.split(separator: "-").dropFirst()
        let field = NSTextField(string: suffix.map(\.capitalized).joined(separator: " "))
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        let kind: DesktopApp.Kind = account.isClaude ? .claude : .codex
        guard ask("Make a \(kind.tool) desktop app", "The app will be called \(kind.tool) followed by this name.", field) else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return show("Please enter a name", "The name is used for the app.") }
        do {
            let launcher = try DesktopApp.make(kind, name: title, configDir: account.id, tag: account.tag, color: iconColor(account.tint))
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: launcher)])
        } catch {
            show("Could not make the desktop app", error.localizedDescription)
        }
    }

    @objc private func addToT3(_ sender: NSMenuItem) {
        guard let account = sender.representedObject as? Account else { return }
        let suffix = URL(fileURLWithPath: account.id).lastPathComponent.split(separator: "-").dropFirst()
        let field = NSTextField(string: suffix.map(\.capitalized).joined(separator: " "))
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        guard ask("Add \(account.label) to T3 Code", "The name T3 Code shows for this account.", field) else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return show("Please enter a name", "T3 Code shows this name.") }
        do {
            try T3Code.add(claude: account.isClaude, name: title, color: iconColor(account.tint), homePath: account.id)
        } catch {
            show("Could not add it to T3 Code", error.localizedDescription)
        }
    }

    private func colorPicker(selected: Tint) -> NSPopUpButton {
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 26), pullsDown: false)
        for tint in Tint.allCases where tint != .plain {
            picker.addItem(withTitle: tint.title)
            picker.lastItem?.image = dot(tint.color)
        }
        picker.selectItem(withTitle: selected.title)
        return picker
    }

    private func iconColor(_ tint: Tint) -> NSColor {
        tint == .plain ? .systemGray : tint.color
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            show("Could not change the login setting", error.localizedDescription)
        }
    }

    private func waitForLogin() {
        let known = Set(accounts.map(\.id))
        let started = Date()
        waitingForLogin?.invalidate()
        waitingForLogin = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if !Set(self.visibleAccounts().map(\.id)).subtracting(known).isEmpty {
                    timer.invalidate()
                    self.reload()
                    self.pool.accountAppeared()
                } else if Date().timeIntervalSince(started) > 900 {
                    timer.invalidate()
                }
            }
        }
    }

    func openTerminal(_ body: String) {
        let shell = loginShell
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("relaybar-login-\(UUID().uuidString).command")
        do {
            try "#!\(shell) -l\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            show("Could not open a terminal", error.localizedDescription)
        }
    }

    private func ask(_ title: String, _ text: String, _ view: NSView) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.accessoryView = view
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = view is NSStackView ? view.subviews.first : view
        return alert.runModal() == .alertFirstButtonReturn
    }

    func show(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.window.level = .floating
        alert.window.orderFrontRegardless()
        alert.runModal()
    }

    private func stack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: CGFloat(views.count) * 30)
        for field in views.compactMap({ $0 as? NSTextField }) { field.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        return stack
    }

    private func slug(_ name: String) -> String? {
        let slug = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        if slug.isEmpty { show("Please enter a name", "The name is used for the account's folder.") }
        return slug.isEmpty ? nil : slug
    }

    private func create(_ dir: String) -> Bool {
        guard !FileManager.default.fileExists(atPath: dir) else {
            show("That account already exists", dir)
            return false
        }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
            return true
        } catch {
            show("Could not create the account folder", error.localizedDescription)
            return false
        }
    }

    private func saveTag(_ tag: String, for dir: String) {
        let tag = tag.trimmingCharacters(in: .whitespaces)
        if !tag.isEmpty { UserDefaults.standard.set(String(tag.prefix(3)), forKey: "tag:" + dir) }
    }

    private func home(_ path: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path).path
    }

    private func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
