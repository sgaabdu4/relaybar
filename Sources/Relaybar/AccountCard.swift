import AppKit

final class AccountCard: NSView {
    private let account: Account
    private let logo: NSImage
    private let opens: String?
    private let open: (String) -> Void
    private static let width: CGFloat = 250
    private static let inset: CGFloat = 14
    private static let rowHeight: CGFloat = 18
    private static let nameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let smallFont = NSFont.systemFont(ofSize: 11)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    init(account: Account, logo: NSImage, opens: String?, open: @escaping (String) -> Void) {
        self.account = account
        self.logo = logo
        self.opens = opens
        self.open = open
        let rows = CGFloat(max(1, [account.session, account.weekly].compactMap { $0 }.count + (account.stale ? 1 : 0)))
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 32 + rows * Self.rowHeight))
        toolTip = opens.map { "Open " + URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
    }

    override func mouseUp(with event: NSEvent) {
        guard let opens else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        open(opens)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let inset = Self.inset
        if opens != nil, enclosingMenuItem?.isHighlighted == true {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        Render.tint(logo, account.tint.color).draw(in: NSRect(x: inset, y: 7, width: 14, height: 14), from: .zero,
                                                   operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let name = account.tag.isEmpty ? (account.isClaude ? "Claude" : "Codex") : account.tag
        draw(name, font: Self.nameFont, color: .labelColor, at: NSPoint(x: inset + 21, y: 5), maxWidth: 160)

        var y: CGFloat = 28
        for (label, window) in [("5h", account.session), ("7d", account.weekly)] {
            guard let window else { continue }
            drawRow(label, window, y: y)
            y += Self.rowHeight
        }
        if account.stale {
            draw("Login expired", font: Self.smallFont, color: .systemOrange, at: NSPoint(x: inset, y: y), maxWidth: 200)
        } else if account.session == nil && account.weekly == nil {
            draw("Waiting for \(account.isClaude ? "Claude" : "Codex")", font: Self.smallFont, color: .tertiaryLabelColor,
                 at: NSPoint(x: inset, y: y), maxWidth: 200)
        }
    }

    private func drawRow(_ label: String, _ window: Window, y: CGFloat) {
        let inset = Self.inset
        let right = bounds.width - inset
        let low = window.left <= 10
        draw(label, font: Self.smallFont, color: .secondaryLabelColor, at: NSPoint(x: inset, y: y), maxWidth: 24)

        let reset = Self.resets(window)
        let resetAttributes: [NSAttributedString.Key: Any] = [.font: Self.smallFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let resetWidth = (reset as NSString).size(withAttributes: resetAttributes).width
        (reset as NSString).draw(at: NSPoint(x: right - resetWidth, y: y), withAttributes: resetAttributes)

        let valueRight = right - 52
        let value = "\(window.left)%"
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: Self.valueFont, .foregroundColor: account.tint.color(for: window)]
        let valueWidth = (value as NSString).size(withAttributes: valueAttributes).width
        (value as NSString).draw(at: NSPoint(x: valueRight - valueWidth, y: y - 1), withAttributes: valueAttributes)

        let track = NSRect(x: inset + 24, y: y + 6, width: valueRight - 40 - inset - 24, height: 4)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        guard window.left > 0 else { return }
        let fill = NSRect(x: track.minX, y: track.minY, width: max(4, track.width * CGFloat(window.left) / 100), height: track.height)
        (low ? Tint.low : account.tint == .plain ? NSColor.secondaryLabelColor : account.tint.color).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }

    private func draw(_ text: String, font: NSFont, color: NSColor, at point: NSPoint, maxWidth: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        (text as NSString).draw(in: NSRect(x: point.x, y: point.y, width: maxWidth, height: font.boundingRectForFont.height),
                                withAttributes: attributes)
    }

    static func resets(_ window: Window) -> String {
        guard let date = window.resetsAt else { return "" }
        let seconds = date.timeIntervalSinceNow
        if seconds < 86_400 {
            let minutes = max(0, Int(seconds / 60))
            return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        }
        let format = DateFormatter()
        format.setLocalizedDateFormatFromTemplate("EEE")
        return format.string(from: date)
    }
}
