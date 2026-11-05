import Foundation
import Testing

@testable import RelaybarCore

struct PoolSSHSetupTests {
    @Test func setsUpSSHOnlyWhenNeeded() throws {
        let fixture = try Fixture()
        let recorder = Recorder()
        #expect(PoolSSHSetup.prepare(home: fixture.root, run: recorder.runner))
        let keygen = try #require(recorder.commands.first)
        #expect(keygen.executable == "/usr/bin/ssh-keygen")
        #expect(keygen.arguments.starts(with: ["-t", "ed25519", "-N", ""]))
        #expect(keygen.arguments.last == fixture.root.appendingPathComponent(".ssh/id_ed25519").path)
        #expect(
            try FileManager.default.attributesOfItem(atPath: fixture.root.appendingPathComponent(".ssh").path)[.posixPermissions] as? Int
                == 0o700)
        try fixture.write(".ssh/id_rsa.pub", "ssh-rsa AAAA")
        #expect(PoolSSHSetup.hasKey(in: fixture.root.appendingPathComponent(".ssh")))
        #expect(PoolSSHSetup.prepare(home: fixture.root, run: recorder.runner))
        #expect(recorder.commands.count == 1)
        recorder.respond = { _ in CommandResult(status: 1) }
        let empty = try Fixture()
        #expect(!PoolSSHSetup.prepare(home: empty.root, run: recorder.runner))
    }

    @Test func buildsTheCopyCommandWithOneQuotedAddress() throws {
        #expect(try PoolSSHSetup.copyCommand(host: " 192.168.1.20 ") == "ssh-copy-id '192.168.1.20'")
        #expect(throws: PoolInputError.startsWithDash) { try PoolSSHSetup.copyCommand(host: "-oProxyCommand=x") }
        #expect(throws: PoolInputError.badCharacters) { try PoolSSHSetup.copyCommand(host: "a b; rm") }
    }

    @Test func recognisesTheKeyProblem() {
        let message = PoolHubPicker.explain("Permission denied (publickey,password).", host: "homebox")
        #expect(PoolSSHSetup.needsKey(message))
        #expect(!PoolSSHSetup.needsKey(PoolHubPicker.explain("Connection refused", host: "homebox")))
    }
}
