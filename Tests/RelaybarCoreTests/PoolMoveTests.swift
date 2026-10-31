import Foundation
import Testing

@testable import RelaybarCore

struct PoolMoveTests {
    private func seeded(
        ssh: String? = "homebox", tailscale: String? = nil, joined: Bool = false, clients: [String] = [], keys: Bool = true
    ) throws -> Harness {
        let harness = try Harness()
        var state = PoolState(ssh: ssh, joined: joined)
        state.tailscale = tailscale
        state.steps = [.keychainAccessKey, .keychainManagementSecret]
        state.linuxClients = clients.map { PoolLinuxClient(host: $0) }
        try state.save(harness.paths)
        if keys {
            let keychain = harness.env().keychain
            _ = keychain.store(service: Pool.accessService, secret: String(repeating: "a1", count: 32))
            _ = keychain.store(service: Pool.managementService, secret: String(repeating: "b2", count: 32))
        }
        return harness
    }

    @Test func refusesATargetThatCannotTakeTheHelper() throws {
        let harness = try seeded(tailscale: "100.64.0.7", clients: ["linuxpc"])
        let setup = PoolSetup(env: harness.env())
        harness.recorder.respond = { _ in CommandResult(output: "000") }
        #expect(throws: PoolMoveError.alreadyHere("homebox")) { try setup.checkMove(to: .computer("homebox")) }
        #expect(throws: PoolMoveError.alreadyHere("100.64.0.7")) { try setup.checkMove(to: .computer("100.64.0.7")) }
        #expect(throws: PoolMoveError.addedComputer("linuxpc")) { try setup.checkMove(to: .computer("linuxpc")) }
        #expect(PoolMoveError.addedComputer("linuxpc").errorDescription == "Remove linuxpc from Computers first, then move.")
        #expect(throws: PoolInputError.self) { try setup.checkMove(to: .computer("-x")) }
        #expect(!harness.recorder.commands.contains { $0.executable == "/usr/bin/ssh" })
        harness.recorder.respond = { _ in CommandResult(output: "ours") }
        #expect(throws: PoolSetupError.hubExists("mediabox")) { try setup.checkMove(to: .computer("mediabox")) }
        harness.recorder.respond = { _ in CommandResult(output: "folder") }
        #expect(throws: PoolSetupError.conflict(.foreignHelperFolder("mediabox:.local/share/relaybar-helper"))) {
            try setup.checkMove(to: .computer("mediabox"))
        }
        harness.recorder.respond = { _ in CommandResult(output: "401") }
        #expect(throws: PoolSetupError.conflict(.portInUse(8317))) { try setup.checkMove(to: .computer("mediabox")) }
        harness.recorder.respond = { _ in CommandResult(output: "000") }
        #expect(try setup.checkMove(to: .computer("mediabox")) == "mediabox")
        #expect(try setup.checkMove(to: .thisMac) == nil)
        try harness.home.write("Library/Application Support/Relaybar/Helper/config.yaml", "mine")
        #expect(throws: PoolSetupError.conflict(.foreignHelperFolder(harness.paths.helper.path))) { try setup.checkMove(to: .thisMac) }
        #expect(PoolMoveError.alreadyHere("this Mac").errorDescription?.contains("this Mac") == true)
    }

    @Test func refusesWhenThereIsNothingToMove() throws {
        let none = try Harness()
        #expect(throws: PoolSetupError.notCombining) { try PoolSetup(env: none.env()).checkMove(to: .thisMac) }
        let local = try seeded(ssh: nil)
        #expect(throws: PoolMoveError.alreadyHere("this Mac")) { try PoolSetup(env: local.env()).checkMove(to: .thisMac) }
        let keyless = try seeded(keys: false)
        #expect(throws: PoolSetupError.accessKeyMissing) { try PoolSetup(env: keyless.env()).checkMove(to: .computer("mediabox")) }
        let pending = try seeded()
        var state = try #require(PoolState.load(pending.paths))
        state.move = PoolMove(target: "mediabox", phase: .preparing, old: nil)
        try state.save(pending.paths)
        #expect(throws: PoolMoveError.unfinished) { try PoolSetup(env: pending.env()).checkMove(to: .thisMac) }
        #expect(PoolMoveError.unfinished.errorDescription?.isEmpty == false)
    }

    @Test func onlyTheOwnerCanMove() throws {
        let owner = try seeded()
        #expect(try #require(PoolState.load(owner.paths)).canMoveHelper)
        let joined = try seeded(joined: true)
        #expect(!(try #require(PoolState.load(joined.paths))).canMoveHelper)
        harnessRespondsFree(joined)
        #expect(throws: PoolMoveError.joined) { try PoolSetup(env: joined.env()).checkMove(to: .computer("mediabox")) }
        #expect(PoolMoveError.joined.errorDescription?.contains("Only the Mac that set up the helper") == true)
        #expect(!joined.recorder.commands.contains { $0.executable == "/usr/bin/ssh" })
        var moving = try #require(PoolState.load(owner.paths))
        moving.move = PoolMove(target: nil, phase: .switched, old: nil)
        #expect(!moving.canMoveHelper)
    }

    private func harnessRespondsFree(_ harness: Harness) {
        harness.recorder.respond = { _ in CommandResult(output: "000") }
    }
}
