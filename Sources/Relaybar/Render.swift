import AppKit

enum Tint: String, CaseIterable {
    case orange, blue, green, purple, pink, teal, yellow, red, plain

    static let palette: [Tint] = [.orange, .blue, .green, .purple, .pink, .teal, .yellow]

    var color: NSColor {
        switch self {
        case .orange: .systemOrange
        case .blue: .systemBlue
        case .green: .systemGreen
        case .purple: .systemPurple
        case .pink: .systemPink
        case .teal: .systemTeal
        case .yellow: .systemYellow
        case .red: .systemRed
        case .plain: .labelColor
        }
    }

    static let low = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.55, blue: 0.55, alpha: 1)
            : NSColor(srgbRed: 0.88, green: 0.3, blue: 0.3, alpha: 1)
    }

    func color(for window: Window) -> NSColor {
        window.left <= 10 ? Tint.low : color
    }

    var title: String { self == .plain ? "No color" : rawValue.capitalized }
}

enum Render {
    private static let height: CGFloat = 22
    private static let iconSize: CGFloat = 15
    private static let gap: CGFloat = 2.5
    private static let stackedFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let singleFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
    private static let tagFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 6, weight: .bold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 6) } ?? base
    }()

    static func image(logo: NSImage, color: NSColor, tag: String, lines: [(text: String, color: NSColor)]) -> NSImage {
        let font = lines.count > 1 ? stackedFont : singleFont
        let tinted = tint(logo, color)
        let sizes = lines.map { ($0.text as NSString).size(withAttributes: [.font: font]) }
        let textWidth = ceil(sizes.map(\.width).max() ?? 0)
        let inset: CGFloat = tag.isEmpty ? 0 : 1.5
        let size = NSSize(width: inset + iconSize + (lines.isEmpty ? 0 : gap) + textWidth, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            let iconRect = NSRect(x: inset, y: (height - iconSize) / 2 + (tag.isEmpty ? 0 : 1), width: iconSize, height: iconSize)
            tinted.draw(in: iconRect)
            if !tag.isEmpty { drawTag(tag, color: color, at: NSPoint(x: 0, y: iconRect.minY - 2)) }
            let x = iconRect.maxX + gap
            for (index, line) in lines.enumerated() {
                let lineSize = sizes[index]
                let y: CGFloat
                if lines.count == 1 {
                    y = (height - lineSize.height) / 2
                } else {
                    y = index == 0 ? height / 2 - 1.5 : height / 2 - lineSize.height + 1.5
                }
                (line.text as NSString).draw(at: NSPoint(x: x + textWidth - lineSize.width, y: y),
                                             withAttributes: [.font: font, .foregroundColor: line.color])
            }
            return true
        }
        return image
    }

    static func row(_ parts: [NSImage]) -> NSImage {
        let spacing: CGFloat = 7
        let width = parts.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(0, parts.count - 1))
        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for part in parts {
                part.draw(in: NSRect(x: x, y: 0, width: part.size.width, height: height))
                x += part.size.width + spacing
            }
            return true
        }
        return image
    }

    static func tint(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceIn)
            return true
        }
    }

    private static func drawTag(_ tag: String, color: NSColor, at origin: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: tagFont, .foregroundColor: NSColor.black]
        let width = (tag as NSString).size(withAttributes: attributes).width
        let box = NSRect(x: origin.x, y: origin.y, width: ceil(width) + 3, height: ceil(tagFont.capHeight) + 3)
        let text = NSPoint(x: box.minX + (box.width - width) / 2, y: box.minY + (box.height - tagFont.capHeight) / 2 + tagFont.descender)
        let context = NSGraphicsContext.current
        context?.compositingOperation = .clear
        NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: -1), xRadius: box.height / 2 + 1, yRadius: box.height / 2 + 1).fill()
        context?.compositingOperation = .sourceOver
        color.set()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        context?.compositingOperation = .destinationOut
        (tag as NSString).draw(at: text, withAttributes: attributes)
        context?.compositingOperation = .sourceOver
    }
}
