import Foundation

public enum PoolTunnel {
    public static func arguments(destination: String) -> [String] {
        [
            "-N", "-L", "127.0.0.1:\(Pool.port):127.0.0.1:\(Pool.port)", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3", "--", destination,
        ]
    }

    public static func plist(paths: PoolPaths, destination: String) -> String {
        PoolInstall.plist(
            label: Pool.tunnelLabel, arguments: ["/usr/bin/ssh"] + arguments(destination: destination),
            workingDirectory: paths.appSupport.path, keepAlive: true,
            extra: "    <key>ThrottleInterval</key>\n    <integer>10</integer>\n")
    }

    public static func linuxUnit(destination: String) -> String {
        let words = (["/usr/bin/ssh"] + arguments(destination: destination)).map(Shell.quote).joined(separator: " ")
        return
            "[Unit]\nDescription=Relaybar helper tunnel\nAfter=network-online.target\n\n[Service]\nExecStart=\(words)\nRestart=always\nRestartSec=10\n\n[Install]\nWantedBy=default.target\n"
    }
}
