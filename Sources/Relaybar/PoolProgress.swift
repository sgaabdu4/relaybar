import AppKit

enum SignInState: Equatable {
    case ready
    case waiting
    case done
    case problem(String)
}

enum SignInAction {
    case signIn
    case openAgain
    case cancel
}

struct SignInEntry {
    let name: String
    let email: String
    let logo: NSImage
    let color: NSColor
}

@MainActor
final class SignInRow: NSStackView {
    private let problem = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let waitingText = NSTextField(labelWithString: "Waiting for you in the browser")
    private let waitLine = NSStackView()
    private let buttons = NSStackView()
    private let signIn = NSButton(title: "Sign In", target: nil, action: nil)
    private let openAgain = NSButton(title: "Open Again", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let done = NSStackView()
    private let waiting = NSStackView()
    var onAction: (SignInAction) -> Void = { _ in }

    init(_ entry: SignInEntry) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 10
        edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let logo = NSImageView(image: Render.tint(entry.logo, entry.color))
        logo.widthAnchor.constraint(equalToConstant: 14).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let name = NSTextField(labelWithString: entry.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        let email = NSTextField(labelWithString: entry.email)
        email.font = .systemFont(ofSize: 11)
        email.textColor = .secondaryLabelColor
        email.lineBreakMode = .byTruncatingMiddle
        problem.font = .systemFont(ofSize: 11)
        problem.textColor = .systemRed
        problem.preferredMaxLayoutWidth = 280
        let info = NSStackView(views: [name, email, problem])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 2
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        waitingText.font = .systemFont(ofSize: 12)
        waitLine.setViews([spinner, waitingText], in: .leading)
        waitLine.spacing = 6
        for button in [signIn, openAgain, cancel] {
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.target = self
        }
        signIn.action = #selector(signInPressed)
        openAgain.action = #selector(openAgainPressed)
        cancel.action = #selector(cancelPressed)
        buttons.setViews([openAgain, cancel], in: .leading)
        buttons.spacing = 6
        waiting.setViews([waitLine, buttons], in: .leading)
        waiting.orientation = .vertical
        waiting.alignment = .trailing
        waiting.spacing = 6
        let tick = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done") ?? NSImage())
        tick.contentTintColor = .systemGreen
        let doneText = NSTextField(labelWithString: "Done")
        doneText.font = .systemFont(ofSize: 13)
        doneText.textColor = .systemGreen
        done.setViews([tick, doneText], in: .leading)
        done.spacing = 4
        for view in [logo, info, spacer, waiting, signIn, done] { addArrangedSubview(view) }
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ state: SignInState, locked: Bool) {
        spinner.stopAnimation(nil)
        problem.isHidden = true
        waiting.isHidden = true
        signIn.isHidden = true
        done.isHidden = true
        signIn.title = "Sign In"
        signIn.isEnabled = !locked
        switch state {
        case .ready:
            signIn.isHidden = false
        case .waiting:
            waiting.isHidden = false
            spinner.startAnimation(nil)
        case .done:
            done.isHidden = false
        case .problem(let text):
            problem.stringValue = text
            problem.isHidden = false
            signIn.title = "Try Again"
            signIn.isHidden = false
        }
    }

    @objc private func signInPressed() { onAction(.signIn) }

    @objc private func openAgainPressed() { onAction(.openAgain) }

    @objc private func cancelPressed() { onAction(.cancel) }
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
    private let add = NSButton(title: "Add an account…", target: nil, action: nil)
    private let done = NSButton(title: "Done", target: nil, action: nil)
    private let content = NSStackView()
    private var rows: [SignInRow] = []
    private var states: [SignInState] = []
    private static let wide: CGFloat = 560
    private static let inner: CGFloat = wide - 40
    private var width: CGFloat = 440
    var onStop: () -> Void = {}
    var onDone: () -> Void = {}
    var onAdd: () -> Void = {}
    var onAction: (Int, SignInAction) -> Void = { _, _ in }

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
        add.target = self
        add.action = #selector(addPressed)
        done.target = self
        done.action = #selector(donePressed)
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [stop, done])
        buttons.spacing = 8
        let line = NSStackView(views: [spinner, note])
        line.spacing = 8
        line.alignment = .centerY
        buttons.setHuggingPriority(.defaultHigh, for: .horizontal)
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [add, gap, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [heading, line, box, footer] { content.addArrangedSubview(view) }
        box.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        footer.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
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
        note.preferredMaxLayoutWidth = 400
        width = 440
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
        note.preferredMaxLayoutWidth = Self.inner
        width = Self.wide
        note.stringValue = "Click Sign In, then sign in to that account in the browser. Your normal logins stay as they are."
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        rows = []
        states = []
        for entry in entries { addRow(entry) }
        footer?.isHidden = false
        rebuild()
        present()
    }

    func append(_ entry: SignInEntry) {
        addRow(entry)
        rebuild()
        resize()
    }

    private func addRow(_ entry: SignInEntry) {
        let row = SignInRow(entry)
        let index = rows.count
        row.onAction = { [weak self] action in self?.onAction(index, action) }
        rows.append(row)
        states.append(.ready)
    }

    private func rebuild() {
        for view in list.arrangedSubviews { view.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: Self.inner - 2).isActive = true
            if index < rows.count - 1 {
                let rule = NSBox()
                rule.boxType = .separator
                list.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalToConstant: Self.inner - 2).isActive = true
            }
        }
        box.isHidden = rows.isEmpty
        refresh()
    }

    func set(_ index: Int, _ state: SignInState) {
        guard states.indices.contains(index) else { return }
        states[index] = state
        refresh()
        resize()
    }

    private func refresh() {
        let locked = states.contains(.waiting)
        for (row, state) in zip(rows, states) { row.apply(state, locked: locked) }
        done.isEnabled = states.contains(.done)
    }

    func close() {
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
    }

    private func resize() {
        content.layoutSubtreeIfNeeded()
        let top = panel.frame.maxY
        panel.setContentSize(NSSize(width: width, height: content.fittingSize.height))
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
    }

    private func present() {
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: width, height: content.fittingSize.height))
        if !panel.isVisible { panel.center() }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func stopPressed() { onStop() }

    @objc private func addPressed() { onAdd() }

    @objc private func donePressed() { onDone() }
}
