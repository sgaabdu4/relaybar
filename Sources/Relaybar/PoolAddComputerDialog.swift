import AppKit
import RelaybarCore

@MainActor
final class AddComputerDialog: NSObject {
    private static let another = 1

    private let alert = NSAlert()
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var add: NSButton?
    private var previous = 0

    init(hosts: [String]) {
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

    func run() -> String? {
        alert.messageText = "Add a computer"
        alert.informativeText =
            "Relaybar sets it up to use all your accounts in its terminal and in T3 Code. It must be a Linux computer that this Mac can reach with SSH."
        add = alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let label = NSTextField(labelWithString: "Computer")
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, popup])
        row.spacing = 8
        row.distribution = .fill
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        popup.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = PoolDialogs.column([row])
        PoolDialogs.fit(stack)
        alert.accessoryView = stack
        refresh()
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return popup.selectedItem?.representedObject as? String
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
