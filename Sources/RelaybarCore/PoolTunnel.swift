import Foundation

public enum PoolTunnel {
    public static func arguments(destination: String, extra: [String] = []) -> [String] {
        [
            "-N", "-L", "127.0.0.1:\(Pool.port):127.0.0.1:\(Pool.port)", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
        ] + extra + ["--", destination]
    }

    public static func pinnedOptions(key: String, knownHosts: String, port: Int) -> [String] {
        [
            "-i", key, "-o", "IdentitiesOnly=yes", "-o", "UserKnownHostsFile=\(knownHosts)", "-o", "StrictHostKeyChecking=yes", "-p",
            String(port),
        ]
    }

    public static func plist(paths: PoolPaths, destination: String) -> String {
        PoolInstall.plist(
            label: Pool.tunnelLabel, arguments: ["/usr/bin/ssh"] + arguments(destination: destination),
            workingDirectory: paths.appSupport.path, keepAlive: true,
            extra: "    <key>ThrottleInterval</key>\n    <integer>10</integer>\n")
    }

    public static func linuxUnit(
        user: String, addresses: [String], key: String, knownHosts: String, port: Int, ssh: String = "/usr/bin/ssh"
    ) throws -> String {
        let hosts = try addresses.map(PoolHubPicker.validate)
        guard !hosts.isEmpty else { throw PoolInputError.empty }
        let options = pinnedOptions(key: key, knownHosts: knownHosts, port: port) + ["-o", "ConnectTimeout=10"]
        let fixed = try ([ssh] + arguments(destination: "", extra: options).dropLast()).map(inDoubleQuotes)
        _ = try inDoubleQuotes(user)
        let list = try hosts.map(inDoubleQuotes).joined(separator: " ")
        let script = "for a in \(list); do \(fixed.joined(separator: " ")) \"\(user)@$a\"; r=$?; done; exit $r"
        let escaped = script.replacingOccurrences(of: "$", with: "$$").replacingOccurrences(of: "%", with: "%%")
        return
            "[Unit]\nDescription=Relaybar helper tunnel\nAfter=network-online.target\n\n[Service]\nExecStart=/bin/sh -c '\(escaped)'\nRestart=always\nRestartSec=10\n\n[Install]\nWantedBy=default.target\n"
    }

    private static func inDoubleQuotes(_ word: String) throws -> String {
        guard !word.contains(where: { "\"'\\$`\n".contains($0) }) else { throw PoolClientError.unsafeTunnel }
        return "\"\(word)\""
    }
}
