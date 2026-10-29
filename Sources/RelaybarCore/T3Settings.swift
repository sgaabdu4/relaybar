import Foundation

public enum T3SettingsError: Error, Equatable, LocalizedError {
    case unreadable

    public var errorDescription: String? {
        "T3 Code's settings file could not be read, so Relaybar did not change it. Fix or move ~/.t3/userdata/settings.json, then try again."
    }
}

public final class T3Flow: @unchecked Sendable {
    private let lock = NSLock()
    private var backedUp = false

    public init() {}

    func firstBackup() -> Bool {
        lock.withLock {
            defer { backedUp = true }
            return !backedUp
        }
    }
}

public enum PoolDefaultChange: Equatable, Sendable {
    case set(previous: String?)
    case alreadyPool
    case kept
}

public struct T3Settings {
    public let settings: URL
    private let flow: T3Flow

    public init(home: URL, flow: T3Flow = T3Flow()) {
        settings = home.appendingPathComponent(".t3/userdata/settings.json")
        self.flow = flow
    }

    public func contains(homePath: String) -> Bool {
        instances(in: (try? read()) ?? [:]).contains { home(of: $0.value) == homePath }
    }

    public func validate() throws {
        _ = try read()
    }

    public func add(claude: Bool, name: String, hex: String, homePath: String) throws {
        var root = try read()
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
            "driver": driver, "displayName": name, "accentColor": hex, "enabled": true,
            "config": ["homePath": homePath],
        ]
        root["providerInstances"] = instances
        try write(root)
    }

    public func remove(homePath: String) throws {
        try remove(matching: { home(of: $0.value) == homePath })
    }

    private func remove(matching match: (Dictionary<String, Any>.Element) -> Bool) throws {
        var root = try read()
        var instances = instances(in: root)
        let removed = instances.filter(match)
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

    public static let claudePoolID = "claudeAgent_all_accounts"
    public static let codexPoolID = "codex_all_accounts"
    public static let usageSourceID = "relaybar"
    private static let tokenVariable = "ANTHROPIC_AUTH_TOKEN"

    public func addPoolEntries(
        accessKey: String, hex: String, claudeBinary: String? = nil, codexBinary: String? = nil
    ) throws {
        var root = try read()
        try writeSecret(
            "provider-env-\(Self.encode(Self.claudePoolID))-\(Self.encode(Self.tokenVariable))", accessKey)
        var instances = instances(in: root)
        instances[Self.claudePoolID] = [
            "driver": "claudeAgent", "displayName": Pool.claudeName, "accentColor": hex, "enabled": true,
            "config": Self.config(binaryPath: claudeBinary),
            "environment": [
                ["name": "ANTHROPIC_BASE_URL", "value": Pool.base.absoluteString, "sensitive": false],
                ["name": Self.tokenVariable, "value": "", "sensitive": true, "valueRedacted": true],
            ],
        ]
        instances[Self.codexPoolID] = [
            "driver": "codex", "displayName": Pool.codexName, "accentColor": hex, "enabled": true,
            "config": Self.config(binaryPath: codexBinary),
        ]
        root["providerInstances"] = instances
        try write(root)
    }

    private static func config(binaryPath: String?) -> [String: String] {
        binaryPath.map { ["binaryPath": $0] } ?? [:]
    }

    public func removePoolEntries() throws {
        try remove(matching: { [Self.claudePoolID, Self.codexPoolID].contains($0.key) })
        try? FileManager.default.removeItem(
            at: secretFile("provider-env-\(Self.encode(Self.claudePoolID))-\(Self.encode(Self.tokenVariable))"))
    }

    public func claudeModel() -> String? {
        guard let root = try? read() else { return nil }
        let instances = instances(in: root)
        let selection = root["defaultModelSelection"] as? [String: Any]
        if let current = selection?["instanceId"] as? String, isClaude(current, instances), let model = selection?["model"] as? String,
            !model.isEmpty
        {
            return model
        }
        return firstClaudeModel(root, instances)
    }

    public func setPoolDefault(fallbackModel: String? = nil) throws -> PoolDefaultChange {
        var root = try read()
        let instances = instances(in: root)
        let selection = root["defaultModelSelection"] as? [String: Any]
        let current = selection?["instanceId"] as? String
        if current == Self.claudePoolID { return .alreadyPool }
        var next: [String: Any]
        if let selection, let current, isClaude(current, instances), selection["model"] is String {
            next = selection
        } else if let model = firstClaudeModel(root, instances) ?? fallbackModel {
            next = ["model": model]
        } else {
            return .kept
        }
        next["instanceId"] = Self.claudePoolID
        let previous = selection.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .map { String(decoding: $0, as: UTF8.self) }
        root["defaultModelSelection"] = next
        try write(root)
        return .set(previous: previous)
    }

    public func restoreDefault(to previous: String?) throws {
        var root = try read()
        guard let selection = root["defaultModelSelection"] as? [String: Any], selection["instanceId"] as? String == Self.claudePoolID
        else { return }
        root["defaultModelSelection"] = previous.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        try write(root)
    }

    private func isClaude(_ id: String, _ instances: [String: Any]) -> Bool {
        id == "claudeAgent" || ((instances[id] as? [String: Any])?["driver"] as? String) == "claudeAgent"
    }

    private func firstClaudeModel(_ root: [String: Any], _ instances: [String: Any]) -> String? {
        let favorites = root["favorites"] as? [[String: Any]] ?? []
        for favorite in favorites {
            if let provider = favorite["provider"] as? String, provider != Self.claudePoolID, isClaude(provider, instances),
                let model = favorite["model"] as? String, !model.isEmpty
            {
                return model
            }
        }
        let preferences = root["providerModelPreferences"] as? [String: Any] ?? [:]
        for provider in preferences.keys.sorted() where provider != Self.claudePoolID && isClaude(provider, instances) {
            let order = (preferences[provider] as? [String: Any])?["modelOrder"] as? [String]
            if let model = order?.first(where: { !$0.isEmpty }) { return model }
        }
        return nil
    }

    public func addUsageSource(url: String, managementSecret: String, alreadyAdded: Bool) throws -> Bool {
        var root = try read()
        var sources = root["usageLimitSources"] as? [String: Any] ?? [:]
        guard !alreadyAdded, sources[Self.usageSourceID] == nil else { return false }
        try writeSecret("usage-limit-source-\(Self.encode(Self.usageSourceID))", managementSecret)
        sources[Self.usageSourceID] = [
            "kind": "cliproxy", "label": Pool.usageSourceLabel, "url": url,
            "managementKey": "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}",
            "enabled": true,
        ]
        root["usageLimitSources"] = sources
        try write(root)
        return true
    }

    public func removeUsageSource() throws {
        var root = try read()
        if var sources = root["usageLimitSources"] as? [String: Any], sources[Self.usageSourceID] != nil {
            sources[Self.usageSourceID] = nil
            root["usageLimitSources"] = sources.isEmpty ? nil : sources
            try write(root)
        }
        try? FileManager.default.removeItem(at: secretFile("usage-limit-source-\(Self.encode(Self.usageSourceID))"))
    }

    public func secretFile(_ name: String) -> URL {
        settings.deletingLastPathComponent().appendingPathComponent("secrets/\(name).bin")
    }

    private func writeSecret(_ name: String, _ value: String) throws {
        try PoolFile.write(Data(value.utf8), to: secretFile(name), secret: true, backup: false)
    }

    static func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func read() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settings.path) else { return [:] }
        guard let data = try? Data(contentsOf: settings),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw T3SettingsError.unreadable }
        return root
    }

    private func instances(in root: [String: Any]) -> [String: Any] {
        root["providerInstances"] as? [String: Any] ?? [:]
    }

    private func home(of instance: Any) -> String? {
        ((instance as? [String: Any])?["config"] as? [String: Any])?["homePath"] as? String
    }

    private func write(_ root: [String: Any]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: settings.path), flow.firstBackup() {
            let backup = settings.appendingPathExtension("relaybar-backup")
            try? manager.removeItem(at: backup)
            try manager.copyItem(at: settings, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: settings, options: .atomic)
    }
}
