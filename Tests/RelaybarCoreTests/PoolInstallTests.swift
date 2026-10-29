import Foundation
import Testing

@testable import RelaybarCore

struct PoolInstallTests {
    private let paths = PoolPaths(home: URL(fileURLWithPath: "/Users/sam"))

    @Test func checksTheDownload() throws {
        let command = PoolInstall.command(paths: paths)
        #expect(command.executable == "/bin/sh")
        #expect(
            command.arguments == [
                "/Users/sam/Library/Application Support/Relaybar/relaybar-helper.sh", "install",
                "/Users/sam/Library/Application Support/Relaybar/Helper",
            ])
        #expect(command.environment == ["RELAYBAR_MAJOR": "8", "HOME": "/Users/sam"])
        #expect(command.limit == 900)
        #expect(command.stdin == nil)
        let recorder = Recorder()
        try PoolInstall.install(paths: paths, run: recorder.runner)
        #expect(recorder.commands == [command])
        recorder.respond = { _ in
            CommandResult(status: 1, error: "installing\nfailed: checksum mismatch for CLIProxyAPI_8.0.44_darwin_aarch64.tar.gz\n")
        }
        #expect(throws: PoolInstallError.failed("checksum mismatch for CLIProxyAPI_8.0.44_darwin_aarch64.tar.gz")) {
            try PoolInstall.install(paths: paths, run: recorder.runner)
        }
        recorder.respond = { _ in CommandResult(status: 1) }
        #expect(throws: PoolInstallError.self) { try PoolInstall.install(paths: paths, run: recorder.runner) }
        #expect(PoolInstallError.failed("x").errorDescription?.contains("Nothing was changed") == true)
    }

    @Test func buildsTheSandboxProfile() {
        let text = PoolInstall.sandboxProfile(paths: paths)
        #expect(text.contains("(deny file-read* file-write* (subpath \"/Users/sam\"))"))
        #expect(text.contains("(allow file-read* file-write* (subpath \"/Users/sam/Library/Application Support/Relaybar/Helper\"))"))
        #expect(text.contains("com.apple.SecurityServer"))
        let denyAt = text.range(of: "(deny file-read*")!.lowerBound
        let allowAt = text.range(of: "(allow file-read* file-write*")!.lowerBound
        #expect(denyAt < allowAt)
    }

    @Test func theSandboxStopsTheHelperStartingPrograms() throws {
        let text = PoolInstall.sandboxProfile(paths: paths)
        let helper = "/Users/sam/Library/Application Support/Relaybar/Helper/versions"
        let lines = text.split(separator: "\n").map(String.init)
        let deny = try #require(lines.firstIndex(of: "(deny process-exec*)"))
        let allow = try #require(lines.firstIndex(of: "(allow process-exec* (subpath \"\(helper)\"))"))
        #expect(deny < allow)
        #expect(lines.contains("(deny file-write* (subpath \"\(helper)\"))"))
        for rule in [
            "(deny process-fork)", "(deny appleevent-send)", "com.apple.coreservices.launchservicesd", "com.apple.lsd.mapdb",
            "com.apple.coreservices.quarantine-resolver",
            "(deny file-write* (subpath \"/private/tmp\") (subpath \"/tmp\") (subpath \"/Users/Shared\"))",
        ] {
            #expect(text.contains(rule), "missing \(rule)")
        }
    }

    @Test func buildsTheHelperAgent() {
        let text = PoolInstall.helperPlist(paths: paths)
        #expect(text.contains("<string>com.relaybar.helper</string>"))
        #expect(text.contains("<string>/usr/bin/sandbox-exec</string>"))
        #expect(text.contains("<string>/Users/sam/Library/Application Support/Relaybar/Helper/current/cli-proxy-api</string>"))
        #expect(text.contains("<string>-config</string>"))
        #expect(text.contains("<key>KeepAlive</key>\n    <true/>"))
        #expect(text.contains("<key>RunAtLoad</key>\n    <true/>"))
        #expect(text.contains("<key>StandardOutPath</key>\n    <string>/dev/null</string>"))
        #expect(text.contains("<key>StandardErrorPath</key>\n    <string>/dev/null</string>"))
    }

    @Test func buildsTheNightlyUpdateAgent() {
        let text = PoolInstall.updatePlist(paths: paths)
        #expect(text.contains("<string>com.relaybar.helper-update</string>"))
        #expect(text.contains("<string>update</string>"))
        #expect(text.contains("<key>Hour</key>\n        <integer>4</integer>"))
        #expect(text.contains("<key>Minute</key>\n        <integer>0</integer>"))
        #expect(text.contains("<key>KeepAlive</key>\n    <false/>"))
        #expect(text.contains("<key>RunAtLoad</key>\n    <false/>"))
    }

    @Test func escapesXMLInPaths() {
        let odd = PoolPaths(home: URL(fileURLWithPath: "/Users/a&b"))
        #expect(PoolInstall.helperPlist(paths: odd).contains("/Users/a&amp;b/"))
        #expect(PoolInstall.quote("a\"b\\c") == "a\\\"b\\\\c")
    }
}

struct PoolTunnelTests {
    private let paths = PoolPaths(home: URL(fileURLWithPath: "/Users/sam"))

    @Test func writesTheTunnelAgent() {
        let arguments = PoolTunnel.arguments(destination: "homebox")
        #expect(
            arguments == [
                "-N", "-L", "127.0.0.1:8317:127.0.0.1:8317", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o",
                "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3", "--", "homebox",
            ])
        let text = PoolTunnel.plist(paths: paths, destination: "homebox")
        #expect(text.contains("<string>com.relaybar.helper-tunnel</string>"))
        #expect(text.contains("<string>/usr/bin/ssh</string>"))
        #expect(text.contains("<string>127.0.0.1:8317:127.0.0.1:8317</string>"))
        #expect(text.contains("<string>BatchMode=yes</string>"))
        #expect(text.contains("<string>ExitOnForwardFailure=yes</string>"))
        #expect(text.contains("<key>KeepAlive</key>\n    <true/>"))
        #expect(text.contains("<key>ThrottleInterval</key>"))
    }

    @Test func writesALinuxTunnelUnit() {
        let unit = PoolTunnel.linuxUnit(destination: "192.168.1.20")
        #expect(unit.contains("ExecStart='/usr/bin/ssh' '-N' '-L' '127.0.0.1:8317:127.0.0.1:8317'"))
        #expect(unit.contains("'192.168.1.20'"))
        #expect(unit.contains("Restart=always"))
    }
}
