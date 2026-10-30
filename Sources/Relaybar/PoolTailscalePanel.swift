import AppKit
import RelaybarCore

@MainActor
final class TailscaleRow: NSStackView {
    private let status = NSTextField(labelWithString: "Next")
    private let spinner = NSProgressIndicator()
    private let check = NSImageView()
    private let name: NSTextField

    static let turn = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .systemYellow : NSColor(srgbRed: 0.62, green: 0.44, blue: 0, alpha: 1)
    }

    init(group: String, title: String) {
        name = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let place = NSTextField(labelWithString: group)
        place.font = .systemFont(ofSize: 12)
        place.textColor = .tertiaryLabelColor
        place.lineBreakMode = .byTruncatingTail
        place.widthAnchor.constraint(equalToConstant: 64).isActive = true
        name.font = .systemFont(ofSize: 13)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Done")
        check.contentTintColor = .systemGreen
        check.isHidden = true
        status.font = .systemFont(ofSize: 13)
        status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [place, name, spacer, spinner, check, status] { addArrangedSubview(view) }
        set(.next)
    }

    required init?(coder: NSCoder) { nil }

    func set(_ state: PoolStageState) {
        spinner.stopAnimation(nil)
        check.isHidden = true
        name.font = .systemFont(ofSize: 13, weight: state == .yourTurn ? .semibold : .regular)
        switch state {
        case .next:
            status.stringValue = "Next"
            status.textColor = .tertiaryLabelColor
        case .working:
            status.stringValue = "Working"
            status.textColor = .labelColor
            spinner.startAnimation(nil)
        case .yourTurn:
            status.stringValue = "Your turn"
            status.textColor = Self.turn
            spinner.startAnimation(nil)
        case .done:
            status.stringValue = "Done"
            status.textColor = .systemGreen
            check.isHidden = false
        case .problem(let text):
            status.stringValue = text
            status.textColor = .systemOrange
        }
    }
}

@MainActor
final class PoolTailscalePanel: NSObject {
    private static let titles: [(PoolTailscaleStage, String)] = [
        (.download, "Download and check Tailscale"), (.install, "Install (Mac password)"),
        (.allow, "Allow Tailscale in Settings"), (.signIn, "Sign in to Tailscale"), (.home, "Install and sign in"),
        (.connection, "Switch the connection"),
    ]

    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    private let rows: [PoolTailscaleStage: TailscaleRow]
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    var onCancel: () -> Void = {}

    init(host: String) {
        var made: [PoolTailscaleStage: TailscaleRow] = [:]
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        for (index, entry) in Self.titles.enumerated() {
            let group = entry.0 == .connection ? "Both" : (entry.0 == .home ? host : "This Mac")
            let row = TailscaleRow(group: group, title: entry.1)
            made[entry.0] = row
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 438).isActive = true
            if index < Self.titles.count - 1 {
                let rule = NSBox()
                rule.boxType = .separator
                list.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalToConstant: 438).isActive = true
            }
        }
        rows = made
        super.init()
        panel.level = .floating
        panel.title = "Combine accounts"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let heading = NSTextField(labelWithString: "Set up Tailscale")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: "Relaybar does each step. You only act where it says \"Your turn\".")
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 440
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentView = list
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        let footer = NSStackView(views: [NSView(), cancel])
        let content = NSStackView(views: [heading, note, box, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        box.widthAnchor.constraint(equalToConstant: 440).isActive = true
        footer.widthAnchor.constraint(equalToConstant: 440).isActive = true
        panel.contentView = content
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 480, height: content.fittingSize.height))
    }

    func set(_ stage: PoolTailscaleStage, _ state: PoolStageState) {
        rows[stage]?.set(state)
    }

    func show() {
        if !panel.isVisible { panel.center() }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
    }

    @objc private func cancelPressed() {
        cancel.isEnabled = false
        onCancel()
    }
}
