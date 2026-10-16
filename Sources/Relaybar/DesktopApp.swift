import AppKit
import RelaybarCore

enum DesktopApp {
    static var logos: [String: NSImage] = [:]

    struct Kind {
        let tool: String
        let source: String
        let variable: String

        static let claude = Kind(tool: "Claude", source: "/Applications/Claude.app", variable: "CLAUDE_CONFIG_DIR")
        static let codex = Kind(tool: "Codex", source: "/Applications/ChatGPT.app", variable: "CODEX_HOME")
    }

    static func make(_ kind: Kind, name: String, configDir: String, tag: String, color: NSColor) throws -> String {
        let manager = FileManager.default
        let support = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").path
        let runtimeDir = support + "/\(name)-\(kind.tool)-Runtime"
        let runtime = runtimeDir + "/\(kind.tool) \(name).app"
        let launcher = "/Applications/\(kind.tool) \(name).app"
        let dataDir = support + "/\(kind.tool)-" + name.replacingOccurrences(of: " ", with: "-")
        guard let executable = Bundle(path: kind.source)?.executableURL?.lastPathComponent else {
            throw failure("\(kind.source) was not found.")
        }
        guard !manager.fileExists(atPath: launcher), !manager.fileExists(atPath: runtimeDir) else {
            throw failure("\(launcher) already exists. It was left as it is.")
        }

        try manager.createDirectory(atPath: runtimeDir, withIntermediateDirectories: true)
        let clone = Process()
        clone.executableURL = URL(fileURLWithPath: "/bin/cp")
        clone.arguments = ["-cR", kind.source, runtime]
        try clone.run()
        clone.waitUntilExit()
        guard clone.terminationStatus == 0 else { throw failure("Could not copy \(kind.source).") }

        try manager.createDirectory(atPath: launcher + "/Contents/MacOS", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: launcher + "/Contents/Resources", withIntermediateDirectories: true)
        let script = """
            #!/bin/bash
            export \(kind.variable)=\(quote(configDir))
            exec \(quote(runtime + "/Contents/MacOS/" + executable)) --user-data-dir=\(quote(dataDir))

            """
        try script.write(toFile: launcher + "/Contents/MacOS/launch", atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher + "/Contents/MacOS/launch")
        let slug = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        let plist: [String: Any] = [
            "CFBundleDisplayName": "\(kind.tool) \(name)", "CFBundleName": "\(kind.tool) \(name)",
            "CFBundleExecutable": "launch", "CFBundleIdentifier": "com.afenso.\(kind.tool.lowercased())-launcher.\(slug)",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleIconFile": "AppIcon", "LSUIElement": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: launcher + "/Contents/Info.plist"))
        try applyIcon(tool: kind.tool, launcher: launcher, runtime: runtime, tag: tag, color: color)
        return launcher
    }

    static func updateIcon(configDir: String, tag: String, color: NSColor) {
        guard let found = find(configDir: configDir), let runtime = found.runtime else { return }
        let tool = found.isCodex ? Kind.codex.tool : Kind.claude.tool
        try? applyIcon(tool: tool, launcher: found.app, runtime: runtime, tag: tag, color: color)
    }

    static func exists(configDir: String) -> Bool {
        find(configDir: configDir) != nil
    }

    static func launcher(configDir: String) -> String? {
        find(configDir: configDir)?.app
    }

    static func targets(configDir: String) -> [String] {
        find(configDir: configDir)?.targets ?? []
    }

    private static func find(configDir: String) -> Launcher? {
        Launcher.find(configDir: configDir, in: URL(fileURLWithPath: "/Applications"))
    }

    private static func applyIcon(tool: String, launcher: String, runtime: String, tag: String, color: NSColor) throws {
        guard let logo = logos[tool] else { throw failure("The \(tool) logo is missing.") }
        let image = icon(logo: logo, tag: tag, color: color)
        try writeIcns(image, to: launcher + "/Contents/Resources/AppIcon.icns")
        NSWorkspace.shared.setIcon(image, forFile: runtime, options: [])
        NSWorkspace.shared.setIcon(image, forFile: launcher, options: [])
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: launcher)
        LSRegisterURL(URL(fileURLWithPath: launcher) as CFURL, true)
        NSWorkspace.shared.noteFileSystemChanged(launcher)
    }

    static func icon(logo: NSImage, tag: String, color: NSColor) -> NSImage {
        let fill = color.usingColorSpace(.sRGB) ?? .systemGray
        return NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
            let unit = tile.width
            NSBezierPath(roundedRect: tile, xRadius: unit * 0.225, yRadius: unit * 0.225).addClip()
            let top = fill.blended(withFraction: 0.18, of: .white) ?? fill
            let bottom = fill.blended(withFraction: 0.14, of: .black) ?? fill
            NSGradient(starting: top, ending: bottom)?.draw(in: tile, angle: -90)
            Render.tint(logo, .white).draw(in: tile.insetBy(dx: unit * 0.21, dy: unit * 0.21))
            guard !tag.isEmpty else { return true }
            let size = unit * 0.16
            let font =
                NSFont.systemFont(ofSize: size, weight: .heavy).fontDescriptor.withDesign(.rounded)
                .flatMap { NSFont(descriptor: $0, size: size) } ?? NSFont.systemFont(ofSize: size, weight: .heavy)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: bottom]
            let text = (tag as NSString).size(withAttributes: attributes)
            let height = unit * 0.23
            let pill = NSRect(
                x: tile.minX + unit * 0.09, y: tile.minY + unit * 0.09, width: max(height, text.width + unit * 0.1), height: height)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: pill, xRadius: height / 2, yRadius: height / 2).fill()
            (tag as NSString).draw(at: NSPoint(x: pill.midX - text.width / 2, y: pill.midY - text.height / 2), withAttributes: attributes)
            return true
        }
    }

    private static func writeIcns(_ image: NSImage, to path: String) throws {
        let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("relaybar-\(UUID().uuidString).iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: iconset) }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
                try png(image, pixels: size * scale).write(to: iconset.appendingPathComponent(name))
            }
        }
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        tool.arguments = ["-c", "icns", iconset.path, "-o", path]
        try tool.run()
        tool.waitUntilExit()
        guard tool.terminationStatus == 0 else { throw failure("Could not make the app icon.") }
    }

    private static func png(_ image: NSImage, pixels: Int) throws -> Data {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { throw failure("Could not draw the app icon.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw failure("Could not save the app icon.") }
        return data
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Relaybar", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
