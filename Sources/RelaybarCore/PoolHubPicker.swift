import Foundation

public struct IPInfo: Equatable, Sendable {
    public let ip: String
    public let org: String
}

public enum PoolInputError: Error, Equatable, LocalizedError {
    case empty
    case startsWithDash
    case badCharacters

    public var errorDescription: String? {
        switch self {
        case .empty: return "Type an address or an SSH name."
        case .startsWithDash: return "An address cannot start with a dash. Type an address like 192.168.1.20 or an SSH name."
        case .badCharacters: return "An address cannot hold spaces or odd characters. Type an address like 192.168.1.20 or an SSH name."
        }
    }
}

public enum PoolVerdict: Equatable, Sendable {
    case offer
    case hidden(String)
}

public struct PoolComputer: Equatable, Sendable {
    public let name: String
    public let verdict: PoolVerdict

    public init(name: String, verdict: PoolVerdict) {
        self.name = name
        self.verdict = verdict
    }
}

public struct PoolChoices: Equatable, Sendable {
    public let macLooksLikeCloud: Bool
    public let computers: [PoolComputer]

    public init(macLooksLikeCloud: Bool, computers: [PoolComputer]) {
        self.macLooksLikeCloud = macLooksLikeCloud
        self.computers = computers
    }

    public var offered: [PoolComputer] { computers.filter { $0.verdict == .offer } }
}

public enum PoolHubPicker {
    static let cloudNames = [
        "amazon", "google", "microsoft", "digitalocean", "hetzner", "ovh", "linode", "akamai", "vultr", "oracle", "alibaba", "tencent",
        "scaleway", "contabo", "cloudflare", "mullvad", "nordvpn", "proton", "m247", "surfshark", "private internet access",
    ]

    static let keyProblem = "SSH asked for a password."

    public static func parseSSHConfig(_ text: String) -> [String] {
        var seen: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard words.first?.lowercased() == "host" else { continue }
            for word in words.dropFirst() where !word.contains(where: { "*?!".contains($0) }) {
                if !seen.contains(String(word)) { seen.append(String(word)) }
            }
        }
        return seen
    }

    public static func validate(_ typed: String) throws -> String {
        let value = typed.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { throw PoolInputError.empty }
        if value.hasPrefix("-") { throw PoolInputError.startsWithDash }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:@%-[]")
        guard value.count <= 255, value.unicodeScalars.allSatisfy(allowed.contains) else { throw PoolInputError.badCharacters }
        return value
    }

    public static func parseIPInfo(_ data: Data) -> IPInfo? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let ip = json["ip"] as? String else {
            return nil
        }
        return IPInfo(ip: ip, org: json["org"] as? String ?? "")
    }

    public static func isCloud(_ org: String) -> Bool {
        let lower = org.lowercased()
        return cloudNames.contains { lower.contains($0) }
    }

    public static func explain(_ stderr: String, host: String) -> String {
        if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return
                "The SSH identity of \(host) changed. If you did not change it, do not go on. Otherwise remove its old line from ~/.ssh/known_hosts, then click Try Again."
        }
        if stderr.contains("Host key verification failed") {
            return "This Mac has not met \(host) yet. Run \"ssh \(host)\" once in Terminal and accept its key, then click Try Again."
        }
        if stderr.contains("Permission denied") {
            return keyProblem + " Add this Mac's SSH key to that computer, then click Try Again."
        }
        if stderr.contains("Connection refused") {
            return "\(host) refused the connection. Turn on SSH (Remote Login) on that computer, then click Try Again."
        }
        if stderr.contains("Could not resolve hostname") {
            return "Relaybar cannot find \(host). Check the name or address, then click Try Again."
        }
        if stderr.contains("timed out") || stderr.contains("No route to host") || stderr.contains("Network is unreachable") {
            return "\(host) did not answer. Check that it is on and on the same network, then click Try Again."
        }
        let first = stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "no reason given"
        return "SSH to \(host) failed (\(first)). Check that you can run \"ssh \(host)\" in Terminal, then click Try Again."
    }

    static let probeScript =
        "echo \"os=$(uname -s)\"; echo \"state=$(systemctl is-system-running 2>/dev/null)\"; echo \"up=$(cut -d. -f1 /proc/uptime 2>/dev/null)\"; echo \"id=$(cat /etc/machine-id 2>/dev/null)\"; "
        + "echo \"info=$(curl -fsS --max-time 8 https://ipinfo.io/json 2>/dev/null | tr -d '\\n')\""

    public static func probe(host: String) -> Command {
        PoolSSH.command(host: host, script: probeScript, connectTimeout: 5, limit: 15)
    }

    public static func judge(_ result: CommandResult, host: String, mac: IPInfo) -> PoolVerdict {
        guard result.succeeded else { return .hidden(explain(result.error, host: host)) }
        var fields: [String: String] = [:]
        for line in result.output.split(separator: "\n") {
            guard let split = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<split])] = String(line[line.index(after: split)...])
        }
        guard fields["os"] == "Linux" else { return .hidden("\(host) is not a Linux computer.") }
        guard let info = fields["info"].flatMap({ parseIPInfo(Data($0.utf8)) }) else {
            return .hidden("Relaybar could not check where \(host) is. Check that it can reach the internet.")
        }
        if isCloud(info.org) { return .hidden("\(host) looks like a cloud server. Combining accounts there can get them banned.") }
        if info.ip != mac.ip { return .hidden("\(host) is not on this Mac's home network address, so it is not at home.") }
        let uptime = fields["up"].flatMap(Double.init) ?? 0
        guard ["running", "degraded"].contains(fields["state"] ?? ""), uptime >= 86_400 else {
            return .hidden("\(host) does not look always on. Use a computer that stays on.")
        }
        return .offer
    }

    public static func lookUpThisMac(_ env: PoolEnvironment) async -> IPInfo? {
        let response = await env.http(HTTPRequest("GET", URL(string: "https://ipinfo.io/json")!))
        return response.flatMap { parseIPInfo($0.body) }
    }

    public static func isHomeAddress(_ name: String) -> Bool {
        let lower = name.lowercased()
        if !lower.contains(".") { return true }
        if [".local", ".lan", ".home", ".home.arpa", ".ts.net"].contains(where: { lower.hasSuffix($0) }) { return true }
        if lower.hasPrefix("fd") || lower.hasPrefix("fe80:") { return true }
        let parts = lower.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168), (172, 16...31), (100, 64...127): return true
        default: return false
        }
    }

    static func address(of host: String, run: CommandRunner) -> String {
        let result = run(Command("/usr/bin/ssh", ["-G", host], limit: 5))
        let line = result.output.split(whereSeparator: \.isNewline).first { $0.hasPrefix("hostname ") }
        return line.map { String($0.dropFirst("hostname ".count)) } ?? host
    }

    public static func addable(hosts: [String], excluding: [String], run: CommandRunner) -> [String] {
        hosts.filter { (try? validate($0)) != nil && !excluding.contains($0) && isHomeAddress(address(of: $0, run: run)) }
    }

    public static func discover(hosts: [String], env: PoolEnvironment) async -> PoolChoices {
        guard let mac = await lookUpThisMac(env), !isCloud(mac.org) else {
            return PoolChoices(macLooksLikeCloud: true, computers: [])
        }
        let run = env.run
        let hosts = hosts.filter { (try? validate($0)) == nil || isHomeAddress(address(of: $0, run: run)) }
        let probed = await withTaskGroup(of: (Int, PoolComputer, String).self) { group in
            for (index, host) in hosts.enumerated() {
                group.addTask {
                    guard (try? validate(host)) != nil else {
                        return (index, PoolComputer(name: host, verdict: .hidden("Not a usable name.")), "")
                    }
                    let result = run(probe(host: host))
                    let id = result.output.split(separator: "\n").first { $0.hasPrefix("id=") }.map { String($0.dropFirst(3)) } ?? ""
                    return (index, PoolComputer(name: host, verdict: judge(result, host: host, mac: mac)), id)
                }
            }
            var found: [(Int, PoolComputer, String)] = []
            for await item in group { found.append(item) }
            return found.sorted { $0.0 < $1.0 }
        }
        var seen: Set<String> = []
        let computers = probed.compactMap { _, computer, id -> PoolComputer? in
            guard computer.verdict == .offer, !id.isEmpty else { return computer }
            return seen.insert(id).inserted ? computer : nil
        }
        return PoolChoices(macLooksLikeCloud: false, computers: computers)
    }

    public static func check(typed: String, env: PoolEnvironment) async throws -> PoolComputer {
        let host = try validate(typed)
        guard let mac = await lookUpThisMac(env), !isCloud(mac.org) else {
            return PoolComputer(
                name: host, verdict: .hidden("This Mac looks like a cloud server or VPN. Switch it off and be at home, then try again."))
        }
        let run = env.run
        let result = await Task.detached { run(probe(host: host)) }.value
        return PoolComputer(name: host, verdict: judge(result, host: host, mac: mac))
    }
}
