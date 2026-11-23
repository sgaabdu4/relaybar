import AppKit

@MainActor
final class Toast {
    enum Mark {
        case on
        case paused
        case saved
    }

    struct Choice {
        let title: String
        let run: () -> Void
    }

    private var panel: NSPanel?
    private var hiding: Task<Void, Never>?

    func show(
        _ title: String, _ detail: String, mark: Mark?, under button: NSStatusBarButton?, primary: Choice? = nil, secondary: Choice? = nil,
        closesAfter seconds: Double? = 2
    ) {
        hiding?.cancel()
        panel?.orderOut(nil)
        let background = content(title, detail, mark: mark, primary: primary, secondary: secondary) { [weak self] in self?.hide() }
        let size = background.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = primary == nil && secondary == nil
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.contentView = background
        if let icon = button?.window?.frame, let screen = button?.window?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let x = min(max(icon.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
            panel.setFrameOrigin(NSPoint(x: x, y: icon.minY - 8 - size.height))
        } else if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - size.width - 16, y: screen.visibleFrame.maxY - 8 - size.height))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.15
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        guard let seconds else { return }
        hiding = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        hiding?.cancel()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup(
            {
                $0.duration = 0.3
                panel.animator().alphaValue = 0
            },
            completionHandler: {
                Task { @MainActor in
                    panel.orderOut(nil)
                    if self.panel === panel { self.panel = nil }
                }
            })
    }

    func content(
        _ title: String, _ detail: String, mark: Mark?, primary: Choice?, secondary: Choice?, hide: @escaping () -> Void
    ) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.font = .systemFont(ofSize: 11.5)
        detailField.textColor = .secondaryLabelColor
        let fit = (detail as NSString).boundingRect(
            with: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude), options: .usesLineFragmentOrigin,
            attributes: [.font: detailField.font as Any])
        detailField.preferredMaxLayoutWidth = ceil(fit.width)
        detailField.widthAnchor.constraint(equalToConstant: ceil(fit.width)).isActive = true
        detailField.heightAnchor.constraint(equalToConstant: ceil(fit.height)).isActive = true
        var views: [NSView] = [titleField, detailField]
        if primary != nil || secondary != nil {
            let quiet = secondary.map { button($0, filled: false, hide: hide) }
            let filled = primary.map { button($0, filled: true, hide: hide) }
            let buttons = NSStackView(views: [quiet, filled].compactMap { $0 })
            buttons.spacing = 8
            views.append(buttons)
        }
        let text = NSStackView(views: views)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        if views.count == 3 { text.setCustomSpacing(8, after: detailField) }
        let row = NSStackView(views: (mark.map { [Self.image($0)] } ?? []) + [text])
        row.spacing = 9
        row.alignment = views.count == 3 ? .top : .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: background.topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -9),
        ])
        background.layoutSubtreeIfNeeded()
        return background
    }

    private func button(_ choice: Choice, filled: Bool, hide: @escaping () -> Void) -> NSButton {
        ToastButton(title: choice.title, filled: filled) {
            choice.run()
            hide()
        }
    }

    private static func image(_ mark: Mark) -> NSImageView {
        let (name, size, color): (String, CGFloat, NSColor) =
            switch mark {
            case .on: ("circle.fill", 8, PoolStatus.color)
            case .paused: ("circle", 8, .tertiaryLabelColor)
            case .saved: ("checkmark", 12, PoolStatus.color)
            }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        let view = NSImageView(
            image: NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage())
        view.contentTintColor = color
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }
}

@MainActor
final class ToastButton: NSButton {
    private let run: () -> Void
    private let filled: Bool

    init(title: String, filled: Bool, run: @escaping () -> Void) {
        self.run = run
        self.filled = filled
        super.init(frame: .zero)
        target = self
        action = #selector(pressed)
        if filled {
            isBordered = false
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.backgroundColor = Theme.primaryButtonFill.cgColor
            attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: Theme.primaryButtonText])
            heightAnchor.constraint(equalToConstant: 22).isActive = true
        } else {
            isBordered = false
            attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var alignmentRectInsets: NSEdgeInsets {
        filled ? NSEdgeInsets() : NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 0)
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return filled ? NSSize(width: size.width + 20, height: size.height) : size
    }

    override func viewDidChangeEffectiveAppearance() {
        if filled { effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Theme.primaryButtonFill.cgColor } }
    }

    @objc private func pressed() { run() }
}
