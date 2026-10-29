import AppKit
import RelaybarCore

@MainActor
final class PoolController: NSObject {
    unowned let app: App
    let gap: TimeInterval = 60
    private let scanGap: TimeInterval = 3600
    private(set) var members: [PoolMember] = []
    private(set) var loaded = false
    private var reachable = true
    private var reachReason: String?
    private var lastFetch = Date.distantPast
    private var fetching = false
    private var lastScan = Date.distantPast
    private var offers: [PoolJoinOffer] = []
    private var statuses: [String: PoolStatus] = [:]
    var busy = false
    var generation = 0
    var signing = false
    var session: SignInSession?

    init(app: App) {
        self.app = app
    }

    var paths: PoolPaths { PoolPaths(home: FileManager.default.homeDirectoryForCurrentUser) }

    var state: PoolState? { PoolState.load(paths) }

    func environment() -> PoolEnvironment {
        .live(
            script: Bundle.main.url(forResource: "relaybar-helper", withExtension: "sh"), t3Installed: T3Code.isInstalled,
            openURL: { _ = NSWorkspace.shared.open($0) })
    }

    var hostName: String { state?.ssh ?? "this Mac" }

    func start() {
        guard state != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                MainActor.assumeIsolated { self?.scanIfDue() }
            }
            return
        }
        let setup = PoolSetup(env: environment())
        Task.detached { _ = try? setup.refreshUpdateScript() }
        Task {
            if !busy, state?.needsTailscale == true, tailscaleOnThisMac {
                busy = true
                defer { busy = false }
                await autoSwitch()
            }
            refresh(force: true)
        }
    }

    func tick() {
        refresh()
        scanIfDue()
    }

    func clearCache() {
        members = []
        loaded = false
        reachable = true
        reachReason = nil
        statuses = [:]
    }

    func menuOpened() {
        refresh()
    }

    func kind(of account: Account) -> PoolKind { account.isClaude ? .claude : .codex }

    func inputs() -> [PoolAccountInput] {
        app.accounts.map {
            PoolAccountInput(id: $0.id, kind: kind(of: $0), name: $0.tag.isEmpty ? $0.label : $0.tag, email: $0.label)
        }
    }

    func refresh(force: Bool = false) {
        guard state != nil, !busy, !fetching else { return }
        if !force, Date().timeIntervalSince(lastFetch) < gap { return }
        Task { await fetch() }
    }

    func fetch() async {
        guard state != nil, !fetching else { return }
        lastFetch = Date()
        fetching = true
        defer { fetching = false }
        let started = generation
        let setup = PoolSetup(env: environment())
        guard let management = await Task.detached(operation: { setup.management }).value else {
            guard started == generation else { return }
            reachable = false
            reachReason = nil
            return app.redraw()
        }
        do {
            let credentials = try await management.credentials()
            let fetched = await PoolUsage.fetch(management: management, credentials: credentials)
            guard started == generation else { return }
            members = fetched
            loaded = true
            reachable = true
            reachReason = nil
            _ = try? await setup.updateOrder(members: members)
        } catch {
            let reason = await reachProblem(error)
            guard started == generation else { return }
            reachable = false
            reachReason = reason
        }
        guard started == generation else { return }
        rebuildStatuses()
        app.redraw()
    }

    private func reachProblem(_ error: Error) async -> String? {
        guard let state else { return nil }
        var probe: CommandResult?
        if !PoolReach.isRejectedKey(error), let target = state.tunnelDestination, !state.runsOnThisMac {
            probe = await Task.detached { PoolProcess.run(PoolReach.probe(host: target)) }.value
        }
        return PoolReach.reason(host: hostName, error: error, probe: probe)
    }

    private func unreachableItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Cannot reach \(hostName).", action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let reachReason { subtitle(item, reachReason) }
        return item
    }

    func status(for account: Account) -> PoolStatus? {
        statuses[account.id]
    }

    private func rebuildStatuses() {
        statuses = [:]
        guard loaded else { return }
        let saved = state?.order ?? [:]
        let joined = state?.joined == true
        var inUse: [PoolKind: String] = [:]
        for kind in [PoolKind.claude, .codex] {
            let plan = PoolOrder.plan(
                kind: kind, members: members, saved: saved[kind.rawValue] ?? [], mode: state?.orderMode ?? .automatic)
            let current = joined ? PoolOrder.inUse(kind: kind, members: members) : plan.inUse
            inUse[kind] = current?.credential.email.lowercased()
        }
        for row in PoolAccounts.rows(accounts: inputs(), members: members) {
            switch row.state {
            case .paused: statuses[row.account.id] = .paused
            case .signedOut: statuses[row.account.id] = .signedOut
            case .active:
                if inUse[row.account.kind] == row.account.email?.lowercased() { statuses[row.account.id] = .inUse }
            case .notInHelper: break
            }
        }
    }

    private func scanIfDue() {
        guard !busy, state == nil, Date().timeIntervalSince(lastScan) >= scanGap else { return }
        lastScan = Date()
        let config = paths.home.appendingPathComponent(".ssh/config")
        let hosts = PoolHubPicker.parseSSHConfig((try? String(contentsOf: config, encoding: .utf8)) ?? "")
        guard !hosts.isEmpty else {
            offers = []
            return
        }
        let env = environment()
        Task { offers = await PoolJoin.findPools(hosts: hosts, env: env) }
    }

    func account(for credential: PoolCredential) -> Account? {
        app.accounts.first {
            kind(of: $0) == credential.kind && !credential.email.isEmpty && $0.label.lowercased() == credential.email.lowercased()
        }
    }

    func tagModel(for member: PoolMember) -> PoolTagModel {
        let account = account(for: member.credential)
        let text =
            account.map { $0.tag.isEmpty ? String($0.label.prefix(2)).uppercased() : $0.tag }
            ?? String(member.credential.email.prefix(2)).uppercased()
        let tint = account.map(\.tint)
        let plain = tint == nil || tint == .plain
        var paused = false
        if case .paused = member.state { paused = true }
        return PoolTagModel(
            text: text, color: plain ? .secondaryLabelColor : (tint?.color ?? .secondaryLabelColor),
            textColor: plain ? .windowBackgroundColor : .black, paused: paused)
    }

    func topItems() -> [NSMenuItem] {
        guard !busy, state == nil, let offer = offers.first else { return [] }
        let item = NSMenuItem(title: "Use combined accounts", action: #selector(useOffer(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = offer.host
        item.image = swatch(Render.tint(app.claudeLogo, PoolStatus.color))
        subtitle(
            item,
            T3Code.isInstalled
                ? "From \(offer.host). Adds them to T3 Code here." : "From \(offer.host). Adds claude-all and codex-all here.")
        return [item, .separator()]
    }

    func entryItems() -> [NSMenuItem] {
        if busy {
            let item = NSMenuItem(title: "Working on combined accounts…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return [item]
        }
        if state != nil { return [allAccountsItem()] }
        guard offers.isEmpty else { return [] }
        let item = NSMenuItem(title: "Combine accounts…", action: #selector(combineAccounts), keyEquivalent: "")
        item.target = self
        return [item]
    }

    private func allAccountsItem() -> NSMenuItem {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if loaded {
            if !reachable {
                menu.addItem(unreachableItem())
                menu.addItem(.separator())
            }
            let rows = PoolAccounts.rows(accounts: inputs(), members: members)
            for kind in [PoolKind.claude, .codex] {
                let mine = rows.filter { $0.account.kind == kind }
                guard !mine.isEmpty else { continue }
                menu.addItem(.sectionHeader(title: kind == .claude ? "Claude" : "Codex"))
                for row in mine { menu.addItem(accountItem(row, of: mine.count)) }
            }
            menu.addItem(.separator())
            menu.addItem(action("Add an account…", #selector(addAnAccount)))
            if !orderLists().isEmpty {
                let order = action("Change order…", #selector(changeOrder))
                if state?.joined == true {
                    order.isEnabled = false
                    subtitle(order, "Set on the Mac that set up \(hostName).")
                }
                menu.addItem(order)
            }
        } else {
            if reachable {
                let item = NSMenuItem(title: "Reading the helper…", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                menu.addItem(unreachableItem())
            }
        }
        let computers = state?.linuxClients ?? []
        if !computers.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Computers"))
            for computer in computers { menu.addItem(computerItem(computer.host)) }
        }
        menu.addItem(.separator())
        if state?.ssh != nil { menu.addItem(action("Add a computer…", #selector(addComputer))) }
        if state?.needsTailscale == true { menu.addItem(action("Use it away from home…", #selector(setUpTailscale))) }
        menu.addItem(action("Stop combining…", #selector(stopCombining)))
        let item = NSMenuItem(title: "All accounts", action: nil, keyEquivalent: "")
        item.submenu = menu
        subtitle(item, "On \(hostName)")
        return item
    }

    private func computerItem(_ host: String) -> NSMenuItem {
        let remove = NSMenuItem(title: "Remove \(host)…", action: #selector(removeComputer(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = host
        let menu = NSMenu()
        menu.addItem(remove)
        let item = NSMenuItem(title: host, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func accountItem(_ row: PoolAccountRow, of count: Int) -> NSMenuItem {
        let account = row.account
        let item = NSMenuItem(title: account.name, action: #selector(toggleAccount(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = account.id
        if let match = app.accounts.first(where: { $0.id == account.id }) {
            item.image = swatch(Render.tint(app.logo(for: match), match.tint == .plain ? NSColor.labelColor : match.tint.color))
        }
        let tool = account.kind == .claude ? "Claude" : "Codex"
        switch row.state {
        case .active:
            item.state = .on
            if !row.canPause {
                item.isEnabled = false
                subtitle(
                    item, count == 1 ? "Only \(tool) account. It cannot be paused." : "Last \(tool) account in use. It cannot be paused.")
            }
        case .paused:
            subtitle(item, "Paused. Click to use it again.")
        case .signedOut:
            item.state = .on
            subtitle(item, "Signed out. Click to sign in again.", red: true)
        case .notInHelper:
            subtitle(item, "Not signed in. Click to sign in.")
        }
        return item
    }

    private func subtitle(_ item: NSMenuItem, _ text: String, red: Bool = false) {
        if !red, #available(macOS 14.4, *) {
            item.subtitle = text
            return
        }
        let title = NSMutableAttributedString(string: item.title + "\n", attributes: [.font: NSFont.menuFont(ofSize: 0)])
        title.append(
            NSAttributedString(
                string: text,
                attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: red ? NSColor.systemRed : NSColor.secondaryLabelColor]))
        item.attributedTitle = title
    }

    private func swatch(_ image: NSImage) -> NSImage {
        let sized = image.copy() as? NSImage ?? image
        sized.size = NSSize(width: 14, height: 14)
        return sized
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    func orderLists(live: Bool = false) -> [PoolOrderList] {
        let saved = state?.order ?? [:]
        return [PoolKind.claude, .codex].compactMap { kind in
            let plan = PoolOrder.plan(kind: kind, members: members, saved: saved[kind.rawValue] ?? [], mode: live ? .automatic : .manual)
            let order = live ? plan.effective.map { $0.credential.email.lowercased() } : plan.savedOrder
            let entries = order.compactMap { email -> PoolOrderEntry? in
                guard let member = members.first(where: { $0.credential.kind == kind && $0.credential.email.lowercased() == email })
                else { return nil }
                var session = "–"
                var weekly = "–"
                if case .active(let first, let second) = member.state {
                    session = first.map { "\($0.left)%" } ?? "–"
                    weekly = second.map { "\($0.left)%" } ?? "–"
                }
                let found = account(for: member.credential)
                let name = found.map {
                    URL(fileURLWithPath: $0.id).lastPathComponent.split(separator: "-").dropFirst().map(\.capitalized).joined(
                        separator: " ")
                }
                let label = name.flatMap { $0.isEmpty ? nil : $0 } ?? found?.label ?? member.credential.email
                return PoolOrderEntry(email: email, tag: tagModel(for: member), label: label, session: session, weekly: weekly)
            }
            return entries.count > 1 ? PoolOrderList(kind: kind, entries: entries) : nil
        }
    }
}
