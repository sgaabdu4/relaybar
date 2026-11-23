import AppKit

enum Theme {
    static let iconPillFill: NSColor = .white
    static let tagCutoutMask: NSColor = .black
    static let primaryButtonText: NSColor = .white
    static let primaryButtonFill: NSColor = NSColor.controlAccentColor.blended(withFraction: 0.25, of: .black) ?? .controlAccentColor
}
