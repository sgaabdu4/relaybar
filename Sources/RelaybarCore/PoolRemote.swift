import CryptoKit
import Foundation

public enum PoolSleep: Equatable, Sendable {
    case off
    case needsPassword
}

public enum PoolRemoteStatus: Equatable, Sendable {
    case free
    case relaybarHub
    case conflict(PoolConflict)
}

public struct PoolKeepResult: Equatable, Sendable {
    public var sleep: PoolSleep?
    public var changes: PoolKeepOn
}

public struct PoolRemote: Sendable {
    public static let helperDir = "$HOME/.local/share/relaybar-helper"
    public static let scriptPath = "$HOME/.local/share/relaybar/relaybar-helper.sh"
    public static let joinFile = helperDir + "/join.json"
    static let sleepList = ["sleep.target", "suspend.target", "hibernate.target", "hybrid-sleep.target"]
    static let sleepTargets = sleepList.joined(separator: " ")
    static let needsPasswordStatus: Int32 = 7

    public let host: String
    public let run: CommandRunner

    public init(host: String, run: @escaping CommandRunner) {
        self.host = host
        self.run = run
    }

    @discardableResult
    func execute(_ script: String, stdin: Data? = nil, limit: TimeInterval = 120) throws -> String {
        let result = run(PoolSSH.command(host: host, script: script, stdin: stdin, limit: limit))
        guard result.succeeded else { throw PoolSSHError.failed(PoolHubPicker.explain(result.error, host: host)) }
        return result.output
    }

    public func remoteHome() throws -> String {
        let home = try execute("printf %s \"$HOME\"").trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/") else { throw PoolSSHError.failed("\(host) did not say where its home folder is.") }
        return home
    }

    public func status() throws -> PoolRemoteStatus {
        let answer = try execute(
            "if [ -f \"\(Self.joinFile)\" ]; then echo ours; elif [ -e \"\(Self.helperDir)/config.yaml\" ]; then echo folder; "
                + "else curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:\(Pool.port)/v1/models || true; fi"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        switch answer {
        case "ours": return .relaybarHub
        case "folder": return .conflict(.foreignHelperFolder(Self.folderName(host)))
        case "401", "200": return .conflict(.portInUse(Pool.port))
        default: return .free
        }
    }

    private static func folderName(_ host: String) -> String { "\(host):.local/share/relaybar-helper" }

    public func claim() throws {
        let answer = try execute(
            "mkdir -p \"$HOME/.local/share\" && if mkdir -m 700 \"\(Self.helperDir)\" 2>/dev/null; then echo claimed; else echo exists; fi")
        guard answer.trimmingCharacters(in: .whitespacesAndNewlines) == "claimed" else {
            throw PoolSetupError.conflict(.foreignHelperFolder(Self.folderName(host)))
        }
    }

    public func refreshScript(_ script: Data) throws -> Bool {
        let local = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        let remote = (try? execute("sha256sum \"\(Self.scriptPath)\" 2>/dev/null | cut -d' ' -f1")) ?? ""
        if remote.trimmingCharacters(in: .whitespacesAndNewlines) == local { return false }
        try execute(
            "umask 077; mkdir -p \"$HOME/.local/share/relaybar\"; cat > \"\(Self.scriptPath)\"; chmod 700 \"\(Self.scriptPath)\"",
            stdin: script)
        return true
    }

    public func install(secrets: PoolSecrets, script: Data, progress: (String) -> Void) throws {
        let home = try remoteHome()
        let dir = home + "/.local/share/relaybar-helper"
        let scriptFile = home + "/.local/share/relaybar/relaybar-helper.sh"
        progress("Copying the helper installer to \(host)")
        _ = try refreshScript(script)
        try execute("umask 077; mkdir -p \"\(Self.helperDir)/auth\" \"$HOME/.config/systemd/user\"")
        progress("Writing the helper settings on \(host)")
        let config = PoolConfig.helperYAML(secrets: secrets, authDir: dir + "/auth")
        try execute("umask 077; cat > \"\(Self.helperDir)/config.yaml\"", stdin: Data(config.utf8))
        let join = try JSONSerialization.data(
            withJSONObject: ["accessKey": secrets.accessKey, "managementSecret": secrets.managementSecret], options: [.sortedKeys])
        try execute("umask 077; cat > \"\(Self.joinFile)\"", stdin: join)
        let units = [
            ("relaybar-helper.service", Self.helperUnit(dir: dir)),
            ("relaybar-helper-update.service", Self.updateUnit(script: scriptFile, dir: dir)),
            ("relaybar-helper-update.timer", Self.updateTimer),
        ]
        for (name, text) in units {
            try execute("umask 077; cat > \"$HOME/.config/systemd/user/\(name)\"", stdin: Data(text.utf8))
        }
        progress("Downloading and checking the helper on \(host)")
        let result = run(
            PoolSSH.command(
                host: host,
                script: Pool.scriptEnvironment.sorted { $0.key < $1.key }.map { "\($0.key)=\"\($0.value)\" " }.joined()
                    + "sh \"\(Self.scriptPath)\" install \"\(Self.helperDir)\"",
                limit: 900))
        guard result.succeeded else {
            let reason = result.error.split(separator: "\n").last.map(String.init) ?? "the download was refused."
            throw PoolInstallError.failed(reason.hasPrefix("failed: ") ? String(reason.dropFirst(8)) : reason)
        }
        try execute("systemctl --user daemon-reload && systemctl --user enable --now relaybar-helper-update.timer")
    }

    private static let keepProbe =
        "u=$(id -un); lingerNeeded=0; "
        + "[ \"$(loginctl show-user \"$u\" -p Linger --value 2>/dev/null)\" = yes ] || lingerNeeded=1; "
        + "todo=''; for t in \(sleepTargets); do [ \"$(systemctl is-enabled \"$t\" 2>/dev/null)\" = masked ] || todo=\"$todo $t\"; done; "

    public func keepOn(password: String? = nil) -> PoolKeepResult {
        let script: String
        if password == nil {
            script =
                Self.keepProbe
                + "if [ $lingerNeeded = 1 ]; then { loginctl enable-linger \"$u\" 2>/dev/null || sudo -n loginctl enable-linger \"$u\"; } "
                + "|| exit 1; echo changed:linger; fi; "
                + "if [ -n \"$todo\" ]; then sudo -n systemctl mask $todo || exit 1; for t in $todo; do echo changed:$t; done; fi"
        } else {
            script =
                Self.keepProbe
                + "sudo -S -p '' sh -c \"[ $lingerNeeded = 0 ] || loginctl enable-linger $u && { [ -z '$todo' ] || systemctl mask $todo; }\" "
                + "|| exit 1; [ $lingerNeeded = 0 ] || echo changed:linger; for t in $todo; do echo changed:$t; done"
        }
        let result = run(PoolSSH.command(host: host, script: script, stdin: password.map { Data(($0 + "\n").utf8) }))
        var changes = PoolKeepOn()
        for line in result.output.split(whereSeparator: \.isNewline) where line.hasPrefix("changed:") {
            let name = String(line.dropFirst(8))
            if name == "linger" { changes.linger = true } else if Self.sleepList.contains(name) { changes.masked.append(name) }
        }
        let sleep: PoolSleep? = result.succeeded ? .off : (password == nil ? .needsPassword : nil)
        return PoolKeepResult(sleep: sleep, changes: changes)
    }

    public static func restoreSleepCommand(host: String, keep: PoolKeepOn, password: String?) -> Command {
        var steps: [String] = []
        if !keep.masked.isEmpty { steps.append("systemctl unmask \(keep.masked.joined(separator: " "))") }
        if keep.linger { steps.append("loginctl disable-linger \"$u\"") }
        let fail = "|| exit \(needsPasswordStatus)"
        guard let password else {
            let list = steps.map { $0.hasPrefix("loginctl") ? "{ \($0) 2>/dev/null || sudo -n \($0); }" : "sudo -n \($0)" }
            return PoolSSH.command(
                host: host, script: "u=$(id -un); " + (list.isEmpty ? "true" : list.joined(separator: " && ")) + " " + fail)
        }
        let inner = steps.joined(separator: " && ").replacingOccurrences(of: "\"$u\"", with: "$u")
        return PoolSSH.command(
            host: host, script: "u=$(id -un); sudo -S -p '' sh -c \"\(inner.isEmpty ? "true" : inner)\" \(fail)",
            stdin: Data((password + "\n").utf8))
    }

    public static func helperUnit(dir: String) -> String {
        """
        [Unit]
        Description=Relaybar helper

        [Service]
        WorkingDirectory=\(dir)
        ExecStart=\(dir)/current/cli-proxy-api -config \(dir)/config.yaml
        Restart=always
        RestartSec=5
        StandardOutput=null
        StandardError=null
        NoNewPrivileges=yes
        PrivateTmp=yes
        ProtectSystem=strict
        ProtectHome=tmpfs
        BindPaths=\(dir)
        InaccessiblePaths=/run/user
        RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK
        ProtectKernelTunables=yes
        ProtectControlGroups=yes
        RestrictSUIDSGID=yes
        LockPersonality=yes

        [Install]
        WantedBy=default.target

        """
    }

    public static func updateUnit(script: String, dir: String) -> String {
        "[Unit]\nDescription=Relaybar helper update\n\n[Service]\nType=oneshot\nExecStart=/bin/sh \(script) update \(dir)\n"
    }

    public static let updateTimer =
        "[Unit]\nDescription=Relaybar helper nightly update\n\n[Timer]\nOnCalendar=*-*-* 04:00:00\nPersistent=true\nRandomizedDelaySec=30m\n\n[Install]\nWantedBy=timers.target\n"
}
