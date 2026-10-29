import Foundation

public enum PoolInstallSite: String, CaseIterable, Sendable {
    case claude
    case codex
    case t3

    public var address: String {
        switch self {
        case .claude: "https://claude.ai/install.sh"
        case .codex: "https://chatgpt.com/codex/install.sh"
        case .t3: "https://t3.codes/install.sh"
        }
    }

    public var url: String { Pool.overriddenURL("RELAYBAR_\(rawValue.uppercased())_INSTALL_URL") ?? address }
}

public enum T3Channel: String, CaseIterable, Sendable {
    case stable
    case nightly
    case preview

    public static func detect(version: String) -> T3Channel {
        if version.contains("-nightly.") { return .nightly }
        if version.contains("-preview.") { return .preview }
        return .stable
    }
}

public struct PoolAddOptions: Equatable, Sendable {
    public var t3Channel: T3Channel?
    public var tailscale: Bool

    public init(t3Channel: T3Channel? = nil, tailscale: Bool = false) {
        self.t3Channel = t3Channel
        self.tailscale = tailscale
    }
}

public enum PoolAddStage: Int, CaseIterable, Sendable {
    case letIn
    case tools
    case tailscale
    case route
    case commands
    case t3
    case link
}

public struct PoolAddHooks: Sendable {
    public var plan: @Sendable ([PoolAddStage]) -> Void
    public var report: @Sendable (PoolAddStage, PoolStageState) -> Void
    public var password: @Sendable (Bool, String) async -> String?
    public var signIn: @Sendable (URL) -> Void
    public var pair: @Sendable (URL) -> Void
    public var linkFailed: @Sendable (String) async -> Bool
    public var pause: @Sendable (TimeInterval) async -> Void

    public init(
        plan: @escaping @Sendable ([PoolAddStage]) -> Void = { _ in },
        report: @escaping @Sendable (PoolAddStage, PoolStageState) -> Void = { _, _ in },
        password: @escaping @Sendable (Bool, String) async -> String? = { _, _ in nil },
        signIn: @escaping @Sendable (URL) -> Void = { _ in },
        pair: @escaping @Sendable (URL) -> Void = { _ in },
        linkFailed: @escaping @Sendable (String) async -> Bool = { _ in false },
        pause: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.plan = plan
        self.report = report
        self.password = password
        self.signIn = signIn
        self.pair = pair
        self.linkFailed = linkFailed
        self.pause = pause
    }

    public static let none = PoolAddHooks()
}

struct PoolClientProbe {
    let lines: [String]

    func has(_ line: String) -> Bool { lines.contains(line) }

    var missing: [String] { ["claude", "codex"].filter { has("need:\($0)") } }

    func inLocalBin(_ tool: String) -> Bool { has("bin:\(tool)") }

    var t3Path: String? { path(after: "t3path:") ?? path(after: "t3exec:") }

    var t3Running: Bool { has("t3svc:yes") }

    private func path(after prefix: String) -> String? {
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let path = String(line.dropFirst(prefix.count))
        let safe = path.hasPrefix("/") && path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-+".contains($0)) }
        return safe ? path : nil
    }
}

extension PoolJoin {
    static let probeTools =
        "for t in claude codex; do p=$(PATH=\"$HOME/.local/bin:$PATH\" command -v $t 2>/dev/null); "
        + "[ -n \"$p\" ] || p=$(\"${SHELL:-sh}\" -lc \"command -v $t\" </dev/null 2>/dev/null | grep '^/' | tail -n 1); "
        + "if [ -z \"$p\" ]; then echo need:$t; elif [ \"$p\" = \"$HOME/.local/bin/$t\" ]; then echo bin:$t; fi; done; "
        + "p=$(PATH=\"$HOME/.local/bin:$PATH\" command -v t3 2>/dev/null); [ -n \"$p\" ] && echo t3path:$p; "
        + "systemctl --user is-active --quiet t3code.service 2>/dev/null && echo t3svc:yes; "
        + "systemctl --user show t3code.service -p ExecStart 2>/dev/null | sed -n 's/^ExecStart={ path=\\([^ ;]*\\) ;.*/t3exec:\\1/p'; "
        + "for f in .profile .bashrc .zshrc .zprofile; do grep -q '>>> Codex installer >>>' \"$HOME/$f\" 2>/dev/null && echo profile:codex; done; "
        + "[ -e \"$HOME/.codex\" ] || echo codexdir:new; "

    static let t3Runtime = "$HOME/.t3/userdata/server-runtime.json"
    static let t3Unit = "$HOME/.config/systemd/user/t3code.service"
    static let t3Env = "$HOME/.t3/service.env"

    static func installScript(site: PoolInstallSite, interpreter: String, variable: String?, tool: String) -> String {
        let prefix = variable.map { $0 + " " } ?? ""
        return "f=$(mktemp) || exit 1; curl -fsSL \(Shell.quote(site.url)) -o \"$f\" && "
            + "\(prefix)\(interpreter) \"$f\" </dev/null; r=$?; rm -f \"$f\"; "
            + "[ $r = 0 ] || exit $r; [ -x \"$HOME/.local/bin/\(tool)\" ] || { echo \"it did not make ~/.local/bin/\(tool)\" >&2; exit 3; }"
    }

    static func install(
        _ remote: PoolRemote, site: PoolInstallSite, interpreter: String, variable: String? = nil, tool: String, name: String
    ) throws {
        let result = remote.run(
            PoolSSH.command(
                host: remote.host, script: installScript(site: site, interpreter: interpreter, variable: variable, tool: tool),
                limit: 900))
        guard !result.succeeded else { return }
        if [255, CommandResult.timedOut].contains(result.status) {
            throw PoolSSHError.failed(PoolHubPicker.explain(result.error, host: remote.host))
        }
        let reason = String((result.error.split(whereSeparator: \.isNewline).last ?? "it gave no reason").prefix(160))
        throw PoolClientError.installFailed(host: remote.host, tool: name, reason: reason)
    }

    static func waitForT3(_ remote: PoolRemote, address: String? = nil) throws {
        let host = address.map { " && grep -q '\"host\":\"\($0)\"' \"\(t3Runtime)\"" } ?? ""
        let answer = try remote.execute(
            "i=0; while [ $i -lt 60 ]; do if systemctl --user is-active --quiet t3code.service && [ \"\(t3Runtime)\" -nt \"\(t3Unit)\" ]\(host); "
                + "then echo ready; exit 0; fi; sleep 1; i=$((i+1)); done; echo notready",
            limit: 90)
        guard answer.trimmingCharacters(in: .whitespacesAndNewlines) == "ready" else { throw PoolClientError.t3NotReady(remote.host) }
    }

    static let t3Retry = "$HOME/.config/systemd/user/t3code.service.d/relaybar.conf"

    static func keepT3Retrying(_ remote: PoolRemote) throws {
        let answer = try remote.execute(
            "f=\"\(t3Retry)\"; d=$(dirname \"$f\"); if [ -L \"$d\" ] || [ -L \"$f\" ]; then echo link; exit 0; fi; "
                + "mkdir -p \"$d\" && printf '[Unit]\\nStartLimitIntervalSec=0\\n' > \"$f\" && systemctl --user daemon-reload")
        if answer.contains("link") { throw PoolFileError.link("\(remote.host):.config/systemd/user/t3code.service.d") }
    }

    static func setT3Host(_ remote: PoolRemote, address: String) throws {
        let answer = try remote.execute(
            "f=\"\(t3Env)\"; if [ -L \"$f\" ]; then echo link; exit 0; fi; mkdir -p \"$HOME/.t3\"; t=$(mktemp) || exit 1; "
                + "{ [ -f \"$f\" ] && grep -v '^T3CODE_HOST=' \"$f\"; printf 'T3CODE_HOST=%s\\n' \(Shell.quote(address)); } > \"$t\"; "
                + "cat \"$t\" > \"$f\"; r=$?; rm -f \"$t\"; exit $r")
        if answer.contains("link") { throw PoolFileError.link("\(remote.host):.t3/service.env") }
    }

    public static func pairLink(in output: String) -> URL? {
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("App link: ") else { continue }
            let word = text.dropFirst(10).trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: word), isPairLink(url) else { continue }
            return url
        }
        return nil
    }

    public static func isPairLink(_ url: URL) -> Bool {
        url.scheme == "t3code" && url.host == "pair"
    }

    static func pair(_ remote: PoolRemote, t3: String, hooks: PoolAddHooks) async throws -> Bool {
        while true {
            let result = remote.run(PoolSSH.command(host: remote.host, script: "\"\(t3)\" pair --label Relaybar </dev/null", limit: 60))
            if [255, CommandResult.timedOut].contains(result.status) {
                throw PoolSSHError.failed(PoolHubPicker.explain(result.error, host: remote.host))
            }
            if result.succeeded, let url = pairLink(in: result.output) {
                hooks.pair(url)
                return true
            }
            guard await hooks.linkFailed(remote.host) else { return false }
        }
    }

    static func removeInstalls(_ client: PoolLinuxClient) -> [String] {
        var steps: [String] = []
        if client.claudeInstalled {
            steps.append("rm -f \"$HOME/.local/bin/claude\"; rm -rf \"$HOME/.local/share/claude\"")
        }
        if client.codexInstalled {
            steps.append(
                "p=\"$HOME/.local/bin/codex\"; if [ -L \"$p\" ]; then case \"$(readlink \"$p\")\" in */.codex/packages/standalone/*) rm -f \"$p\";; esac; fi; "
                    + "rm -rf \"$HOME/.codex/packages/standalone\"; rmdir \"$HOME/.codex/packages\" 2>/dev/null")
            if client.codexFolder { steps.append("rm -rf \"$HOME/.codex/tmp\"; rmdir \"$HOME/.codex\" 2>/dev/null") }
            if client.codexProfile {
                steps.append(
                    "for n in .profile .bashrc .zshrc .zprofile; do f=\"$HOME/$n\"; if [ -f \"$f\" ] && [ ! -L \"$f\" ] && grep -q '>>> Codex installer >>>' \"$f\"; then "
                        + "t=$(mktemp) && awk '/^# >>> Codex installer >>>$/ { skip = 1; next } /^# <<< Codex installer <<<$/ { skip = 0; next } !skip { print }' \"$f\" > \"$t\" "
                        + "&& cat \"$t\" > \"$f\"; rm -f \"$t\"; fi; done")
            }
        }
        return steps
    }

    static func removeT3(_ remote: PoolRemote, client: PoolLinuxClient) throws {
        var steps: [String] = []
        if client.t3Service || client.t3Installed {
            steps.append("t3=\"$HOME/.local/bin/t3\"; if [ -x \"$t3\" ]; then")
            if client.t3Service { steps.append("\"$t3\" service uninstall </dev/null || exit 1;") }
            if client.t3Installed { steps.append("\"$t3\" uninstall -y </dev/null || exit 1;") }
            steps.append("fi;")
        }
        if client.t3Host != nil {
            steps.append(
                "f=\"\(t3Env)\"; if [ -f \"$f\" ] && [ ! -L \"$f\" ]; then t=$(mktemp) && { grep -v '^T3CODE_HOST=' \"$f\" > \"$t\"; "
                    + "if [ -s \"$t\" ]; then cat \"$t\" > \"$f\"; else rm -f \"$f\"; fi; }; rm -f \"$t\"; fi; "
                    + "f=\"\(t3Retry)\"; d=$(dirname \"$f\"); if [ ! -L \"$d\" ]; then rm -f \"$f\"; rmdir \"$d\" 2>/dev/null; systemctl --user daemon-reload 2>/dev/null; fi;")
        }
        guard !steps.isEmpty else { return }
        try remote.execute(steps.joined(separator: " ") + " true", limit: 300)
    }

    public static func removalNote(_ client: PoolLinuxClient) -> String {
        let goes = [(client.t3Installed, "T3 Code"), (client.claudeInstalled, "Claude Code"), (client.codexInstalled, "Codex")]
            .filter(\.0).map(\.1)
        let stays = [(client.t3Installed, "Your chats"), (client.tailscaleInstalled, "Tailscale")].filter(\.0).map(\.1)
        var parts: [String] = []
        if !goes.isEmpty { parts.append("Relaybar removes what it installed there: \(list(goes)).") }
        if !stays.isEmpty { parts.append("\(list(stays)) \(stays.count == 1 && stays[0] != "Your chats" ? "stays" : "stay").") }
        return parts.joined(separator: " ")
    }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.joined() }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}
