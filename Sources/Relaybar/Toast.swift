import AppKit

@MainActor
final class Toast {
    enum Mark {
        case on
        case paused
        case saved
    }

    private var panel: NSPanel?
    private var hiding: Task<Void, Never>?

    func show(_ title: String, _ detail: String, mark: Mark, under button: NSStatusBarButton?) {
        hiding?.cancel()
        panel?.orderOut(nil)
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        let detailField = NSTextField(labelWithString: detail)
        detailField.font = .systemFont(ofSize: 11.5)
        detailField.textColor = .secondaryLabelColor
        let text = NSStackView(views: [titleField, detailField])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [Self.image(mark), text])
        row.spacing = 9
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 14)
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
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        let size = row.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
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
        hiding = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({
                $0.duration = 0.3
                panel.animator().alphaValue = 0
            }) {
                Task { @MainActor in
                    panel.orderOut(nil)
                    if self?.panel === panel { self?.panel = nil }
                }
            }
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
