import AppKit
import RelaybarCore

@MainActor
final class AddComputerDialog: NSObject {
    struct Choice {
        let host: String
        let t3: Bool
        let tailscale: Bool
    }

    private static let another = 1

    private let alert = NSAlert()
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let t3Box = NSButton(checkboxWithTitle: "Show its chats in T3 Code on this Mac", target: nil, action: nil)
    private let tailscaleBox = NSButton(checkboxWithTitle: "Use it away from home", target: nil, action: nil)
    private let offerT3: Bool
    private let offerTailscale: Bool
    private var add: NSButton?
    private var previous = 0

    init(hosts: [String], t3: Bool, tailscale: Bool) {
        offerT3 = t3
        offerTailscale = tailscale
        super.init()
        popup.autoenablesItems = false
        if hosts.isEmpty {
            let none = NSMenuItem(title: "Choose a computer", action: nil, keyEquivalent: "")
            none.isEnabled = false
            popup.menu?.addItem(none)
        }
        for host in hosts { popup.addItem(withTitle: host) }
        for item in popup.itemArray where item.isEnabled { item.representedObject = item.title }
        if !hosts.isEmpty { popup.menu?.addItem(.separator()) }
        let other = NSMenuItem(title: "Another computer…", action: nil, keyEquivalent: "")
        other.tag = Self.another
        popup.menu?.addItem(other)
        popup.target = self
        popup.action = #selector(picked)
    }

    func run() -> Choice? {
        alert.messageText = "Add a computer"
        alert.informativeText =
            "Relaybar sets it up to use all your accounts. It must be a Linux computer that this Mac can reach with SSH."
        add = alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let label = NSTextField(labelWithString: "Computer")
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, popup])
        row.spacing = 8
        row.distribution = .fill
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        popup.setContentHuggingPriority(.init(1), for: .horizontal)
        var views: [NSView] = [row]
        if offerT3 {
            views.append(option(t3Box, "Installs T3 Code there and links it to this Mac."))
        }
        if offerTailscale {
            views.append(option(tailscaleBox, "Installs Tailscale there. You sign in once."))
        }
        views.append(
            PoolDialogs.label(
                "Relaybar also installs Claude Code and Codex there if they are missing. No sign-in is needed.", size: 11,
                color: .secondaryLabelColor, width: 300))
        let stack = PoolDialogs.column(views, spacing: 14)
        PoolDialogs.fit(stack)
        alert.accessoryView = stack
        refresh()
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn, let host = popup.selectedItem?.representedObject as? String else { return nil }
        return Choice(host: host, t3: offerT3 && t3Box.state == .on, tailscale: offerTailscale && tailscaleBox.state == .on)
    }

    private func option(_ box: NSButton, _ detail: String) -> NSView {
        box.state = .on
        box.font = .systemFont(ofSize: 13)
        let subtitle = PoolDialogs.label(detail, size: 11, color: .secondaryLabelColor, width: 282)
        let indented = NSStackView(views: [subtitle])
        indented.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
        let stack = NSStackView(views: [box, indented])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func refresh() {
        add?.isEnabled = popup.selectedItem?.representedObject is String
    }

    @objc private func picked() {
        if popup.selectedItem?.tag == Self.another {
            popup.selectItem(at: previous)
            Task { askAddress(text: "", error: nil) }
        } else {
            previous = popup.indexOfSelectedItem
        }
        refresh()
    }

    private func askAddress(text: String, error: String?) {
        guard
            let typed = PoolDialogs.address(
                text: text, error: error, title: "Which computer should use your accounts?",
                message: "It must be a Linux computer that this Mac can reach with SSH.", accept: "Use this computer")
        else { return }
        do {
            insert(try PoolHubPicker.validate(typed))
        } catch {
            askAddress(text: typed, error: error.localizedDescription)
        }
    }

    private func insert(_ host: String) {
        if let index = popup.itemArray.firstIndex(where: { $0.representedObject as? String == host }) {
            popup.selectItem(at: index)
        } else {
            if let first = popup.item(at: 0), !first.isEnabled { popup.removeItem(at: 0) }
            let item = NSMenuItem(title: host, action: nil, keyEquivalent: "")
            item.representedObject = host
            popup.menu?.insertItem(item, at: 0)
            if popup.numberOfItems == 2 { popup.menu?.insertItem(.separator(), at: 1) }
            popup.selectItem(at: 0)
        }
        previous = popup.indexOfSelectedItem
        refresh()
    }
}
