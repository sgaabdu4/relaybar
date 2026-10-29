import Foundation

public enum PoolStep: String, Codable, Sendable {
    case keychainAccessKey
    case keychainManagementSecret
    case helperFolder
    case helperAgent
    case updateAgent
    case tunnelAgent
    case remoteHelper
    case keepOn
    case linuxClient
    case hubFolders
    case terminalCommands
    case t3Entries
    case t3UsageSource
    case t3Default
}

extension PoolStep {
    public var isRemote: Bool { [.remoteHelper, .keepOn, .linuxClient].contains(self) }
}

public struct PoolKeepOn: Codable, Equatable, Sendable {
    public var linger = false
    public var masked: [String] = []

    public init(linger: Bool = false, masked: [String] = []) {
        self.linger = linger
        self.masked = masked
    }

    public var isEmpty: Bool { !linger && masked.isEmpty }
}

public struct PoolLinuxClient: Codable, Equatable, Sendable {
    public var host: String
    public var folders: [String]
    public var linger: Bool
    public var hubKey = false
    public var hubCreated: [String] = []
    public var t3Entries = false
    public var t3DefaultSet = false
    public var previousSelection: String?
    public var t3Secrets: [String] = []
    public var t3SecretsFolder = false
    public var claudeInstalled = false
    public var codexInstalled = false
    public var codexProfile = false
    public var codexFolder = false
    public var t3Installed = false
    public var t3Service = false
    public var t3Host: String?
    public var tailscaleInstalled = false

    public init(host: String, folders: [String] = [], linger: Bool = false) {
        self.host = host
        self.folders = folders
        self.linger = linger
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        host = try values.decode(String.self, forKey: .host)
        folders = try values.decodeIfPresent([String].self, forKey: .folders) ?? []
        linger = try values.decodeIfPresent(Bool.self, forKey: .linger) ?? false
        hubKey = try values.decodeIfPresent(Bool.self, forKey: .hubKey) ?? false
        hubCreated = try values.decodeIfPresent([String].self, forKey: .hubCreated) ?? []
        t3Entries = try values.decodeIfPresent(Bool.self, forKey: .t3Entries) ?? false
        t3DefaultSet = try values.decodeIfPresent(Bool.self, forKey: .t3DefaultSet) ?? false
        previousSelection = try values.decodeIfPresent(String.self, forKey: .previousSelection)
        t3Secrets = try values.decodeIfPresent([String].self, forKey: .t3Secrets) ?? []
        t3SecretsFolder = try values.decodeIfPresent(Bool.self, forKey: .t3SecretsFolder) ?? false
        claudeInstalled = try values.decodeIfPresent(Bool.self, forKey: .claudeInstalled) ?? false
        codexInstalled = try values.decodeIfPresent(Bool.self, forKey: .codexInstalled) ?? false
        codexProfile = try values.decodeIfPresent(Bool.self, forKey: .codexProfile) ?? false
        codexFolder = try values.decodeIfPresent(Bool.self, forKey: .codexFolder) ?? false
        t3Installed = try values.decodeIfPresent(Bool.self, forKey: .t3Installed) ?? false
        t3Service = try values.decodeIfPresent(Bool.self, forKey: .t3Service) ?? false
        t3Host = try values.decodeIfPresent(String.self, forKey: .t3Host)
        tailscaleInstalled = try values.decodeIfPresent(Bool.self, forKey: .tailscaleInstalled) ?? false
    }
}

public struct PoolState: Codable, Equatable, Sendable {
    public var ssh: String?
    public var tailscale: String?
    public var joined = false
    public var steps: [PoolStep] = []
    public var previousSelection: String?
    public var defaultKept = false
    public var hubFolders: [String] = []
    public var keepOn = PoolKeepOn()
    public var linuxClients: [PoolLinuxClient] = []
    public var usageSourceAdded = false
    public var order: [String: [String]] = [:]

    public init(ssh: String? = nil, joined: Bool = false) {
        self.ssh = ssh
        self.joined = joined
    }

    public var runsOnThisMac: Bool { ssh == nil }

    public var tunnelDestination: String? { tailscale ?? ssh }

    public static func load(_ paths: PoolPaths) -> PoolState? {
        guard let data = try? Data(contentsOf: paths.state) else { return nil }
        return try? JSONDecoder().decode(PoolState.self, from: data)
    }

    public func save(_ paths: PoolPaths) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PoolFile.write(try encoder.encode(self), to: paths.state, backup: false)
    }

    public mutating func record(_ step: PoolStep) {
        if !steps.contains(step) { steps.append(step) }
    }
}

public struct PoolEnvironment: Sendable {
    public var paths: PoolPaths
    public var uid: UInt32
    public var run: CommandRunner
    public var http: HTTPClient
    public var trash: @Sendable (URL) throws -> Void
    public var script: Data?
    public var t3Installed: Bool
    public var openURL: @Sendable (URL) -> Void
    public var pause: @Sendable (TimeInterval) async -> Void
    public let t3Flow = T3Flow()

    public init(
        home: URL, uid: UInt32, run: @escaping CommandRunner, http: @escaping HTTPClient, trash: @escaping @Sendable (URL) throws -> Void,
        script: Data?, t3Installed: Bool, openURL: @escaping @Sendable (URL) -> Void = { _ in },
        pause: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.paths = PoolPaths(home: home)
        self.uid = uid
        self.run = run
        self.http = http
        self.trash = trash
        self.script = script
        self.t3Installed = t3Installed
        self.openURL = openURL
        self.pause = pause
    }

    public static func live(script: URL?, t3Installed: Bool, openURL: @escaping @Sendable (URL) -> Void) -> PoolEnvironment {
        PoolEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser, uid: getuid(), run: PoolProcess.run, http: PoolHTTP.live,
            trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
            script: script.flatMap { try? Data(contentsOf: $0) }, t3Installed: t3Installed, openURL: openURL)
    }

    public var t3: T3Settings { T3Settings(home: paths.home, flow: t3Flow) }
    public var keychain: PoolKeychain { PoolKeychain(run: run) }
    public var domain: String { "gui/\(uid)" }
}

public enum PoolSSH {
    public static func options(connectTimeout: Int = 10) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"]
    }

    public static func command(
        host: String, script: String, stdin: Data? = nil, connectTimeout: Int = 10, limit: TimeInterval = 120
    ) -> Command {
        Command(
            "/usr/bin/ssh", options(connectTimeout: connectTimeout) + ["--", host, "sh -c " + Shell.quote(script)], stdin: stdin,
            limit: limit)
    }
}
