import Foundation
import Testing

@testable import RelaybarCore

struct PoolCommandTests {
    @Test func secretsNeverInArguments() async throws {
        let harness = try Harness()
        try harness.home.write(".t3/userdata/settings.json", #"{"providerInstances": {}}"#)
        let up = Flag()
        let recorder = harness.recorder
        let keys = Keys()
        recorder.respond = { command in
            let text = command.executable == "/usr/bin/ssh" ? remoteScript(command) : ""
            if let stdin = command.stdin, command.arguments == ["-i"] {
                keys.stdin.append(String(decoding: stdin, as: UTF8.self))
            }
            if text.contains("printf %s \"$HOME\"") { return CommandResult(output: "/home/sam") }
            if text.contains("join.json\" ]") { return CommandResult(output: "000") }
            if text.contains("mkdir -m 700") { return CommandResult(output: "claimed") }
            if command.executable == "/bin/launchctl", command.arguments.first == "bootstrap" { up.on = true }
            if command.executable == "/bin/sh", command.arguments.dropFirst().first == "install" { up.on = true }
            return CommandResult()
        }
        harness.http.handler = { request in
            guard request.url.path == "/v1/models", up.on else { return nil }
            return HTTPResponse(status: request.headers["Authorization"] == nil ? 401 : 200)
        }
        let setup = PoolSetup(env: harness.env())
        try await setup.combineOnThisMac()
        let local = recorder.commands
        up.on = false
        _ = setup.stop()
        _ = try await setup.combineOnHome(host: "homebox", sudoPassword: "hunter2-password")
        let all = recorder.commands
        let secrets = keys.stdin.flatMap { line in
            line.split(separator: "\"").map(String.init).filter { $0.count == 64 && $0.allSatisfy({ $0.isHexDigit }) }
        }
        #expect(secrets.count >= 4)
        #expect(local.count < all.count)
        for command in all {
            let joined = ([command.executable] + command.arguments + command.environment.map { $0.key + "=" + $0.value }).joined(
                separator: " ")
            for secret in secrets + ["hunter2-password"] {
                #expect(!joined.contains(secret), "secret in arguments of \(command.executable)")
            }
        }
        let remoteStdin = all.filter { $0.executable == "/usr/bin/ssh" }.compactMap(\.stdin).map { String(decoding: $0, as: UTF8.self) }
        #expect(remoteStdin.contains { secrets.suffix(2).contains(where: $0.contains) })
        #expect(remoteStdin.contains("hunter2-password\n"))
    }

    @Test func computerSecretsNeverInArguments() async throws {
        let harness = try Harness()
        try harness.home.write(".t3/userdata/settings.json", #"{"providerInstances": {}}"#)
        harness.answerHomeAndComputers(
            FakeClientHost(
                probe: FakeClientHost.probe + "\nt3:yes\nt3secrets:new",
                settings: #"{"defaultModelSelection": {"instanceId": "claudeAgent", "model": "m"}, "providerInstances": {}}"#))
        let setup = PoolSetup(env: harness.env())
        _ = try await setup.combineOnHome(host: "homebox")
        let mark = harness.recorder.commands.count
        let access = try #require(setup.accessKey())
        let management = try #require(harness.env().keychain.read(service: Pool.managementService))
        try await setup.useOnLinux(host: "laptop")
        try setup.removeComputer(host: "laptop")
        let sent = Array(harness.recorder.commands.dropFirst(mark))
        #expect(sent.contains { remoteScript($0).contains("userdata/secrets/provider-env-") })
        for command in sent {
            let joined = ([command.executable] + command.arguments + command.environment.map { $0.key + "=" + $0.value }).joined(
                separator: " ")
            for secret in [access, management] { #expect(!joined.contains(secret), "secret in arguments of \(command.executable)") }
            #expect(command.stdin.map { String(decoding: $0, as: UTF8.self).contains(management) } != true)
        }
        #expect(sent.contains { $0.stdin == Data(access.utf8) })

        let password = "correct-horse-battery"
        let joined = Flag()
        let computer = FakeClientHost(probe: FakeClientHost.probe + "\nneed:codex", password: password)
        let mac = harness.recorder.commands.count
        harness.recorder.respond = { command in
            let text = command.executable == "/usr/bin/ssh" ? remoteScript(command) : ""
            if text.hasPrefix("if ! command -v tailscale") {
                let running = "RB-IP\n100.64.0.9\nRB-STATUS\n" + tailscaleStatus("Running") + "\n"
                return CommandResult(output: joined.on ? running : "RB-MISSING\n")
            }
            if text.contains("sudo"), text.contains("tailscale up"), command.stdin != nil {
                joined.on = true
                return CommandResult(output: signInOutput)
            }
            return computer.answer(command) ?? CommandResult()
        }
        let hooks = PoolAddHooks(password: { _, _ in password })
        _ = try await setup.useOnLinux(host: "desktop", options: PoolAddOptions(t3Channel: .stable, tailscale: true), hooks: hooks)
        let added = Array(harness.recorder.commands.dropFirst(mac))
        for command in added {
            let line = ([command.executable] + command.arguments + command.environment.map { $0.key + "=" + $0.value }).joined(
                separator: " ")
            #expect(!line.contains(password), "password in arguments of \(command.executable)")
            #expect(!line.contains("token%3D"), "pair link in arguments")
        }
        let typed = added.filter { $0.stdin == Data((password + "\n").utf8) }
        #expect(typed.count >= 2)
        #expect(typed.allSatisfy { plainScript($0).hasPrefix("sudo -S -p '' sh -c ") })
        #expect(!added.contains { $0.stdin.map { String(decoding: $0, as: UTF8.self).contains(password) } == true && !typed.contains($0) })
    }

    @Test func theRealRunnerRunsAProgram() {
        let echo = PoolProcess.run(Command("/bin/echo", ["hello"]))
        #expect(echo.succeeded)
        #expect(echo.output == "hello\n")
        let cat = PoolProcess.run(Command("/bin/cat", stdin: Data("from stdin".utf8)))
        #expect(cat.output == "from stdin")
        let env = PoolProcess.run(Command("/usr/bin/env", environment: ["RELAYBAR_TEST_VALUE": "yes"]))
        #expect(env.output.contains("RELAYBAR_TEST_VALUE=yes"))
        let failing = PoolProcess.run(Command("/bin/sh", ["-c", "echo oops >&2; exit 3"]))
        #expect(failing.status == 3)
        #expect(failing.error == "oops\n")
        #expect(!failing.succeeded)
        #expect(PoolProcess.run(Command("/nonexistent/program")).status == 127)
        let big = PoolProcess.run(Command("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' x >&2; echo done"]))
        #expect(big.output == "done\n")
        #expect(big.error.count == 300_000)
    }

    @Test func stopsAProgramThatRunsTooLong() {
        let started = Date()
        let slow = PoolProcess.run(Command("/bin/sleep", ["30"], limit: 0.3))
        #expect(slow.status == CommandResult.timedOut)
        #expect(slow.error == "timed out")
        #expect(!slow.succeeded)
        #expect(Date().timeIntervalSince(started) < 10)
        let quick = PoolProcess.run(Command("/bin/echo", ["ok"], limit: 30))
        #expect(quick.output == "ok\n")
        #expect(quick.succeeded)
    }

    @Test func returnsWhenABackgroundChildKeepsThePipesOpen() {
        let started = Date()
        let result = PoolProcess.run(Command("/bin/sh", ["-c", "sleep 30 & echo ok"]))
        #expect(result.output == "ok\n")
        #expect(result.succeeded)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func quotesForTheRemoteShell() {
        #expect(Shell.quote("plain") == "'plain'")
        #expect(Shell.quote("it's") == "'it'\\''s'")
        let command = PoolSSH.command(host: "homebox", script: "echo 'x'; echo $HOME")
        #expect(command.arguments.suffix(3) == ["--", "homebox", "sh -c 'echo '\\''x'\\''; echo $HOME'"])
        #expect(remoteScript(command) == "echo '\\''x'\\''; echo $HOME")
        #expect(command.limit == 120)
        for option in ["BatchMode=yes", "ConnectTimeout=10", "ServerAliveInterval=15", "ServerAliveCountMax=2"] {
            #expect(command.arguments.contains(option))
        }
    }
}

final class Keys: @unchecked Sendable {
    var stdin: [String] = []
}
