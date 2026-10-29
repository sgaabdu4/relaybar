import AppKit
import RelaybarCore

@MainActor
final class AddStepRow: NSStackView {
    private let slot = NSView()
    private let spinner = NSProgressIndicator()
    private let check = NSImageView()
    private let dot = NSTextField(labelWithString: "\u{00B7}")
    private let name: NSTextField

    init(title: String) {
        name = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 10
        edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Done")
        check.contentTintColor = .systemGreen
        dot.font = .systemFont(ofSize: 16)
        dot.textColor = .tertiaryLabelColor
        for view in [spinner, check, dot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: slot.centerXAnchor), view.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            ])
        }
        slot.widthAnchor.constraint(equalToConstant: 16).isActive = true
        slot.heightAnchor.constraint(equalToConstant: 16).isActive = true
        name.lineBreakMode = .byTruncatingTail
        addArrangedSubview(slot)
        addArrangedSubview(name)
        set(.next)
    }

    required init?(coder: NSCoder) { nil }

    func retitle(_ title: String) {
        name.stringValue = title
    }

    func set(_ state: PoolStageState) {
        spinner.stopAnimation(nil)
        check.isHidden = true
        dot.isHidden = true
        switch state {
        case .next:
            dot.isHidden = false
            name.font = .systemFont(ofSize: 13)
            name.textColor = .tertiaryLabelColor
        case .working, .yourTurn:
            spinner.startAnimation(nil)
            name.font = .systemFont(ofSize: 13, weight: .semibold)
            name.textColor = .labelColor
        case .done:
            check.isHidden = false
            name.font = .systemFont(ofSize: 13)
            name.textColor = .labelColor
        case .problem:
            dot.isHidden = false
            name.font = .systemFont(ofSize: 13)
            name.textColor = .systemOrange
        }
    }
}

@MainActor
final class PoolAddPanel: NSObject, PoolWorkPanel {
    private static let inner: CGFloat = 440

    private let host: String
    private let hub: String
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    private let list = NSStackView()
    private let steps = NSStackView()
    private let rule = NSBox()
    private let waiting = NSStackView()
    private let waitText = NSTextField(labelWithString: "Waiting for you in the browser")
    private let copy = NSButton(title: "Copy Link", target: nil, action: nil)
    private let again = NSButton(title: "Open Again", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let content = NSStackView()
    private var rows: [PoolAddStage: AddStepRow] = [:]
    private var link: URL?
    var onCancel: () -> Void = {}

    init(host: String, hub: String) {
        self.host = host
        self.hub = hub
        super.init()
        panel.level = .floating
        panel.title = "Setting up \(host)"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 0
        steps.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        rule.boxType = .separator
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentView = list
        waitText.font = .systemFont(ofSize: 12)
        waitText.textColor = .secondaryLabelColor
        for button in [copy, again, cancel] {
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.target = self
        }
        copy.action = #selector(copyPressed)
        again.action = #selector(againPressed)
        cancel.action = #selector(cancelPressed)
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        waiting.setViews([waitText, gap, copy, again, cancel], in: .leading)
        waiting.orientation = .horizontal
        waiting.alignment = .centerY
        waiting.spacing = 6
        waiting.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)
        waiting.isHidden = true
        rule.isHidden = true
        for view in [steps, rule, waiting] {
            list.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: Self.inner - 2).isActive = true
        }
        let checking = AddStepRow(title: "Checking \(host)")
        checking.set(.working)
        steps.addArrangedSubview(checking)
        checking.widthAnchor.constraint(equalToConstant: Self.inner - 2).isActive = true
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.addArrangedSubview(box)
        box.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        panel.contentView = content
    }

    private func title(_ stage: PoolAddStage) -> String {
        switch stage {
        case .letIn: "Letting \(host) in on \(hub)"
        case .tools: "Installing Claude Code and Codex"
        case .tailscale: "Installing Tailscale"
        case .route: "Finding the way to \(hub)"
        case .commands: "Setting up claude-all and codex-all"
        case .t3: "Installing T3 Code"
        case .link: "Linking T3 Code to this Mac"
        }
    }

    func plan(_ stages: [PoolAddStage]) {
        for view in steps.arrangedSubviews { view.removeFromSuperview() }
        rows = [:]
        for stage in stages {
            let row = AddStepRow(title: title(stage))
            rows[stage] = row
            steps.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: Self.inner - 2).isActive = true
        }
        resize()
    }

    func set(_ stage: PoolAddStage, _ state: PoolStageState) {
        rows[stage]?.set(state)
        if stage == .tailscale {
            rows[stage]?.retitle(state == .yourTurn ? "Sign in to Tailscale for \(host)" : title(stage))
            if state == .yourTurn { showWaiting("Waiting for you in the browser", copyable: true) } else { hideSignIn() }
        }
        if stage == .link {
            rows[stage]?.retitle(state == .yourTurn ? "Confirm in T3 Code" : title(stage))
            if state == .yourTurn { showWaiting("Waiting for you in T3 Code", copyable: false) } else { hideSignIn() }
        }
        resize()
    }

    func showSignIn(_ url: URL) {
        link = url
        showWaiting("Waiting for you in the browser", copyable: true)
        resize()
    }

    func rememberPairLink(_ url: URL) {
        link = url
    }

    private func showWaiting(_ text: String, copyable: Bool) {
        waitText.stringValue = text
        copy.isHidden = !copyable
        waiting.isHidden = false
        rule.isHidden = false
    }

    private func hideSignIn() {
        link = nil
        waiting.isHidden = true
        rule.isHidden = true
    }

    func show() {
        resize()
        if !panel.isVisible { panel.center() }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func showSetup(title: String, message: String) {
        for stage in rows.keys { rows[stage]?.set(.next) }
        cancel.isEnabled = true
        hideSignIn()
        show()
    }

    func close() {
        panel.orderOut(nil)
    }

    private func resize() {
        content.layoutSubtreeIfNeeded()
        let top = panel.frame.maxY
        panel.setContentSize(NSSize(width: 480, height: content.fittingSize.height))
        if panel.isVisible { panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top)) }
    }

    @objc private func copyPressed() {
        guard let link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
        copy.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.copy.title = "Copy Link" }
    }

    @objc private func againPressed() {
        if let link { NSWorkspace.shared.open(link) }
    }

    @objc private func cancelPressed() {
        cancel.isEnabled = false
        onCancel()
    }
}

@MainActor
protocol PoolWorkPanel: AnyObject {
    func close()
    func showSetup(title: String, message: String)
}

extension PoolProgressPanel: PoolWorkPanel {}
