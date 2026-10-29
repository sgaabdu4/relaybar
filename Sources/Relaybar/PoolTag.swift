import AppKit
import RelaybarCore

enum PoolStatus {
    case inUse
    case paused
    case signedOut

    static let color: NSColor = {
        let hex = PoolSetup.combinedColor.dropFirst()
        let value = Int(hex, radix: 16) ?? 0x32ade6
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255,
            alpha: 1)
    }()
}

struct PoolTagModel {
    let text: String
    let color: NSColor
    let textColor: NSColor
    let paused: Bool
}

enum PoolTag {
    private static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 9, weight: .bold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 9) } ?? base
    }()

    static func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 10
    }

    static func draw(_ tag: PoolTagModel, in rect: NSRect) {
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        let outlined = tag.paused
        if outlined {
            tag.color.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        } else {
            tag.color.setFill()
            shape.fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: outlined ? tag.color : tag.textColor]
        let size = (tag.text as NSString).size(withAttributes: attributes)
        (tag.text as NSString).draw(
            at: NSPoint(x: rect.minX + (rect.width - size.width) / 2, y: rect.minY + (rect.height - size.height) / 2),
            withAttributes: attributes)
    }
}
