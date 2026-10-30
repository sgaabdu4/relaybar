import Foundation
import Testing

@testable import RelaybarCore

struct PoolHubPickerTests {
    private func probe(
        os: String = "Linux", state: String = "running", up: Int = 200_000, ip: String = "203.0.113.9",
        org: String = "AS64500 Example Broadband"
    ) -> CommandResult {
        let info = ip.isEmpty ? "" : #"{"ip":"\#(ip)","org":"\#(org)"}"#
        return CommandResult(output: "os=\(os)\nstate=\(state)\nup=\(up)\ninfo=\(info)\n")
    }

    private func setup(mac: String = #"{"ip":"203.0.113.9","org":"AS64500 Example Broadband"}"#, answers: [String: CommandResult]) throws
        -> (PoolEnvironment, FakeHTTP, Recorder)
    {
        let harness = try Harness()
        harness.http.handler = { _ in HTTPResponse(status: 200, body: Data(mac.utf8)) }
        harness.recorder.respond = { command in
            let host = command.arguments.dropLast().last ?? ""
            return answers[host] ?? CommandResult(status: 255, error: "ssh: Could not resolve hostname \(host)")
        }
        return (harness.env(), harness.http, harness.recorder)
    }

    @Test func offersOnlyAHomeLinuxComputer() async throws {
        let (env, _, _) = try setup(answers: ["homebox": probe()])
        let choices = await PoolHubPicker.discover(hosts: ["homebox"], env: env)
        #expect(!choices.macLooksLikeCloud)
        #expect(choices.offered.map(\.name) == ["homebox"])
    }

    @Test func hidesUnsafeComputers() async throws {
        let answers: [String: CommandResult] = [
            "cloudbox": probe(org: "AS16509 Amazon.com, Inc."), "elsewhere": probe(ip: "198.51.100.7"), "macbox": probe(os: "Darwin"),
            "sleepy": probe(up: 600), "broken": probe(state: ""), "noinfo": probe(ip: ""),
            "gone": CommandResult(status: 255, error: "Connection refused"),
            "home": probe(),
        ]
        let (env, _, _) = try setup(answers: answers)
        let hosts = ["cloudbox", "elsewhere", "macbox", "sleepy", "broken", "noinfo", "gone", "home", "-bad"]
        let choices = await PoolHubPicker.discover(hosts: hosts, env: env)
        #expect(choices.offered.map(\.name) == ["home"])
        let reasons = choices.computers.compactMap { computer -> String? in
            if case .hidden(let reason) = computer.verdict { return reason }
            return nil
        }
        #expect(reasons.count == 8)
        #expect(reasons[0].contains("cloud server"))
        #expect(reasons[1].contains("not at home"))
        #expect(reasons[2].contains("not a Linux"))
        #expect(reasons[3].contains("always on"))
        #expect(reasons[5].contains("could not check"))
        #expect(reasons[6].contains("refused the connection"))
    }

    @Test func checksOnlyHomeAddresses() async throws {
        let (env, _, recorder) = try setup(answers: ["homebox": probe(), "work": probe()])
        recorder.respond = { command in
            if command.arguments.first == "-G" {
                let host = command.arguments.last ?? ""
                return CommandResult(output: "user someone\nhostname \(host == "work" ? "203.0.113.50" : "192.168.1.20")\n")
            }
            return probe()
        }
        let choices = await PoolHubPicker.discover(hosts: ["homebox", "work"], env: env)
        #expect(choices.offered.map(\.name) == ["homebox"])
        #expect(!recorder.commands.contains { $0.arguments.first != "-G" && $0.arguments.contains("work") })
        #expect(PoolHubPicker.isHomeAddress("100.95.1.2") && PoolHubPicker.isHomeAddress("box.tail1234.ts.net"))
        #expect(!PoolHubPicker.isHomeAddress("github.com") && !PoolHubPicker.isHomeAddress("157.230.1.2"))
    }

    @Test func listsOnlyHomeComputersToAdd() {
        let recorder = Recorder()
        recorder.respond = { command in
            let host = command.arguments.last ?? ""
            return CommandResult(output: "hostname \(["work": "203.0.113.50", "nas": "192.168.1.30"][host] ?? "192.168.1.20")\n")
        }
        let found = PoolHubPicker.addable(
            hosts: ["homebox", "laptop", "work", "nas", "-bad", "desktop"], excluding: ["homebox", "desktop"], run: recorder.runner)
        #expect(found == ["laptop", "nas"])
        #expect(!recorder.commands.contains { $0.arguments.contains("homebox") || $0.arguments.contains("-bad") })
    }

    @Test func listsEachComputerOnce() async throws {
        let same = CommandResult(output: probe().output + "id=0123abcd\n")
        let (env, _, _) = try setup(answers: ["homebox": same, "homebox-lan": same, "192.168.1.20": same, "other": probe()])
        let choices = await PoolHubPicker.discover(hosts: ["homebox", "homebox-lan", "192.168.1.20", "other"], env: env)
        #expect(choices.offered.map(\.name) == ["homebox", "other"])
    }

    @Test func blocksWhileOnAVPN() async throws {
        let (env, _, recorder) = try setup(
            mac: #"{"ip":"198.51.100.2","org":"AS9009 M247 Europe SRL"}"#, answers: ["homebox": probe(ip: "198.51.100.2")])
        let choices = await PoolHubPicker.discover(hosts: ["homebox"], env: env)
        #expect(choices.macLooksLikeCloud)
        #expect(choices.offered.isEmpty)
        #expect(recorder.commands.isEmpty)
        let typed = try await PoolHubPicker.check(typed: "homebox", env: env)
        #expect(typed.verdict != .offer)
        let blind = try Harness().env()
        #expect(await PoolHubPicker.discover(hosts: ["x"], env: blind).macLooksLikeCloud)
    }

    @Test func acceptsAnAddressOrSSHName() async throws {
        for value in ["192.168.1.20", "homebox", "homebox.local", "100.64.0.5", "me@homebox", "fd7a:115c::1", " homebox "] {
            #expect(throws: Never.self) { try PoolHubPicker.validate(value) }
        }
        #expect(try PoolHubPicker.validate(" homebox ") == "homebox")
        let (env, _, recorder) = try setup(answers: ["192.168.1.20": probe()])
        let computer = try await PoolHubPicker.check(typed: "192.168.1.20", env: env)
        #expect(computer == PoolComputer(name: "192.168.1.20", verdict: .offer))
        let command = try #require(recorder.commands.first)
        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments.prefix(4) == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"])
        #expect(command.arguments.contains("--"))
    }

    @Test func refusesSSHOptions() async throws {
        for value in ["-oProxyCommand=touch /tmp/x", "-v", "a b", "host\nname", "", "   ", "host;rm", "$(id)", "ho`st"] {
            #expect(throws: PoolInputError.self) { try PoolHubPicker.validate(value) }
        }
        #expect(throws: PoolInputError.startsWithDash) { try PoolHubPicker.validate("-x") }
        #expect(throws: PoolInputError.empty) { try PoolHubPicker.validate("") }
        #expect(throws: PoolInputError.badCharacters) { try PoolHubPicker.validate("a b") }
        for error in [PoolInputError.empty, .startsWithDash, .badCharacters] { #expect(error.errorDescription?.isEmpty == false) }
        let (env, _, recorder) = try setup(answers: [:])
        await #expect(throws: PoolInputError.startsWithDash) { try await PoolHubPicker.check(typed: "-oProxyCommand=x", env: env) }
        #expect(recorder.commands.isEmpty)
    }

    @Test func explainsSSHFailures() {
        let cases: [(String, String)] = [
            (
                "user@homebox: Permission denied (publickey,password).",
                "SSH asked for a password. Add this Mac's SSH key to that computer, then click Try Again."
            ),
            (
                "Host key verification failed.",
                "This Mac has not met homebox yet. Run \"ssh homebox\" once in Terminal and accept its key, then click Try Again."
            ),
            ("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed.", "The SSH identity of homebox changed."),
            ("ssh: connect to host homebox port 22: Connection refused", "homebox refused the connection. Turn on SSH (Remote Login)"),
            ("ssh: Could not resolve hostname homebox: nodename nor servname provided", "Relaybar cannot find homebox."),
            ("ssh: connect to host homebox port 22: Operation timed out", "homebox did not answer."),
            ("ssh: connect to host homebox port 22: No route to host", "homebox did not answer."),
            ("something odd\nsecond line", "SSH to homebox failed (something odd)."),
        ]
        for (stderr, expected) in cases {
            #expect(PoolHubPicker.explain(stderr, host: "homebox").hasPrefix(expected), "\(stderr)")
        }
        let result = PoolHubPicker.judge(CommandResult(status: 255, error: "Permission denied"), host: "h", mac: IPInfo(ip: "1", org: ""))
        #expect(result == .hidden("SSH asked for a password. Add this Mac's SSH key to that computer, then click Try Again."))
        #expect(PoolHubPicker.explain("", host: "h").contains("no reason given"))
    }

    @Test func looksUpAddressesOnlyDuringSetup() async throws {
        let (env, http, _) = try setup(answers: ["homebox": probe()])
        _ = await PoolHubPicker.discover(hosts: ["homebox"], env: env)
        #expect(http.requests.map(\.url.host) == ["ipinfo.io"])
        let before = http.requests.count
        http.handler = { _ in ok(sampleCredentials) }
        let management = PoolManagement(secret: "s", http: http.client)
        _ = try await management.credentials()
        _ = await management.isUp()
        _ = await management.modelsAnswer(accessKey: "k")
        let members = await PoolUsage.fetch(management: management, credentials: try await management.credentials())
        _ = PoolUsage.card(kind: .claude, members: members)
        #expect(http.requests.dropFirst(before).allSatisfy { $0.url.host == "127.0.0.1" })
    }

    @Test func readsHostsFromTheSSHConfig() {
        let text = """
            Host *
              ServerAliveInterval 30
            Host homebox nas.local
              HostName 192.168.1.20
            host=laptop
            Host work-*  !secret
            Match all
            Host homebox
            """
        #expect(PoolHubPicker.parseSSHConfig(text) == ["homebox", "nas.local", "laptop"])
        #expect(PoolHubPicker.parseSSHConfig("").isEmpty)
    }

    @Test func parsesAddressAnswers() {
        #expect(PoolHubPicker.parseIPInfo(Data(#"{"ip":"1.2.3.4"}"#.utf8)) == IPInfo(ip: "1.2.3.4", org: ""))
        #expect(PoolHubPicker.parseIPInfo(Data("nope".utf8)) == nil)
        #expect(PoolHubPicker.isCloud("AS14061 DigitalOcean, LLC"))
        #expect(PoolHubPicker.isCloud("AS24940 Hetzner Online GmbH"))
        #expect(!PoolHubPicker.isCloud("AS5089 Example Cable"))
    }
}
