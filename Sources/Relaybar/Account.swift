import Foundation
import RelaybarCore

@MainActor
final class Account {
    let id: String
    let provider: AccountInfo.Source
    let label: String
    private let defaultTag: String
    private let defaultTint: Tint

    private(set) var session: Window?
    private(set) var weekly: Window?
    private(set) var stale = false
    private(set) var lastFetch = Date.distantPast
    var refreshQueued = false
    private var retryAt = Date.distantPast
    private var backoff: TimeInterval = 120

    init(_ info: AccountInfo, defaultTint: Tint) {
        self.id = info.id
        self.provider = info.source
        self.label = info.label
        self.defaultTag = info.defaultTag
        self.defaultTint = defaultTint
        if let saved = UserDefaults.standard.array(forKey: "usage:" + id) as? [Double], saved.count == 4 {
            session = Self.window(saved, 0)
            weekly = Self.window(saved, 2)
        }
    }

    private static func window(_ saved: [Double], _ index: Int) -> Window? {
        guard saved[index] >= 0 else { return nil }
        return Window(used: saved[index], resetsAt: saved[index + 1] > 0 ? Date(timeIntervalSince1970: saved[index + 1]) : nil)
    }

    var isClaude: Bool {
        if case .claude = provider { return true }
        return false
    }

    var watchPath: String {
        let sub = isClaude ? "projects" : "sessions"
        let path = id + "/" + sub
        return FileManager.default.fileExists(atPath: path) ? path : id
    }

    var tag: String {
        get { UserDefaults.standard.string(forKey: "tag:" + id) ?? defaultTag }
        set { UserDefaults.standard.set(newValue, forKey: "tag:" + id) }
    }

    var tint: Tint {
        get { UserDefaults.standard.string(forKey: "color:" + id).flatMap(Tint.init(rawValue:)) ?? defaultTint }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "color:" + id) }
    }

    func refresh() async {
        guard Date() >= retryAt else { return }
        lastFetch = Date()
        let result: FetchResult
        switch provider {
        case .claude(let service): result = await Fetch.claude(service: service)
        case .codex(let authFile): result = await Fetch.codex(authFile: authFile)
        }
        apply(result)
    }

    func apply(_ result: FetchResult) {
        switch result {
        case .ok(let session, let weekly):
            self.session = session
            self.weekly = weekly
            let saved = [session, weekly].flatMap { window -> [Double] in
                [window?.used ?? -1, window?.resetsAt?.timeIntervalSince1970 ?? 0]
            }
            UserDefaults.standard.set(saved, forKey: "usage:" + id)
            stale = false
            backoff = 120
        case .expired:
            stale = true
        case .rateLimited(let retryAfter):
            retryAt = Date().addingTimeInterval(retryAfter ?? backoff)
            backoff = min(backoff * 2, 900)
        case .failed:
            break
        }
    }

    static func discover() -> [Account] {
        var claudeCount = 0
        return AccountScanner.scan(home: FileManager.default.homeDirectoryForCurrentUser).map { info in
            guard case .claude = info.source else { return Account(info, defaultTint: .plain) }
            defer { claudeCount += 1 }
            return Account(info, defaultTint: Tint.palette[claudeCount % Tint.palette.count])
        }
    }
}
