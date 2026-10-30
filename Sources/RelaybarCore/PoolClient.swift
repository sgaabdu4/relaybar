import Foundation

public enum PoolClientError: Error, Equatable, LocalizedError {
    case mac(String)
    case notLinux(String)
    case isTheHub(String)
    case hubIdentity(String)
    case noRoute(host: String, tried: [String], reason: String?)
    case t3Unreadable(String)
    case noKeyTool(String)
    case unsafeTunnel
    case missingTool(host: String, tool: String)
    case alreadyUsed(String)
    case installFailed(host: String, tool: String, reason: String)
    case needsPassword(host: String, why: String)
    case sudoFailed(host: String, reason: String)
    case rootStepFailed(host: String, why: String, reason: String)
    case t3NotReady(String)

    public var offersRetry: Bool {
        if case .noRoute = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .mac(let host): return "\(host) is a Mac. Open Relaybar on that Mac. It finds your accounts and connects in one click."
        case .notLinux(let host): return "\(host) is not a Linux computer. Relaybar can add Linux computers only for now."
        case .isTheHub(let host): return "\(host) is the computer that runs the helper. It already has your accounts."
        case .hubIdentity(let hub):
            return "Relaybar could not read the SSH identity of \(hub), so it cannot let another computer connect to it safely."
        case .noRoute(let host, let tried, let reason):
            let list =
                tried.isEmpty ? "The helper computer gave no home address to try." : "Relaybar tried " + tried.joined(separator: ", ") + "."
            guard let reason else {
                return
                    "\(host) could not reach the helper computer. \(list) Put both computers on the same network or on Tailscale, then try again."
            }
            return "\(host) could not reach the helper computer. \(list) \(reason)"
        case .t3Unreadable(let host):
            return
                "T3 Code's settings file on \(host) could not be read, so Relaybar did not change anything there. Fix or move ~/.t3/userdata/settings.json on \(host), then try again."
        case .noKeyTool(let host): return "\(host) cannot make an SSH key. Install the OpenSSH client there, then try again."
        case .missingTool(let host, let tool): return "\(host) needs \(tool). Install it, then try again."
        case .alreadyUsed(let host):
            return "\(host) already uses your accounts, set up from another Mac or under another name. Remove it there first."
        case .unsafeTunnel:
            return "A name or folder for the tunnel holds characters Relaybar cannot use safely, so it did not set up the tunnel."
        case .installFailed(let host, let tool, let reason):
            return
                "\(tool) could not be installed on \(host): \(reason) Check that \(host) can reach the internet, then try again."
        case .needsPassword(let host, let why):
            return
                "Relaybar needs the password for \(host) to \(why). It did not get it, so it removed what it had set up. Try again when you have it."
        case .sudoFailed(let host, let reason):
            return
                "\(host) did not allow that: \(reason) The user on \(host) needs administrator rights (sudo) for this step. Give it sudo, or untick the box, then try again."
        case .rootStepFailed(let host, let why, let reason):
            return "Relaybar could not \(why) on \(host): \(reason) Fix that, or untick the box, then try again."
        case .t3NotReady(let host):
            return
                "T3 Code was installed on \(host), but it did not start in time. Run systemctl --user status t3code on \(host) to see why, then try again."
        }
    }
}

public struct PoolClientRemoval: Equatable, Sendable {
    public var hubKeyProblem: String?
    public var lingerStays = false
    public var t3LinkStays = false
    public var keptBackups: [String] = []

    public init(hubKeyProblem: String? = nil, lingerStays: Bool = false, t3LinkStays: Bool = false, keptBackups: [String] = []) {
        self.keptBackups = keptBackups
        self.hubKeyProblem = hubKeyProblem
        self.lingerStays = lingerStays
        self.t3LinkStays = t3LinkStays
    }
}

struct PoolHubFacts: Equatable {
    var user: String
    var port: Int
    var addresses: [String]
    var tailscale: [String] = []
    var hostKeys: [String]

    static let script =
        "echo \"user=$(id -un)\"; echo \"port=$(echo \"$SSH_CONNECTION\" | awk '{print $4}')\"; "
        + "for a in $(hostname -I 2>/dev/null || ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/\\/.*/,\"\",$4); print $4}'); do echo \"addr=$a\"; done; "
        + "if command -v tailscale >/dev/null 2>&1; then tailscale ip -4 2>/dev/null | sed 's/^/ts=/'; fi; "
        + "k=/etc/ssh/ssh_host_ed25519_key.pub; if [ -r \"$k\" ]; then echo \"hostkey=$(cat \"$k\")\"; "
        + "else for k in /etc/ssh/ssh_host_*_key.pub; do [ -r \"$k\" ] && echo \"hostkey=$(cat \"$k\")\"; done; fi; true"

    static func parse(_ output: String) -> PoolHubFacts? {
        var user = ""
        var port = 22
        var plain: [String] = []
        var tailscale: [String] = []
        var keys: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let split = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<split])
            let value = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespaces)
            switch name {
            case "user": user = value
            case "port": if let number = Int(value), (1...65535).contains(number) { port = number }
            case "addr": if isAddress(value) { plain.append(value) }
            case "ts": if isAddress(value) { tailscale.append(value) }
            case "hostkey": if let key = hostKey(value) { keys.append(key) }
            default: break
            }
        }
        let name = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !user.isEmpty, !user.hasPrefix("-"), user.unicodeScalars.allSatisfy(name.contains), !keys.isEmpty else { return nil }
        let home = plain.filter { PoolHubPicker.isHomeAddress($0) }
        let carrier = home.filter { isCarrierGrade($0) }
        var addresses: [String] = []
        for address in home.filter({ !carrier.contains($0) }) + tailscale + carrier where !addresses.contains(address) {
            addresses.append(address)
        }
        return PoolHubFacts(user: user, port: port, addresses: addresses, tailscale: tailscale, hostKeys: keys)
    }

    private static func isAddress(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { $0.count <= 3 && Int($0).map { (0...255).contains($0) } == true }
    }

    private static func isCarrierGrade(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    private static func hostKey(_ line: String) -> String? {
        let words = line.split(separator: " ")
        guard words.count >= 2, words[0].hasPrefix("ssh-") || words[0].hasPrefix("ecdsa-sha2-"),
            words[1].allSatisfy({ $0.isLetter || $0.isNumber || "+/=".contains($0) })
        else { return nil }
        return "\(words[0]) \(words[1])"
    }

    func routes(worked: String) -> [String] {
        var ordered: [String] = []
        for address in tailscale + [worked] + addresses where !ordered.contains(address) { ordered.append(address) }
        return ordered
    }

    func knownHosts() -> String {
        addresses.flatMap { address in
            hostKeys.map { (port == 22 ? address : "[\(address)]:\(port)") + " " + $0 + "\n" }
        }.joined()
    }
}

extension PoolJoin {
    static let hubKeyOptions =
        "restrict,port-forwarding,permitopen=\"127.0.0.1:\(Pool.port)\",permitlisten=\"127.0.0.1:1\",command=\"/bin/false\""
    static let clientConfig = "$HOME/.config/relaybar"
    static let t3Settings = "$HOME/.t3/userdata/settings.json"

    public static func hubKeyTag(_ host: String) -> String { "relaybar-client:\(host)" }

    public static func hubKeyLine(publicKey: String, host: String) -> String {
        "\(hubKeyOptions) \(publicKey) \(hubKeyTag(host))"
    }

    static func dropTagged(_ host: String) -> String {
        "awk -v t=\(Shell.quote(" " + hubKeyTag(host))) '{ n = length($0); m = length(t); if (n >= m && substr($0, n - m + 1) == t) next; print }'"
    }

    public static func linuxClient(
        host: String, hub: String, hubLabel: String? = nil, accessKey: String, options: PoolAddOptions = PoolAddOptions(),
        hooks: PoolAddHooks = .none, run: @escaping CommandRunner, progress: (String) -> Void = { _ in },
        checkpoint: (PoolLinuxClient?) -> Void = { _ in }
    ) async throws -> PoolAddResult {
        let remote = PoolRemote(host: host, run: run)
        let hubName = try PoolHubPicker.validate(hub)
        let hubRemote = PoolRemote(host: hubName, run: run)
        let label = hubLabel ?? hubName
        let system = try operatingSystem(remote)
        if system == "Darwin" { throw PoolClientError.mac(host) }
        guard system == "Linux" else { throw PoolClientError.notLinux(host) }
        let home = try remote.remoteHome()
        let marker = PoolFile.marker
        let probe = try remote.execute(
            "for d in \(clientFolders.joined(separator: " ")); do [ -e \"$HOME/$d\" ] || echo new:$d; done; "
                + "for f in \(clientCommands.joined(separator: " ")); do p=\"$HOME/.local/bin/$f\"; "
                + "if [ -e \"$p\" ] && ! grep -q '\(marker)' \"$p\" 2>/dev/null; then echo foreign:$f; fi; done; "
                + "[ \"$(loginctl show-user \"$(id -un)\" -p Linger --value 2>/dev/null)\" = yes ] || echo linger:off; "
                + "test -e \"\(PoolRemote.joinFile)\" && echo hub:yes; test -e \"\(clientConfig)/hub_key\" && echo key:yes; "
                + "for t in curl ssh ssh-keygen systemctl; do command -v \"$t\" >/dev/null 2>&1 || echo missing:$t; done; echo \"ssh:$(command -v ssh)\"; "
                + "c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:\(Pool.port)/v1/models 2>/dev/null); "
                + "if [ -n \"$c\" ] && [ \"$c\" != 000 ]; then if ! { systemctl --user is-active --quiet relaybar-tunnel.service 2>/dev/null "
                + "&& grep -q relaybar/hub_key \"$HOME/.config/systemd/user/relaybar-tunnel.service\" 2>/dev/null; }; then echo port:busy; fi; fi; "
                + "if [ -f \"\(t3Settings)\" ]; then echo t3:yes; [ -d \"$HOME/.t3/userdata/secrets\" ] || echo t3secrets:new; fi; "
                + probeTools + "true")
        let lines = probe.split(whereSeparator: \.isNewline).map(String.init)
        if let foreign = lines.first(where: { $0.hasPrefix("foreign:") }) {
            throw PoolFileError.notRelaybars("\(host):.local/bin/\(foreign.dropFirst(8))")
        }
        if lines.contains("hub:yes") { throw PoolClientError.isTheHub(host) }
        if let missing = lines.first(where: { $0.hasPrefix("missing:") }) {
            throw PoolClientError.missingTool(host: host, tool: String(missing.dropFirst(8)))
        }
        if lines.contains("key:yes") { throw PoolClientError.alreadyUsed(host) }
        if lines.contains("port:busy") { throw PoolSetupError.conflict(.portInUse(Pool.port)) }
        var hasT3 = lines.contains("t3:yes")
        let facts = try hubFacts(hubRemote)
        if hasT3 { try withT3 { t3 in _ = try pullT3(remote, into: t3) } }

        let found = PoolClientProbe(lines: lines)
        let installT3 = options.t3Channel != nil && found.t3Path == nil && !found.t3Running
        let pairable = options.t3Channel != nil && (installT3 || (found.t3Running && found.t3Path != nil))
        let replace = try await decideReplace(remote, lines: lines, hooks: hooks, progress: progress)
        var stages: [PoolAddStage] = [.letIn]
        if !found.missing.isEmpty { stages.append(.tools) }
        if options.tailscale { stages.append(.tailscale) }
        stages += [.route, .commands]
        if replace { stages.append(.logins) }
        if installT3 { stages.append(.t3) }
        if pairable { stages.append(.link) }
        hooks.plan(stages)
        let report = hooks.report
        let session = PoolPasswordSession(host: host, run: run, ask: hooks.password)
        defer { session.forget() }

        var client = PoolLinuxClient(host: host, folders: lines.filter { $0.hasPrefix("new:") }.map { String($0.dropFirst(4)) })
        client.t3SecretsFolder = lines.contains("t3secrets:new")
        checkpoint(client)
        var result = PoolAddResult(client: client)
        do {
            report(.letIn, .working)
            progress("Making a key on \(host)")
            let key = home + "/.config/relaybar/hub_key"
            let knownHosts = home + "/.config/relaybar/known_hosts"
            let made = try remote.execute(
                "command -v ssh-keygen >/dev/null 2>&1 || { echo nokeygen; exit 0; }; "
                    + "umask 077; mkdir -p \"\(clientConfig)\" \"$HOME/.config/systemd/user\" && rm -f \"\(clientConfig)/hub_key\" \"\(clientConfig)/hub_key.pub\" "
                    + "&& ssh-keygen -q -t ed25519 -N '' -C relaybar -f \"\(clientConfig)/hub_key\" && cut -d' ' -f1,2 \"\(clientConfig)/hub_key.pub\""
            )
            guard let publicKey = made.split(whereSeparator: \.isNewline).map(String.init).first(where: { $0.hasPrefix("ssh-ed25519 ") }),
                publicKey.dropFirst(12).allSatisfy({ $0.isLetter || $0.isNumber || "+/=".contains($0) })
            else { throw PoolClientError.noKeyTool(host) }

            progress("Letting \(host) in on \(label)")
            client.hubKey = true
            checkpoint(client)
            let created = try hubRemote.execute(
                "d=\"$HOME/.ssh\"; f=\"$d/authorized_keys\"; umask 077; "
                    + "if [ -L \"$f\" ]; then echo link; exit 0; fi; "
                    + "[ -d \"$d\" ] || { mkdir -m 700 \"$d\" || exit 1; echo created:ssh; }; "
                    + "if [ -e \"$f\" ]; then [ -e \"$f.relaybar-backup\" ] || cp -p \"$f\" \"$f.relaybar-backup\" || exit 1; "
                    + "tmp=$(mktemp \"$d/.relaybar.XXXXXX\") || exit 1; \(dropTagged(host)) \"$f\" > \"$tmp\" && { cmp -s \"$tmp\" \"$f\" || cat \"$tmp\" > \"$f\"; }; "
                    + "r=$?; rm -f \"$tmp\"; [ $r = 0 ] || exit 1; "
                    + "else : > \"$f\" && chmod 600 \"$f\" && echo created:keys || exit 1; fi; cat >> \"$f\"",
                stdin: Data((hubKeyLine(publicKey: publicKey, host: host) + "\n").utf8))
            if created.split(whereSeparator: \.isNewline).contains("link") { throw PoolFileError.link("\(label):.ssh/authorized_keys") }
            client.hubCreated = created.split(whereSeparator: \.isNewline).map(String.init).filter { $0.hasPrefix("created:") }.map {
                String($0.dropFirst(8))
            }
            checkpoint(client)
            report(.letIn, .done)

            var local = Set(["claude", "codex"].filter(found.inLocalBin))
            func binary(_ tool: String) -> String? { local.contains(tool) ? "$HOME/.local/bin/\(tool)" : elsewhere[tool] }
            var elsewhere = Dictionary(
                uniqueKeysWithValues: ["claude", "codex"].compactMap { tool in found.fullPath(tool).map { (tool, $0) } })
            if !found.missing.isEmpty {
                report(.tools, .working)
                for tool in found.missing {
                    if tool == "claude" {
                        progress("Installing Claude Code on \(host)")
                        client.claudeInstalled = true
                        checkpoint(client)
                        try install(remote, site: .claude, interpreter: "bash", tool: "claude", name: "Claude Code")
                    } else {
                        progress("Installing Codex on \(host)")
                        client.codexInstalled = true
                        client.codexProfile = !found.has("profile:codex")
                        client.codexFolder = found.has("codexdir:new")
                        checkpoint(client)
                        try install(
                            remote, site: .codex, interpreter: "sh", variable: "CODEX_NON_INTERACTIVE=1", tool: "codex", name: "Codex")
                    }
                    local.insert(tool)
                    elsewhere[tool] = nil
                }
                report(.tools, .done)
            }

            var tailscaleAddress: String?
            if options.tailscale {
                report(.tailscale, .working)
                progress("Setting up Tailscale on \(host)")
                tailscaleAddress = try await setUpTailscale(
                    remote, client: &client, session: session, hooks: hooks, checkpoint: checkpoint)
                report(.tailscale, .done)
            }

            report(.route, .working)
            try remote.execute(
                "umask 077; cat > \"\(clientConfig)/known_hosts\"", stdin: Data(facts.knownHosts().utf8))
            progress("Finding the way from \(host) to \(label)")
            let address = try chooseAddress(remote, hub: label, facts: facts, key: key, knownHosts: knownHosts)
            report(.route, .done)

            report(.commands, .working)
            progress(replace ? "Saving the key on \(host)" : "Setting up claude+ and codex+ on \(host)")
            let keyFile = "\(clientConfig)/access-key"
            try remote.execute("umask 077; cat > \"\(keyFile)\"", stdin: Data(accessKey.utf8))
            if !replace {
                try remote.execute("mkdir -p \"$HOME/.local/bin\"")
                let launchers = [
                    ("claude+", PoolConfig.claudePlus(keyCommand: "cat \"\(keyFile)\"", binary: binary("claude"))),
                    (
                        "codex+",
                        PoolConfig.codexPlus(keyCommand: ["/bin/cat", home + "/.config/relaybar/access-key"], binary: binary("codex"))
                    ),
                ]
                for (name, text) in launchers {
                    try remote.execute(
                        "cat > \"$HOME/.local/bin/\(name)\"; chmod 755 \"$HOME/.local/bin/\(name)\"", stdin: Data(text.utf8))
                }
            }
            let unit = try PoolTunnel.linuxUnit(
                user: facts.user, addresses: facts.routes(worked: address), key: key, knownHosts: knownHosts, port: facts.port,
                ssh: sshPath(lines))
            try remote.execute("cat > \"$HOME/.config/systemd/user/relaybar-tunnel.service\"", stdin: Data(unit.utf8))
            if lines.contains("linger:off") {
                let enabled = try remote.execute(
                    "u=$(id -un); { loginctl enable-linger \"$u\" 2>/dev/null || sudo -n loginctl enable-linger \"$u\" 2>/dev/null; } "
                        + "&& echo changed:linger; true")
                client.linger = enabled.contains("changed:linger")
                checkpoint(client)
            }
            try remote.execute(
                "systemctl --user daemon-reload && systemctl --user enable relaybar-tunnel.service && systemctl --user restart relaybar-tunnel.service"
            )
            let answer = try remote.execute(
                "i=0; while [ $i -lt 15 ]; do c=$(printf 'header = \"Authorization: Bearer %s\"\\n' \"$(cat \"\(keyFile)\")\" "
                    + "| curl -s -o /dev/null -w '%{http_code}' --max-time 2 -K - http://127.0.0.1:\(Pool.port)/v1/models); "
                    + "if [ \"$c\" = 200 ] && systemctl --user is-active --quiet relaybar-tunnel.service; then echo up; exit 0; fi; "
                    + "sleep 1; i=$((i+1)); done; echo down")
            guard answer.trimmingCharacters(in: .whitespacesAndNewlines) == "up" else {
                throw PoolSSHError.failed(
                    "\(host) reached \(label), but the helper did not answer there. Check that the helper is running, then try again.")
            }
            report(.commands, .done)

            if replace {
                report(.logins, .working)
                progress("Switching Claude Code and Codex on \(host) to your accounts")
                try replaceLogins(remote, home: home, lines: lines, client: &client, checkpoint: checkpoint)
                result.replaced = true
                report(.logins, .done)
            }

            var t3 = found.t3Path
            if installT3, let channel = options.t3Channel {
                report(.t3, .working)
                progress("Installing T3 Code on \(host)")
                client.t3Installed = true
                checkpoint(client)
                try install(
                    remote, site: .t3, interpreter: "sh", variable: "T3CODE_CHANNEL=\(channel.rawValue)", tool: "t3", name: "T3 Code")
                t3 = "$HOME/.local/bin/t3"
                if lines.contains("linger:off"), !client.linger {
                    _ = try await session.run(
                        "loginctl enable-linger \"$SUDO_USER\"", why: "keep T3 Code running after you log out")
                    client.linger = true
                    checkpoint(client)
                }
                client.t3Service = true
                checkpoint(client)
                try remote.execute("\"$HOME/.local/bin/t3\" service install </dev/null", limit: 300)
                try waitForT3(remote)
                hasT3 = true
            }
            if hasT3, !replace {
                progress("Adding the entries to T3 Code on \(host)")
                try addT3Entries(
                    remote, home: home, accessKey: accessKey, client: &client, checkpoint: checkpoint,
                    claudeBinary: local.contains("claude") ? home + "/.local/bin/claude" : elsewhere["claude"],
                    codexBinary: home + "/.local/bin/codex+", orEmpty: installT3,
                    model: options.t3Model)
            }
            if installT3 {
                let computer = PoolTailscaleComputer(host: host, run: run, pause: hooks.pause)
                if let tailscaleAddress, let user = computer.user(), computer.reaches("\(user)@\(tailscaleAddress)") {
                    progress("Limiting T3 Code on \(host) to Tailscale")
                    client.t3Host = tailscaleAddress
                    checkpoint(client)
                    try setT3Host(remote, address: tailscaleAddress)
                    try keepT3Retrying(remote)
                    try remote.execute("\"$HOME/.local/bin/t3\" service restart </dev/null", limit: 120)
                    try waitForT3(remote, address: tailscaleAddress)
                    result.listening = .tailscale
                } else {
                    result.listening = .homeNetwork
                    if options.tailscale { result.notes.append(.tailscaleUnreachable) }
                }
                report(.t3, .done)
            }
            if options.t3Channel != nil, !installT3 {
                if found.t3Path == nil {
                    result.notes.append(.t3NotFound)
                    progress("T3 Code is already running on \(host), but Relaybar could not find it to link it")
                } else if !found.t3Running {
                    result.notes.append(.t3NotRunning)
                } else if options.tailscale {
                    result.notes.append(.t3Kept)
                }
            }
            if pairable, let t3 {
                report(.link, .working)
                progress("Linking T3 Code on \(host) to this Mac")
                switch try await pair(remote, t3: t3, hooks: hooks) {
                case .linked(let session):
                    result.link = .linked
                    if let session {
                        client.t3Session = session
                        client.t3Binary = installT3 ? nil : t3
                        checkpoint(client)
                    }
                    report(.link, .done)
                case .notLinked:
                    result.link = .notLinked
                    report(.link, .problem("Not linked"))
                }
            }
        } catch {
            if let removal = try? removeLinuxClient(client, hubRoutes: [hubName], run: run), removal.hubKeyProblem == nil {
                checkpoint(nil)
            }
            throw error
        }
        result.client = client
        return result
    }

    private static func setUpTailscale(
        _ remote: PoolRemote, client: inout PoolLinuxClient, session: PoolPasswordSession, hooks: PoolAddHooks,
        checkpoint: (PoolLinuxClient?) -> Void
    ) async throws -> String? {
        let computer = PoolTailscaleComputer(host: remote.host, run: remote.run, pause: hooks.pause)
        let found = try computer.facts()
        if found.running { return found.address }
        client.tailscaleInstalled = !found.installed
        checkpoint(client)
        let report = hooks.report
        let opened = try await computer.bringUp(
            found: found,
            privileged: { [why = found.installed ? "start Tailscale" : "install Tailscale"] in
                try await session.run($0, why: why, limit: $1)
            },
            onLink: { link in
                hooks.signIn(link)
                report(.tailscale, .yourTurn)
            })
        return opened.address
    }

    static func hubFacts(_ hub: PoolRemote) throws -> PoolHubFacts {
        guard let facts = PoolHubFacts.parse(try hub.execute(PoolHubFacts.script)) else { throw PoolClientError.hubIdentity(hub.host) }
        return facts
    }

    private static func routeReason(_ error: String, hub: String, client: String) -> String {
        if error.contains("Permission denied") {
            return "\(hub) refused the key of \(client). Check that SSH on \(hub) reads ~/.ssh/authorized_keys, then try again."
        }
        return PoolHubPicker.explain(error, host: hub)
    }

    private static func operatingSystem(_ remote: PoolRemote) throws -> String {
        let result = remote.run(PoolSSH.command(host: remote.host, script: "uname -s"))
        if [255, CommandResult.timedOut].contains(result.status) {
            throw PoolSSHError.failed(PoolHubPicker.explain(result.error, host: remote.host))
        }
        return result.succeeded ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private static func sshPath(_ lines: [String]) -> String {
        let found = lines.first(where: { $0.hasPrefix("ssh:") }).map { String($0.dropFirst(4)) } ?? ""
        return found.hasPrefix("/") ? found : "/usr/bin/ssh"
    }

    private static func chooseAddress(_ remote: PoolRemote, hub: String, facts: PoolHubFacts, key: String, knownHosts: String) throws
        -> String
    {
        let options = PoolTunnel.pinnedOptions(key: key, knownHosts: knownHosts, port: facts.port).map(Shell.quote).joined(separator: " ")
        let answer = try remote.execute(
            "e=''; p=''; for a in \(facts.addresses.joined(separator: " ")); do "
                + "e=$(ssh \(options) -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR \"\(facts.user)@$a\" true </dev/null 2>&1 >/dev/null); "
                + "r=$?; [ $r -eq 1 ] && { echo ok:$a; exit 0; }; case \"$e\" in *'Permission denied'*) p=$e;; esac; done; "
                + "[ -n \"$p\" ] && e=$p; echo none; echo \"err:$(printf %s \"$e\" | tail -n 1)\"",
            limit: TimeInterval(facts.addresses.count * 8 + 20))
        let lines = answer.split(whereSeparator: \.isNewline)
        guard let line = lines.first(where: { $0.hasPrefix("ok:") }), facts.addresses.contains(String(line.dropFirst(3))) else {
            let last = lines.first(where: { $0.hasPrefix("err:") }).map { String($0.dropFirst(4)) } ?? ""
            throw PoolClientError.noRoute(
                host: remote.host, tried: facts.addresses, reason: last.isEmpty ? nil : routeReason(last, hub: hub, client: remote.host))
        }
        return String(line.dropFirst(3))
    }

    private static func withT3<T>(_ body: (T3Settings) throws -> T) throws -> T {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("relaybar-t3-" + UUID().uuidString)
        try PoolFile.makeFolder(folder, secret: true)
        defer { PoolFile.remove(folder) }
        return try body(T3Settings(home: folder))
    }

    private static func pullT3(_ remote: PoolRemote, into t3: T3Settings, orEmpty: Bool = false) throws -> Bool {
        let text = try remote.execute("f=\"\(t3Settings)\"; [ -f \"$f\" ] && cat \"$f\"; true")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return orEmpty }
        try PoolFile.write(Data(text.utf8), to: t3.settings, secret: true, backup: false)
        do { try t3.validate() } catch { throw PoolClientError.t3Unreadable(remote.host) }
        return true
    }

    private static func pushT3(_ remote: PoolRemote, settings: Data) throws {
        try remote.execute(
            "f=\"\(t3Settings)\"; t=\"$f.relaybar-new\"; if [ -e \"$f\" ]; then "
                + "[ -e \"$f.relaybar-backup\" ] || cp -p \"$f\" \"$f.relaybar-backup\" || exit 1; cp -p \"$f\" \"$t\" || exit 1; fi; "
                + "cat > \"$t\" && mv \"$t\" \"$f\" || { rm -f \"$t\"; exit 1; }",
            stdin: settings)
    }

    private static func addT3Entries(
        _ remote: PoolRemote, home: String, accessKey: String, client: inout PoolLinuxClient, checkpoint: (PoolLinuxClient?) -> Void,
        claudeBinary: String?, codexBinary: String?, orEmpty: Bool, model: String?
    ) throws {
        try withT3 { t3 in
            guard try pullT3(remote, into: t3, orEmpty: orEmpty) else { return }
            client.t3Entries = true
            checkpoint(client)
            try t3.addPoolEntries(
                accessKey: accessKey, hex: PoolSetup.combinedColor, claudeBinary: claudeBinary, codexBinary: codexBinary)
            if case .set(let previous) = try t3.setPoolDefault(fallbackModel: model) {
                client.t3DefaultSet = true
                client.previousSelection = previous
            }
            let folder = t3.secretFile("x").deletingLastPathComponent()
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".bin") }.sorted()
            client.t3Secrets = files.map { String($0.dropLast(4)) }
            checkpoint(client)
            for file in files {
                let name = String(file.dropLast(4))
                guard isSafeName(name) else { throw PoolClientError.t3Unreadable(remote.host) }
                try remote.execute(
                    "umask 077; mkdir -p \"$HOME/.t3/userdata/secrets\" && cat > \"$HOME/.t3/userdata/secrets/\(name).bin\"",
                    stdin: try Data(contentsOf: folder.appendingPathComponent(file)))
            }
            try pushT3(remote, settings: try Data(contentsOf: t3.settings))
        }
    }

    private static func removeT3Entries(_ remote: PoolRemote, client: PoolLinuxClient) throws {
        try withT3 { t3 in
            if try pullT3(remote, into: t3) {
                let before = try Data(contentsOf: t3.settings)
                if client.t3DefaultSet { try t3.restoreDefault(to: client.previousSelection) }
                try t3.removePoolEntries()
                let after = try Data(contentsOf: t3.settings)
                if after != before { try pushT3(remote, settings: after) }
            }
        }
        let names = client.t3Secrets.filter(isSafeName)
        guard !names.isEmpty else { return }
        let files = names.map { "\"$HOME/.t3/userdata/secrets/\($0).bin\"" }.joined(separator: " ")
        try remote.execute(
            "rm -f \(files); " + (client.t3SecretsFolder ? "rmdir \"$HOME/.t3/userdata/secrets\" 2>/dev/null; " : "") + "true")
    }

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    static func removeHubKey(_ client: PoolLinuxClient, routes: [String], run: @escaping CommandRunner) throws {
        let script =
            "d=\"$HOME/.ssh\"; f=\"$d/authorized_keys\"; if [ -e \"$f\" ] && [ ! -L \"$f\" ]; then umask 077; tmp=$(mktemp \"$d/.relaybar.XXXXXX\") || exit 1; "
            + "\(dropTagged(client.host)) \"$f\" > \"$tmp\" && { cmp -s \"$tmp\" \"$f\" || cat \"$tmp\" > \"$f\"; }; r=$?; rm -f \"$tmp\"; [ $r = 0 ] || exit 1; "
            + (client.hubCreated.contains("keys") ? "[ -s \"$f\" ] || rm -f \"$f\"; " : "") + "fi; "
            + (client.hubCreated.contains("ssh") ? "rmdir \"$d\" 2>/dev/null; " : "") + "true"
        guard !routes.isEmpty else {
            throw PoolSSHError.failed("Relaybar does not know how to reach the home computer, so it cannot remove the key there.")
        }
        var first: CommandResult?
        for route in routes {
            let result = run(PoolSSH.command(host: route, script: script))
            if result.succeeded { return }
            first = first ?? result
        }
        throw PoolSSHError.failed(PoolHubPicker.explain(first?.error ?? "", host: routes.first ?? ""))
    }

    @discardableResult
    public static func removeLinuxClient(_ client: PoolLinuxClient, hubRoutes: [String] = [], run: @escaping CommandRunner) throws
        -> PoolClientRemoval
    {
        var removal = forgetLinuxClient(client, hubRoutes: hubRoutes, run: run)
        var problem: Error?
        let remote = PoolRemote(host: client.host, run: run)
        if client.t3Entries {
            do { try removeT3Entries(remote, client: client) } catch { problem = error }
        }
        removal.t3LinkStays = !revokeT3Link(remote, client: client)
        do { try removeT3(remote, client: client) } catch { problem = problem ?? error }
        let config = clientConfig
        do { removal.keptBackups = try restoreLogins(remote, client: client) } catch { problem = problem ?? error }
        var steps = ["systemctl --user disable --now relaybar-tunnel.service >/dev/null 2>&1"]
        steps += [
            "rm -f \"$HOME/.config/systemd/user/relaybar-tunnel.service\" \"\(config)/access-key\" \"\(config)/hub_key\" \"\(config)/hub_key.pub\" \"\(config)/known_hosts\"",
            "f=\"$HOME/.codex-hub/config.toml\"; grep -q '\(PoolFile.marker)' \"$f\" 2>/dev/null && rm -f \"$f\"",
            "for f in \((clientCommands + legacyClientCommands).joined(separator: " ")); do p=\"$HOME/.local/bin/$f\"; grep -q '\(PoolFile.marker)' \"$p\" 2>/dev/null && rm -f \"$p\"; done",
            "systemctl --user daemon-reload >/dev/null 2>&1",
        ]
        steps += removeInstalls(client)
        for folder in client.folders where (clientFolders + legacyClientFolders).contains(folder) {
            steps.append("rmdir \"$HOME/\(folder)\" 2>/dev/null")
        }
        if client.linger {
            steps.append(
                "u=$(id -un); { loginctl disable-linger \"$u\" 2>/dev/null || sudo -n loginctl disable-linger \"$u\" 2>/dev/null; }; "
                    + "[ \"$(loginctl show-user \"$u\" -p Linger --value 2>/dev/null)\" = yes ] && echo linger:stays")
        }
        let result = run(PoolSSH.command(host: client.host, script: steps.joined(separator: "; ") + "; true"))
        if !result.succeeded { problem = problem ?? PoolSSHError.failed(PoolHubPicker.explain(result.error, host: client.host)) }
        if let problem { throw problem }
        removal.lingerStays = result.output.contains("linger:stays")
        return removal
    }

    public static func forgetLinuxClient(_ client: PoolLinuxClient, hubRoutes: [String], run: @escaping CommandRunner)
        -> PoolClientRemoval
    {
        var removal = PoolClientRemoval()
        if client.hubKey {
            do { try removeHubKey(client, routes: hubRoutes, run: run) } catch { removal.hubKeyProblem = error.localizedDescription }
        }
        return removal
    }
}
