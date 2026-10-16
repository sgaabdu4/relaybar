import AppKit
import RelaybarCore

enum T3Code {
    private static let settings = T3Settings(home: FileManager.default.homeDirectoryForCurrentUser)

    static var isInstalled: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return ["/Applications", home].contains { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).contains {
                $0.hasPrefix("T3 Code") && $0.hasSuffix(".app")
            }
        }
    }

    static func contains(homePath: String) -> Bool {
        settings.contains(homePath: homePath)
    }

    static func add(claude: Bool, name: String, color: NSColor, homePath: String) throws {
        guard isInstalled else { return }
        try settings.add(claude: claude, name: name, hex: hex(color), homePath: homePath)
    }

    static func remove(homePath: String) throws {
        try settings.remove(homePath: homePath)
    }

    private static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#888888" }
        return String(format: "#%02x%02x%02x", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}
