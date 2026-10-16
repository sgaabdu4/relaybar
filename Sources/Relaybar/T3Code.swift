import AppKit

enum T3Code {
    private static let settings = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".t3/userdata/settings.json")

    static var isInstalled: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return ["/Applications", home].contains { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).contains { $0.hasPrefix("T3 Code") && $0.hasSuffix(".app") }
        }
    }

    static func contains(homePath: String) -> Bool {
        instances(in: read()).contains { home(of: $0.value) == homePath }
    }

    static func add(claude: Bool, name: String, color: NSColor, homePath: String) throws {
        guard isInstalled else { return }
        var root = read()
        var instances = instances(in: root)
        if let existing = instances.first(where: { home(of: $0.value) == homePath }) {
            var entry = existing.value as? [String: Any] ?? [:]
            guard entry["enabled"] as? Bool == false else { return }
            entry["enabled"] = true
            instances[existing.key] = entry
            root["providerInstances"] = instances
            return try write(root)
        }
        let driver = claude ? "claudeAgent" : "codex"
        let slug = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "_")
        var key = driver + "_" + (slug.isEmpty ? "account" : slug)
        var number = 2
        while instances[key] != nil {
            key = driver + "_" + slug + "_\(number)"
            number += 1
        }
        instances[key] = [
            "driver": driver, "displayName": name, "accentColor": hex(color), "enabled": true,
            "config": ["homePath": homePath],
        ]
        root["providerInstances"] = instances
        try write(root)
    }

    static func remove(homePath: String) throws {
        var root = read()
        var instances = instances(in: root)
        let removed = instances.filter { home(of: $0.value) == homePath }
        guard !removed.isEmpty else { return }
        for (key, value) in removed {
            instances[key] = nil
            let driver = (value as? [String: Any])?["driver"] as? String ?? "claudeAgent"
            if var favorites = root["favorites"] as? [[String: Any]] {
                favorites.removeAll { $0["provider"] as? String == key }
                root["favorites"] = favorites
            }
            if var preferences = root["providerModelPreferences"] as? [String: Any] {
                preferences[key] = nil
                root["providerModelPreferences"] = preferences
            }
            for setting in ["defaultModelSelection", "textGenerationModelSelection"] {
                guard var selection = root[setting] as? [String: Any], selection["instanceId"] as? String == key else { continue }
                selection["instanceId"] = driver
                root[setting] = selection
            }
        }
        root["providerInstances"] = instances
        try write(root)
    }

    private static func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: settings),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return root
    }

    private static func instances(in root: [String: Any]) -> [String: Any] {
        root["providerInstances"] as? [String: Any] ?? [:]
    }

    private static func home(of instance: Any) -> String? {
        ((instance as? [String: Any])?["config"] as? [String: Any])?["homePath"] as? String
    }

    private static func write(_ root: [String: Any]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: settings.path) {
            let backup = settings.appendingPathExtension("relaybar-backup")
            try? manager.removeItem(at: backup)
            try manager.copyItem(at: settings, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: settings, options: .atomic)
    }

    private static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#888888" }
        return String(format: "#%02x%02x%02x", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}
