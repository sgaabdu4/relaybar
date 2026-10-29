import Foundation

public enum PoolTailscaleError: Error, Equatable, LocalizedError {
    case downloadFailed
    case notTailscales
    case installDeclined
    case needsPassword
    case homeFailed(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Relaybar could not download Tailscale. Check the internet connection, then try again."
        case .notTailscales:
            return "The download is not signed by Tailscale, so Relaybar did not install it. Nothing was changed."
        case .installDeclined:
            return "Tailscale was not installed on this Mac. Nothing was changed."
        case .needsPassword:
            return "Relaybar needs the password for the home computer to install Tailscale there."
        case .homeFailed(let reason):
            return "Tailscale could not be set up on the home computer: \(reason)"
        case .timedOut(let place):
            return "Tailscale was not signed in on \(place) in time. Your connection was left as it was. Try again when you are ready."
        }
    }
}

public enum PoolTailscaleStage: Int, CaseIterable, Sendable {
    case download
    case install
    case allow
    case signIn
    case home
    case connection
}

public enum PoolStageState: Equatable, Sendable {
    case next
    case working
    case yourTurn
    case done
    case problem(String)
}

public enum PoolTailscaleReason: Equatable, Sendable {
    case differentTailnet
    case notAnswering
}

public enum PoolSwitchOutcome: Equatable, Sendable {
    case switched(String)
    case notApplicable
    case stayed(PoolTailscaleReason)
}

public struct PoolTailscaleStatus: Equatable, Sendable {
    public var backend: String
    public var addresses: [String]
    public var peers: [String]

    public var running: Bool { backend == "Running" }
    public var daemonUp: Bool { backend != "NoState" }
    public var ipv4: String? { addresses.first(where: PoolTailscale.isIPv4) }

    public static func parse(_ text: String) -> PoolTailscaleStatus? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
            let backend = object["BackendState"] as? String
        else { return nil }
        let own = (object["Self"] as? [String: Any])?["TailscaleIPs"] as? [String] ?? object["TailscaleIPs"] as? [String] ?? []
        let peers = (object["Peer"] as? [String: Any] ?? [:]).values.flatMap { ($0 as? [String: Any])?["TailscaleIPs"] as? [String] ?? [] }
        return PoolTailscaleStatus(backend: backend, addresses: own, peers: peers)
    }
}

public struct PoolTailscaleMac: Equatable, Sendable {
    public var installed: Bool
    public var status: PoolTailscaleStatus?
}

public struct PoolTailscaleHome: Equatable, Sendable {
    public var installed: Bool
    public var running: Bool
    public var address: String?
}

public struct PoolTailscaleHooks: Sendable {
    public var install: @Sendable (URL) async -> Bool
    public var password: @Sendable (Bool) async -> String?
    public var report: @Sendable (PoolTailscaleStage, PoolStageState) -> Void

    public init(
        install: @escaping @Sendable (URL) async -> Bool, password: @escaping @Sendable (Bool) async -> String?,
        report: @escaping @Sendable (PoolTailscaleStage, PoolStageState) -> Void
    ) {
        self.install = install
        self.password = password
        self.report = report
    }
}

extension PoolState {
    public var onTailscale: Bool { tailscale != nil || (ssh.map(PoolTailscale.isTailscaleAddress) ?? false) }
    public var needsTailscale: Bool { ssh != nil && !onTailscale }
}

public struct PoolTailscale: Sendable {
    public static let macApp = "/Applications/Tailscale.app"
    public static let macCLI = macApp + "/Contents/MacOS/Tailscale"
    public static let teamID = "W5364U7YZB"
    public static let packageURL = "https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg"
    public static let installScriptURL = "https://tailscale.com/install.sh"
    public static let loginHost = "login.tailscale.com"
    static let missing = "RB-MISSING"
    static let addressMark = "RB-IP"
    static let statusMark = "RB-STATUS"
    static let running = "RB-RUNNING"

    public let env: PoolEnvironment
    public let work: URL

    public init(
        env: PoolEnvironment,
        work: URL = FileManager.default.temporaryDirectory.appendingPathComponent("relaybar-tailscale-" + UUID().uuidString)
    ) {
        self.env = env
        self.work = work
    }

    public static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } == true }
    }

    public static func isTailscaleAddress(_ destination: String) -> Bool {
        let host = destination.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        if host.hasSuffix(".ts.net") || host.hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return isIPv4(host) && parts[0] == 100 && (64...127).contains(parts[1])
    }

    public static func signInLink(in output: String) -> URL? {
        for word in output.split(whereSeparator: \.isWhitespace) where word.hasPrefix("https://") {
            guard let parts = URLComponents(string: String(word)), parts.scheme == "https", parts.host == loginHost,
                parts.path.count > 1, let url = parts.url
            else { continue }
            return url
        }
        return nil
    }

    public static func installerIsTailscales(_ report: String) -> Bool {
        let lines = report.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let signed = lines.contains { $0.hasPrefix("Status: signed by a developer certificate issued by Apple") }
        let leaf = lines.contains { $0.hasPrefix("1. Developer ID Installer: ") && $0.hasSuffix("(\(teamID))") }
        return signed && leaf
    }

    public static func installScript(package: URL) -> String {
        let path = package.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"/usr/sbin/installer -pkg \" & quoted form of \"\(path)\" & \" -target /\" with administrator privileges"
    }

    public static func installCommand(package: URL) -> Command {
        Command("/usr/bin/osascript", ["-e", installScript(package: package)], limit: 900)
    }

    public func mac() -> PoolTailscaleMac {
        let result = env.run(Command(Self.macCLI, ["status", "--json"], limit: 30))
        guard result.status != 127 else { return PoolTailscaleMac(installed: false, status: nil) }
        return PoolTailscaleMac(installed: true, status: PoolTailscaleStatus.parse(result.output))
    }

    public func home(_ host: String) throws -> PoolTailscaleHome {
        let script =
            "if ! command -v tailscale >/dev/null 2>&1; then echo \(Self.missing); exit 0; fi; echo \(Self.addressMark); "
            + "tailscale ip -4 2>/dev/null; echo \(Self.statusMark); tailscale status --json 2>/dev/null; true"
        let result = env.run(PoolSSH.command(host: host, script: script))
        guard result.succeeded else { throw PoolSSHError.failed(PoolHubPicker.explain(result.error, host: host)) }
        if result.output.contains(Self.missing) { return PoolTailscaleHome(installed: false, running: false, address: nil) }
        let parts = result.output.components(separatedBy: Self.statusMark + "\n")
        let address = parts[0].split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first(where: Self.isIPv4)
        let status = parts.count > 1 ? PoolTailscaleStatus.parse(parts[1]) : nil
        return PoolTailscaleHome(installed: true, running: status?.running == true && address != nil, address: address)
    }

    func reaches(_ destination: String) -> Bool {
        env.run(
            Command(
                "/usr/bin/ssh",
                [
                    "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new", "--", destination,
                    "true",
                ], limit: 20)
        ).succeeded
    }

    func user(of destination: String) -> String? {
        if destination.contains("@") { return destination.split(separator: "@").first.map(String.init) }
        let result = env.run(PoolSSH.command(host: destination, script: "id -un"))
        let name = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !name.isEmpty && !name.contains(where: \.isWhitespace) ? name : nil
    }

    func load() {
        let plist = env.paths.agent(Pool.tunnelLabel).path
        _ = env.run(Command("/bin/launchctl", ["bootout", "\(env.domain)/\(Pool.tunnelLabel)"], limit: 30))
        _ = env.run(Command("/bin/launchctl", ["bootstrap", env.domain, plist], limit: 30))
    }

    func point(at destination: String) throws {
        try PoolFile.write(
            Data(PoolTunnel.plist(paths: env.paths, destination: destination).utf8), to: env.paths.agent(Pool.tunnelLabel), backup: false)
        load()
    }

    func waitForTunnel() async -> Bool {
        let api = PoolManagement(secret: "", http: env.http)
        for _ in 0..<20 {
            if await api.isUp() { return true }
            await env.pause(1)
        }
        return false
    }

    public func switchTunnel(to address: String, mac: PoolTailscaleStatus) async -> PoolSwitchOutcome {
        guard var state = PoolState.load(env.paths), let host = state.ssh, state.needsTailscale else { return .notApplicable }
        guard let name = user(of: host) else { return .stayed(.notAnswering) }
        let destination = "\(name)@\(address)"
        guard reaches(destination) else { return .stayed(mac.peers.contains(address) ? .notAnswering : .differentTailnet) }
        state.tailscale = destination
        guard (try? state.save(env.paths)) != nil, (try? point(at: destination)) != nil else {
            return await putBack(host, state)
        }
        if await waitForTunnel() { return .switched(destination) }
        return await putBack(host, state)
    }

    private func putBack(_ host: String, _ state: PoolState) async -> PoolSwitchOutcome {
        var original = state
        original.tailscale = nil
        try? original.save(env.paths)
        try? point(at: host)
        _ = await waitForTunnel()
        return .stayed(.notAnswering)
    }

    public func automaticSwitch() async -> PoolSwitchOutcome {
        guard let state = PoolState.load(env.paths), let host = state.ssh, state.needsTailscale else { return .notApplicable }
        guard let status = mac().status, status.running else { return .notApplicable }
        guard let home = try? home(host), home.running, let address = home.address else { return .notApplicable }
        return await switchTunnel(to: address, mac: status)
    }

    public func downloadInstaller() throws -> URL {
        try PoolFile.makeFolder(work, secret: true)
        let file = work.appendingPathComponent("Tailscale.pkg")
        let result = env.run(
            Command(
                "/usr/bin/curl", ["-fsSL", "--proto", "=https", "--max-time", "900", "-o", file.path, Self.packageURL], limit: 960))
        guard result.succeeded else { throw PoolTailscaleError.downloadFailed }
        let check = env.run(Command("/usr/sbin/pkgutil", ["--check-signature", file.path], limit: 60))
        guard check.succeeded, Self.installerIsTailscales(check.output) else { throw PoolTailscaleError.notTailscales }
        return file
    }

    private enum Privileged {
        case done(String)
        case needsPassword
        case failed(String)
    }

    private func privileged(_ host: String, _ command: String, password: String?, limit: TimeInterval) -> Privileged {
        let inner = Shell.quote(command)
        let script = password == nil ? "sudo -n sh -c \(inner)" : "sudo -S -p '' sh -c \(inner)"
        let result = env.run(
            PoolSSH.command(host: host, script: script, stdin: password.map { Data(($0 + "\n").utf8) }, limit: limit))
        if result.succeeded { return .done(result.output) }
        let text = result.error.lowercased()
        if text.contains("password is required") || text.contains("try again") || text.contains("incorrect password") {
            return .needsPassword
        }
        return .failed(result.error.split(whereSeparator: \.isNewline).last.map(String.init) ?? "no reason given")
    }

    private func signInCommand() -> String {
        "tailscale status --json 2>/dev/null | grep -q '\"BackendState\": *\"Running\"' && { echo \(Self.running); exit 0; }; "
            + "f=$(mktemp); nohup tailscale up >\"$f\" 2>&1 </dev/null & pid=$!; "
            + "while kill -0 $pid 2>/dev/null && ! grep -q 'https://\(Self.loginHost)/' \"$f\"; do sleep 1; done; cat \"$f\""
    }

    private func asPrivileged(
        _ host: String, _ command: String, limit: TimeInterval, hooks: PoolTailscaleHooks, password: inout String?
    ) async throws -> String {
        var wrong = false
        while true {
            switch privileged(host, command, password: password, limit: limit) {
            case .done(let output): return output
            case .failed(let reason): throw PoolTailscaleError.homeFailed(reason)
            case .needsPassword:
                guard let typed = await hooks.password(wrong), !typed.isEmpty else { throw PoolTailscaleError.needsPassword }
                password = typed
                wrong = true
            }
        }
    }

    private func waitForHome(_ host: String) async throws -> String {
        for _ in 0..<300 {
            try Task.checkCancellation()
            if let found = try? home(host), found.running, let address = found.address { return address }
            await env.pause(3)
        }
        throw PoolTailscaleError.timedOut(host)
    }

    private func waitForMac(hooks: PoolTailscaleHooks) async throws -> PoolTailscaleStatus {
        var allowed = false
        for _ in 0..<300 {
            try Task.checkCancellation()
            if let status = mac().status {
                if status.running { return status }
                if status.daemonUp, !allowed {
                    allowed = true
                    hooks.report(.allow, .done)
                    hooks.report(.signIn, .yourTurn)
                }
            }
            await env.pause(3)
        }
        throw PoolTailscaleError.timedOut("this Mac")
    }

    public func setUp(host: String, hooks: PoolTailscaleHooks) async throws -> PoolSwitchOutcome {
        defer { PoolFile.remove(work) }
        let report = hooks.report
        let current = mac()
        var address = try home(host)
        let installed = current.installed
        report(.download, installed ? .done : .next)
        report(.install, installed ? .done : .next)
        report(.allow, current.status?.daemonUp == true ? .done : .next)
        report(.signIn, current.status?.running == true ? .done : .next)
        report(.home, address.running ? .done : .next)
        report(.connection, .next)
        if !installed {
            report(.download, .working)
            let package = try downloadInstaller()
            try Task.checkCancellation()
            report(.download, .done)
            report(.install, .yourTurn)
            let installed = await hooks.install(package)
            try Task.checkCancellation()
            guard installed else { throw PoolTailscaleError.installDeclined }
            report(.install, .done)
        }
        var status = current.status
        if status?.running != true {
            env.openURL(URL(fileURLWithPath: Self.macApp))
            report(status?.daemonUp == true ? .signIn : .allow, .yourTurn)
            status = try await waitForMac(hooks: hooks)
            report(.allow, .done)
            report(.signIn, .done)
        }
        guard let own = status else { return .notApplicable }
        if !address.running {
            report(.home, .working)
            address.address = try await signInHome(host, found: address, hooks: hooks)
        }
        report(.home, .done)
        try Task.checkCancellation()
        report(.connection, .working)
        guard let target = address.address else { return .notApplicable }
        let outcome = await switchTunnel(to: target, mac: mac().status ?? own)
        switch outcome {
        case .switched: report(.connection, .done)
        case .stayed(.differentTailnet): report(.connection, .problem("Different accounts"))
        case .stayed(.notAnswering), .notApplicable: report(.connection, .problem("Did not answer"))
        }
        return outcome
    }

    private func signInHome(_ host: String, found: PoolTailscaleHome, hooks: PoolTailscaleHooks) async throws -> String {
        try Task.checkCancellation()
        var password: String?
        if !found.installed {
            _ = try await asPrivileged(host, "curl -fsSL \(Self.installScriptURL) | sh", limit: 600, hooks: hooks, password: &password)
        }
        let output = try await asPrivileged(host, signInCommand(), limit: 180, hooks: hooks, password: &password)
        if let link = Self.signInLink(in: output) {
            env.openURL(link)
            hooks.report(.home, .yourTurn)
        } else if !output.contains(Self.running) {
            if let ready = try? home(host), ready.running, let address = ready.address { return address }
            throw PoolTailscaleError.homeFailed(output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "no answer.")
        }
        return try await waitForHome(host)
    }
}
