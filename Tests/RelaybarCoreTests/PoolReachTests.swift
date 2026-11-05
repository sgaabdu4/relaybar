import Foundation
import Testing

@testable import RelaybarCore

struct PoolReachTests {
    @Test func namesAHelperThatWasSetUpAgain() {
        let reason = PoolReach.reason(host: "homebox", error: PoolError.rejected(401), probe: nil)
        #expect(reason == "The helper on homebox was stopped or set up again. Choose Stop combining, then use it again.")
        let ignoresTheProbe = PoolReach.reason(
            host: "homebox", error: PoolError.rejected(401), probe: CommandResult(status: 255, error: "Connection refused"))
        #expect(ignoresTheProbe == reason)
        #expect(PoolReach.isRejectedKey(PoolError.rejected(401)))
        #expect(!PoolReach.isRejectedKey(PoolError.rejected(500)))
        #expect(!PoolReach.isRejectedKey(PoolError.unreachable))
    }

    @Test func passesSSHErrorsThroughTheSameWords() {
        let stderr = "ssh: connect to host homebox port 22: Connection refused"
        let reason = PoolReach.reason(
            host: "homebox", error: PoolError.unreachable, probe: CommandResult(status: 255, error: stderr))
        #expect(reason == PoolHubPicker.explain(stderr, host: "homebox"))
        #expect(reason?.contains("refused the connection") == true)
    }

    @Test func tellsAConnectionProblemFromAStoppedHelper() {
        let tunnel = PoolReach.reason(host: "homebox", error: PoolError.unreachable, probe: CommandResult(output: "401\n"))
        #expect(tunnel == "The helper on homebox is running, but this Mac's connection to it is down. Relaybar starts it again by itself.")
        #expect(PoolReach.reason(host: "homebox", error: PoolError.unreachable, probe: CommandResult(output: "200")) == tunnel)
        let stopped = PoolReach.reason(host: "homebox", error: PoolError.unreachable, probe: CommandResult(output: "000"))
        #expect(stopped == "homebox is on, but the helper is not running there.")
        #expect(PoolReach.reason(host: "homebox", error: PoolError.unreachable, probe: CommandResult(output: "")) == stopped)
        #expect(PoolReach.reason(host: "this Mac", error: PoolError.unreachable, probe: nil) == nil)
    }

    @Test func probesWithOneQuickSSHCall() throws {
        let command = PoolReach.probe(host: "homebox")
        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments.contains("homebox"))
        #expect(command.arguments.contains("ConnectTimeout=5"))
        #expect(command.arguments.contains("BatchMode=yes"))
        #expect(remoteScript(command).contains("http://127.0.0.1:8317/v1/models"))
        #expect(command.stdin == nil)
    }
}
