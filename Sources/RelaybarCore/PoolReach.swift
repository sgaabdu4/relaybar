import Foundation

public enum PoolReach {
    public static func probe(host: String) -> Command {
        PoolSSH.command(
            host: host, script: "curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:\(Pool.port)/v1/models; true",
            connectTimeout: 5, limit: 15)
    }

    public static func isRejectedKey(_ error: Error) -> Bool {
        (error as? PoolError) == .rejected(401)
    }

    public static func reason(host: String, error: Error, probe: CommandResult?) -> String? {
        if isRejectedKey(error) {
            return "The helper on \(host) was stopped or set up again. Choose Stop combining, then use it again."
        }
        guard let probe else { return nil }
        guard probe.succeeded else { return PoolHubPicker.explain(probe.error, host: host) }
        let code = probe.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["200", "401"].contains(code) {
            return "The helper on \(host) is running, but this Mac's connection to it is down. Relaybar starts it again by itself."
        }
        return "\(host) is on, but the helper is not running there."
    }
}
