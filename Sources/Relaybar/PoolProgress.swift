import AppKit

enum SignInState: Equatable {
    case next
    case waiting
    case done
    case problem(String)
}

struct SignInEntry {
    let name: String
    let logo: NSImage
    let color: NSColor
}

@MainActor
final class SignInRow: NSStackView {
    private let status = NSTextField(labelWithString: "Next")
    private let spinner = NSProgressIndicator()
    private let check = NSImageView()

    init(_ entry: SignInEntry) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let logo = NSImageView(image: Render.tint(entry.logo, entry.color))
        logo.widthAnchor.constraint(equalToConstant: 14).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let name = NSTextField(labelWithString: entry.name)
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
        status.textColor = .tertiaryLabelColor
        status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [logo, name, spacer, spinner, check, status] { addArrangedSubview(view) }
    }

    required init?(coder: NSCoder) { nil }

    func set(_ state: SignInState) {
        spinner.stopAnimation(nil)
        check.isHidden = true
        switch state {
        case .next:
            status.stringValue = "Next"
            status.textColor = .tertiaryLabelColor
        case .waiting:
            status.stringValue = "Waiting for the browser"
            status.textColor = .labelColor
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
final class PoolProgressPanel: NSObject {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 440, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    private let heading = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let list = NSStackView()
    private let box = NSBox()
    private let stop = NSButton(title: "Stop and undo", target: nil, action: nil)
    private let skip = NSButton(title: "Skip this account", target: nil, action: nil)
    private let content = NSStackView()
    private var rows: [SignInRow] = []
    var onStop: () -> Void = {}
    var onSkip: () -> Void = {}

    override init() {
        super.init()
        panel.level = .floating
        panel.title = "Combine accounts"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 400
        spinner.style = .spinning
        spinner.controlSize = .small
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentView = list
        stop.target = self
        stop.action = #selector(stopPressed)
        skip.target = self
        skip.action = #selector(skipPressed)
        let buttons = NSStackView(views: [skip, stop])
        buttons.spacing = 8
        let line = NSStackView(views: [spinner, note])
        line.spacing = 8
        line.alignment = .centerY
        buttons.setHuggingPriority(.defaultHigh, for: .horizontal)
        let footer = NSStackView(views: [NSView(), buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [heading, line, box, footer] { content.addArrangedSubview(view) }
        box.widthAnchor.constraint(equalToConstant: 400).isActive = true
        footer.widthAnchor.constraint(equalToConstant: 400).isActive = true
        panel.contentView = content
        box.isHidden = true
        footer.isHidden = true
        self.footer = footer
        self.line = line
    }

    private var footer: NSView?
    private var line: NSView?

    func showSetup(title: String, message: String) {
        heading.stringValue = title
        note.stringValue = message
        spinner.isHidden = false
        spinner.startAnimation(nil)
        line?.isHidden = false
        box.isHidden = true
        footer?.isHidden = true
        present()
    }

    func update(message: String) {
        note.stringValue = message
    }

    func showSignIn(_ entries: [SignInEntry]) {
        heading.stringValue = "Sign in to each account"
        note.stringValue = "Your normal logins stay as they are."
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        rows = entries.map(SignInRow.init)
        for view in list.arrangedSubviews { view.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            row.set(.next)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 398).isActive = true
            if index < rows.count - 1 {
                let rule = NSBox()
                rule.boxType = .separator
                list.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalToConstant: 398).isActive = true
            }
        }
        box.isHidden = rows.isEmpty
        footer?.isHidden = false
        skip.isEnabled = false
        present()
    }

    func set(_ index: Int, _ state: SignInState) {
        guard rows.indices.contains(index) else { return }
        rows[index].set(state)
        skip.isEnabled = state == .waiting
    }

    func close() {
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
    }

    private func present() {
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 440, height: content.fittingSize.height))
        if !panel.isVisible { panel.center() }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func stopPressed() { onStop() }

    @objc private func skipPressed() { onSkip() }
}
