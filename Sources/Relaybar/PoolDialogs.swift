import AppKit
import RelaybarCore

enum PoolRetry {
    case again
    case cancel
}

@MainActor
enum PoolDialogs {
    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        return alert.runModal()
    }

    static func label(_ text: String, size: CGFloat = 11, color: NSColor = .secondaryLabelColor, width: CGFloat = 300) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = color
        field.preferredMaxLayoutWidth = width
        return field
    }

    static func fit(_ stack: NSStackView) {
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
    }

    static func column(_ views: [NSView], width: CGFloat = 300, spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        for view in views { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return stack
    }

    private static func stopAlert(_ title: String, _ text: String, go: String, destructive: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = text
        let action = alert.addButton(withTitle: go)
        action.hasDestructiveAction = destructive
        action.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        return run(alert) == .alertFirstButtonReturn
    }

    static func stopFirst(joined: Bool, host: String?) -> Bool {
        let others = host.map { " Other Macs and computers that use your accounts through \($0) stop working too." } ?? ""
        return stopAlert(
            "Stop combining?",
            joined
                ? "Relaybar removes Claude and Codex, all accounts, from T3 Code on this Mac. The home computer keeps the helper for your other computers."
                : "Relaybar removes Claude and Codex, all accounts, from T3 Code and signs every account out of the helper. Your own accounts do not change."
                    + others,
            go: "Continue…", destructive: false)
    }

    static func stopSecond() -> Bool {
        stopAlert(
            "Are you sure?", "Chats that use all accounts will stop working. To combine again, you sign in to each account again.",
            go: "Stop", destructive: true)
    }

    static func removeComputerFirst(host: String, client: PoolLinuxClient?) -> Bool {
        stopAlert("Remove \(host)?", removeText(host: host, client: client), go: "Continue…", destructive: false)
    }

    static func removeText(host: String, client: PoolLinuxClient?) -> String {
        let note = client.map(PoolJoin.removalNote) ?? ""
        guard let client, !note.isEmpty else {
            return
                "Relaybar removes claude-all, codex-all and the T3 Code entries from \(host), and its key from the home computer. Your accounts stay in the helper."
        }
        let unlink =
            client.t3Installed
            ? " To clear \(host) from T3 Code on this Mac, use Settings, Connections, Remove from this device."
            : ""
        return "\(host) will stop using your accounts. \(note)\(unlink)"
    }

    static func removeComputerSecond(host: String) -> Bool {
        stopAlert(
            "Are you sure?", "\(host) will stop using your accounts. To use them there again, choose Add a computer.", go: "Remove",
            destructive: true)
    }

    enum Done {
        case openT3
        case close
        case tailscale
    }

    private static let tailscaleCode = NSApplication.ModalResponse(rawValue: 1001)

    static func done(host: String?, t3: Bool, note: String?, tailscale: Bool = false) -> Done {
        let alert = NSAlert()
        alert.icon = badged(NSApp.applicationIconImage, symbol: "checkmark.circle.fill", color: .systemGreen)
        alert.messageText = "Your accounts are combined on \(host ?? "this Mac")."
        let first =
            t3
            ? "New chats in T3 Code now use Claude, all accounts."
            : "Use the claude-all and codex-all commands in a terminal to use your combined accounts."
        var text = first + (tailscale ? " It works on your home Wi-Fi." : t3 ? " T3 Code also shows what is left on each account." : "")
        if let note { text += "\n\n" + note }
        alert.informativeText = text
        if tailscale, let host {
            let box = TailscaleBox(host: host) { NSApp.stopModal(withCode: tailscaleCode) }
            alert.accessoryView = box.view
        }
        if t3 { alert.addButton(withTitle: "Open T3 Code") }
        alert.addButton(withTitle: "Close")
        let response = run(alert)
        if response == tailscaleCode { return .tailscale }
        return t3 && response == .alertFirstButtonReturn ? .openT3 : .close
    }

    static func offer(_ offer: PoolAccountOffer) -> Bool {
        let name = offer.account.name
        let alert = NSAlert()
        alert.messageText = offer.title
        alert.informativeText = "\(name) is now in Relaybar. Relaybar opens the browser so you can sign \(name) in to the helper once."
        alert.addButton(withTitle: offer.addButton)
        alert.addButton(withTitle: offer.declineButton)
        return run(alert) == .alertFirstButtonReturn
    }

    static func failure(host: String, message: String, setUp: () -> Void) -> PoolRetry {
        let canSetUp = PoolSSHSetup.needsKey(message)
        while true {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = canSetUp ? "Relaybar could not sign in to \(host)." : "Relaybar cannot use \(host)."
            alert.informativeText = message
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Cancel")
            if canSetUp { alert.addButton(withTitle: "Set Up SSH for Me") }
            switch run(alert) {
            case .alertFirstButtonReturn: return .again
            case .alertThirdButtonReturn: setUp()
            default: return .cancel
            }
        }
    }

    static func address(
        text: String, error: String?, title: String = "Which computer should run the helper?",
        message: String = "It must be a Linux computer at home that you can reach with SSH from this Mac.",
        accept: String = "Use this computer"
    ) -> String? {
        let field = NSTextField(string: text)
        field.placeholderString = "192.168.1.20"
        let hint = label(
            error ?? "For example 192.168.1.20, a Tailscale address, or a name from your SSH settings.",
            color: error == nil ? .secondaryLabelColor : Tint.low)
        let stack = column([label("Address or SSH name"), field, hint], spacing: 6)
        fit(stack)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = stack
        alert.addButton(withTitle: accept)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard run(alert) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func useExistingHub(host: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(host) already combines your accounts. Use them on this Mac?"
        alert.informativeText = "Relaybar leaves the helper on \(host) as it is. This Mac connects to it."
        alert.addButton(withTitle: "Use")
        alert.addButton(withTitle: "Cancel")
        return run(alert) == .alertFirstButtonReturn
    }

    enum Unreachable {
        case again
        case forget
        case leave
    }

    static func unreachable(host: String, reason: String? = nil) -> Unreachable {
        let computer = reason != nil
        while true {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Relaybar could not reach \(host)."
            alert.informativeText = reason.map { "Your accounts are still set up there.\n\n" + $0 } ?? "The helper there is still running."
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Forget It…")
            alert.addButton(withTitle: "Leave It")
            switch run(alert) {
            case .alertFirstButtonReturn: return .again
            case .alertSecondButtonReturn:
                if stopAlert(
                    "Forget \(host)?",
                    computer
                        ? "Relaybar leaves the setup on \(host) and stops tracking it. It also removes the key of \(host) from the home computer when it can. You can remove the rest there by hand later."
                        : "Relaybar leaves the helper running on \(host) and stops tracking it. You can remove it there by hand later.",
                    go: "Forget It", destructive: true)
                {
                    return .forget
                }
            default: return .leave
            }
        }
    }

    static func restoreSleepPassword(host: String, wrong: Bool) -> String? {
        password(
            title: "Turn sleep back on for \(host)?", wrong: wrong, host: host, accept: "Turn On", skip: "Skip",
            text: "Relaybar needs your password on \(host) once to turn sleep back on there. Relaybar does not save it.")
    }

    static func sudoPassword(host: String, wrong: Bool) -> String? {
        password(
            title: "Keep \(host) on?", wrong: wrong, host: host, accept: "Keep It On", skip: "Skip",
            text:
                "To keep the helper running when nobody is signed in, Relaybar needs your password on \(host) once. Relaybar does not save it."
        )
    }

    static func tailscalePassword(host: String, wrong: Bool) -> String? {
        password(
            title: "Install Tailscale on \(host)?", wrong: wrong, host: host, accept: "Install", skip: "Cancel",
            text: "Relaybar needs your password on \(host) once to install Tailscale there. Relaybar does not save it.")
    }

    static func computerPassword(host: String, wrong: Bool, tailscale: Bool, t3: Bool, why: String) -> String? {
        var reasons: [String] = []
        if tailscale { reasons.append("Tailscale needs it to install") }
        if t3 { reasons.append("T3 Code needs it to stay on after you log out") }
        let text = reasons.isEmpty ? "Relaybar needs it to \(why)." : reasons.joined(separator: ", and ") + "."
        let field = NSSecureTextField(string: "")
        field.placeholderString = "Password for \(host)"
        let stack = column([field])
        fit(stack)
        let alert = NSAlert()
        alert.messageText = "Type the password for \(host)"
        alert.informativeText = wrong ? "That password did not work. Type it again." : text + " Relaybar does not keep it."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard run(alert) == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }

    static func addedComputer(host: String, client: PoolLinuxClient, options: PoolAddOptions) {
        let alert = NSAlert()
        alert.messageText = "\(host) can use your accounts"
        var paragraphs: [String] = []
        let linked = options.t3Channel != nil
        if linked {
            let reach = client.t3Host != nil ? "at home and away" : "while you are at home"
            paragraphs.append("Its chats show in T3 Code under \(host), \(reach). T3 Code asks you to confirm it once.")
        } else if client.t3Entries {
            paragraphs.append("T3 Code there now shows Claude, all accounts.")
        }
        paragraphs.append("In a terminal there, run claude-all or codex-all.")
        if options.tailscale, linked, client.t3Host == nil {
            paragraphs.append(
                "T3 Code there listens on your home network, not on Tailscale, because this Mac could not reach \(host) through Tailscale. Use the same Tailscale account on both computers, then add it again."
            )
        }
        if client.t3Installed {
            paragraphs.append(
                "To clear \(host) from T3 Code on this Mac later, use Settings, Connections, Remove from this device."
            )
        }
        alert.informativeText = paragraphs.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        _ = run(alert)
    }

    private static func password(title: String, wrong: Bool, host: String, accept: String, skip: String, text: String) -> String? {
        let field = NSSecureTextField(string: "")
        field.placeholderString = "Password for \(host)"
        let stack = column([field])
        fit(stack)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText =
            wrong ? "That password did not work. Try again, or \(skip == "Skip" ? "skip this step" : "cancel")." : text
        alert.accessoryView = stack
        alert.addButton(withTitle: accept)
        alert.addButton(withTitle: skip)
        alert.window.initialFirstResponder = field
        guard run(alert) == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }

    private static func badged(_ icon: NSImage, symbol: String, color: NSColor) -> NSImage {
        let size = NSSize(width: 64, height: 64)
        return NSImage(size: size, flipped: false) { rect in
            icon.draw(in: rect)
            let badge = NSRect(x: 36, y: 0, width: 28, height: 28)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: badge.insetBy(dx: 3, dy: 3)).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular).applying(.init(paletteColors: [.white, color]))
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)?.draw(in: badge)
            return true
        }
    }
}

@MainActor
final class TailscaleBox: NSObject {
    let view: NSView
    private let action: () -> Void

    init(host: String, action: @escaping () -> Void) {
        self.action = action
        let title = NSTextField(labelWithString: "Use it away from home too?")
        title.font = .systemFont(ofSize: 13, weight: .bold)
        let body = PoolDialogs.label(
            "Relaybar sets up Tailscale on this Mac and on \(host). You type your Mac password, click Allow once and sign in once.",
            size: 12, color: .labelColor, width: 280)
        let button = NSButton(title: "Set Up Tailscale…", target: nil, action: nil)
        let inner = NSStackView(views: [title, body, button])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 6
        inner.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.titlePosition = .noTitle
        box.contentView = inner
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 300),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
        ])
        box.layoutSubtreeIfNeeded()
        box.frame = NSRect(origin: .zero, size: box.fittingSize)
        view = box
        super.init()
        button.target = self
        button.action = #selector(pressed)
    }

    @objc private func pressed() { action() }
}

@MainActor
final class CombineDialog: NSObject {
    enum Choice: Equatable {
        case thisMac
        case computer(String)
        case another
    }

    struct Services {
        let discover: () async -> PoolChoices
        let check: (String) async throws -> PoolComputer
        let setUp: (String) -> Void
    }

    private let services: Services
    private let alert = NSAlert()
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let accept = NSButton(checkboxWithTitle: "I accept the risk and these rules.", target: nil, action: nil)
    private let note = PoolDialogs.label("")
    private var combine: NSButton?
    private var previous = 0
    private var userChose = false
    private var finished = false
    private var checking = false

    init(services: Services) {
        self.services = services
    }

    func run() -> Choice? {
        alert.messageText = "Combine your accounts?"
        alert.informativeText = "T3 Code will use whichever account has room. When one runs out, the next one takes over."
        combine = alert.addButton(withTitle: "Combine")
        alert.addButton(withTitle: "Cancel")
        combine?.isEnabled = false
        add("This Mac", .thisMac)
        popup.menu?.addItem(.separator())
        add("Another computer…", .another)
        popup.target = self
        popup.action = #selector(picked)
        accept.target = self
        accept.action = #selector(toggled)
        let runs = NSTextField(labelWithString: "Runs on")
        runs.textColor = .secondaryLabelColor
        let row = NSStackView(views: [runs, popup])
        row.spacing = 8
        row.distribution = .fill
        runs.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        popup.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = PoolDialogs.column([row, riskBox(), accept, note])
        note.isHidden = true
        PoolDialogs.fit(stack)
        alert.accessoryView = stack
        Task { await discover() }
        NSApp.activate()
        let response = alert.runModal()
        finished = true
        guard response == .alertFirstButtonReturn else { return nil }
        return choice(at: popup.indexOfSelectedItem)
    }

    private func add(_ title: String, _ choice: Choice, at index: Int? = nil) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = Box(choice)
        if let index { popup.menu?.insertItem(item, at: index) } else { popup.menu?.addItem(item) }
    }

    private func choice(at index: Int) -> Choice? {
        (popup.item(at: index)?.representedObject as? Box)?.choice
    }

    private func riskBox() -> NSView {
        let title = NSTextField(labelWithString: "Your accounts could be banned.")
        title.font = .systemFont(ofSize: 11, weight: .bold)
        title.textColor = .systemRed
        let body = PoolDialogs.label(
            "Use your plans only for your own work. Use Claude plans only in Claude Code.", size: 11, color: .labelColor, width: 280)
        let inner = NSStackView(views: [title, body])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 2
        inner.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let box = RiskBox()
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        return box
    }

    private final class RiskBox: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.borderWidth = 1
        }

        required init?(coder: NSCoder) { nil }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.12).cgColor
            layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.34).cgColor
        }
    }

    private func refreshButton() {
        combine?.isEnabled = accept.state == .on && !checking
        popup.isEnabled = !checking
    }

    private func say(_ text: String?, color: NSColor = .secondaryLabelColor) {
        note.isHidden = text == nil
        note.stringValue = text ?? ""
        note.textColor = color
        if let stack = alert.accessoryView as? NSStackView {
            PoolDialogs.fit(stack)
            alert.layout()
        }
    }

    @objc private func toggled() {
        refreshButton()
    }

    @objc private func picked() {
        guard let selected = choice(at: popup.indexOfSelectedItem) else { return }
        if selected == .another {
            popup.selectItem(at: previous)
            Task { await askAddress(text: "", error: nil) }
        } else {
            previous = popup.indexOfSelectedItem
            userChose = true
        }
    }

    private func askAddress(text: String, error: String?) async {
        guard let typed = PoolDialogs.address(text: text, error: error) else { return }
        do {
            let host = try PoolHubPicker.validate(typed)
            await verify(host)
        } catch {
            await askAddress(text: typed, error: error.localizedDescription)
        }
    }

    private func verify(_ host: String) async {
        checking = true
        refreshButton()
        say("Checking \(host)…")
        defer {
            checking = false
            refreshButton()
        }
        let verdict: PoolVerdict
        do {
            verdict = try await services.check(host).verdict
        } catch {
            say(error.localizedDescription, color: Tint.low)
            return
        }
        switch verdict {
        case .offer:
            say(nil)
            insert(host, select: true)
        case .hidden(let message):
            say(nil)
            let services = services
            if PoolDialogs.failure(host: host, message: message, setUp: { services.setUp(host) }) == .again { await verify(host) }
        }
    }

    private func insert(_ host: String, select: Bool) {
        if let existing = popup.menu?.items.firstIndex(where: { (($0.representedObject as? Box)?.choice) == .computer(host) }) {
            if select { choose(existing) }
            return
        }
        add("\(host) (at home, always on)", .computer(host), at: 0)
        if select { choose(0) } else if previous >= 0 { previous += 1 }
    }

    private func choose(_ index: Int) {
        popup.selectItem(at: index)
        previous = index
    }

    private func discover() async {
        let found = await services.discover()
        guard !finished else { return }
        if found.macLooksLikeCloud {
            while popup.numberOfItems > 1, popup.lastItem.flatMap({ ($0.representedObject as? Box)?.choice }) != .thisMac {
                popup.removeItem(at: popup.numberOfItems - 1)
            }
            say("This Mac looks like a cloud server or a VPN, so only This Mac is offered.")
            return
        }
        for computer in found.offered.reversed() {
            insert(computer.name, select: !userChose)
        }
    }

    private final class Box: NSObject {
        let choice: Choice

        init(_ choice: Choice) {
            self.choice = choice
        }
    }
}
