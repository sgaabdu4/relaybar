import Foundation
import Testing

@testable import RelaybarCore

final class Backend: @unchecked Sendable {
    private let lock = NSLock()
    private var holder: String?
    private var destination: String?
    var stubborn = false
    var refuse: String?

    var answers: Bool { lock.withLock { holder != nil && destination != refuse } }
    var served: String? { lock.withLock { destination } }

    func apply(_ command: Command) {
        guard command.executable == "/bin/launchctl", let target = command.arguments.last else { return }
        lock.withLock {
            if command.arguments.first == "bootout" {
                let label = URL(fileURLWithPath: target).lastPathComponent
                if label == holder, !stubborn { holder = nil }
            } else if command.arguments.first == "bootstrap" {
                let label = URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent
                guard holder == nil else { return }
                holder = label
                let text = (try? String(contentsOfFile: target, encoding: .utf8)) ?? ""
                destination = label == Pool.tunnelLabel ? Self.destination(in: text) : "this Mac"
            }
        }
    }

    private static func destination(in plist: String) -> String? {
        let strings = plist.components(separatedBy: "<string>").dropFirst().compactMap { $0.components(separatedBy: "</string>").first }
        return strings.last { !$0.hasPrefix("-") && !$0.hasPrefix("/") && $0 != Pool.tunnelLabel && !$0.contains(":") }
    }

    func handler(accessKey: @escaping @Sendable () -> String?) -> @Sendable (HTTPRequest) -> HTTPResponse? {
        { [self] request in
            guard answers else { return nil }
            switch request.url.path {
            case "/v1/models":
                guard let header = request.headers["Authorization"] else { return HTTPResponse(status: 401) }
                return HTTPResponse(status: header == "Bearer \(accessKey() ?? "")" ? 200 : 401)
            case "/v8/management/credentials": return ok(["files": []])
            default: return nil
            }
        }
    }
}

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

    private let t3Path = ".t3/userdata/settings.json"

    private func wire(
        _ harness: Harness, _ backend: Backend, failInstallOn: String? = nil, failLocalInstall: Bool = false,
        existing: [String: String] = [:]
    ) {
        let paths = harness.paths
        let keychain = harness.env().keychain
        harness.recorder.respond = { command in
            backend.apply(command)
            if command.executable == "/bin/sh", command.arguments.dropFirst().first == "install", failLocalInstall {
                return CommandResult(status: 1, error: "failed: cannot download CLIProxyAPI\n")
            }
            guard command.executable == "/usr/bin/ssh" else { return CommandResult() }
            let text = remoteScript(command)
            let host = command.arguments.dropLast().last ?? ""
            if let answer = existing[host], text.contains("join.json\" ]") { return CommandResult(output: answer) }
            if text.contains("printf %s \"$HOME\"") { return CommandResult(output: "/home/sam") }
            if text.contains("join.json\" ]") { return CommandResult(output: "000") }
            if text.contains("mkdir -m 700") { return CommandResult(output: "claimed") }
            if text.contains("lingerNeeded") {
                return CommandResult(output: host == "homebox" ? "changed:sleep.target\n" : "changed:linger\n")
            }
            if text.contains(" install "), host == failInstallOn {
                return CommandResult(status: 1, error: "failed: cannot download CLIProxyAPI\n")
            }
            return CommandResult()
        }
        harness.http.handler = backend.handler(accessKey: { keychain.read(service: Pool.accessService) })
        _ = paths
    }

    private func combined(_ harness: Harness, _ backend: Backend, host: String? = "homebox") async throws {
        try harness.home.write(
            t3Path,
            #"{"theme": "dark", "defaultModelSelection": {"instanceId": "claudeAgent", "model": "m"}, "providerInstances": {}}"#)
        wire(harness, backend)
        let setup = PoolSetup(env: harness.env())
        if let host { _ = try await setup.combineOnHome(host: host) } else { try await setup.combineOnThisMac() }
    }

    private func tunnelText(_ harness: Harness) -> String {
        (try? String(contentsOf: harness.paths.agent(Pool.tunnelLabel), encoding: .utf8)) ?? ""
    }

    @Test func movesBetweenHomeComputersWithTheSameKeys() async throws {
        let harness = try Harness()
        let backend = Backend()
        try await combined(harness, backend)
        let keychain = harness.env().keychain
        let access = keychain.read(service: Pool.accessService)
        let management = keychain.read(service: Pool.managementService)
        var before = try #require(PoolState.load(harness.paths))
        before.order = ["claude": ["ann@example.com"]]
        before.orderMode = .manual
        before.linuxClients = [PoolLinuxClient(host: "linuxpc")]
        try before.save(harness.paths)
        let mark = harness.recorder.commands.count
        let setup = PoolSetup(env: harness.env())
        let steps = Messages()
        let report = try await setup.move(to: .computer("mediabox"), progress: { steps.texts.append($0) })
        #expect(report.sleep == .off)
        let state = try #require(PoolState.load(harness.paths))
        #expect(state.ssh == "mediabox" && state.tailscale == nil && !state.joined)
        #expect(state.move == nil)
        #expect(state.steps.starts(with: [.keychainAccessKey, .keychainManagementSecret, .remoteHelper, .keepOn, .tunnelAgent]))
        #expect(Set(state.steps) == Set(before.steps))
        #expect(state.steps.filter { $0 == .remoteHelper }.count == 1)
        #expect(state.keepOn == PoolKeepOn(linger: true))
        #expect(state.order == before.order && state.orderMode == .manual)
        #expect(state.linuxClients.map(\.host) == ["linuxpc"])
        #expect(state.previousSelection == before.previousSelection && state.usageSourceAdded)
        #expect(keychain.read(service: Pool.accessService) == access && keychain.read(service: Pool.managementService) == management)
        let ran = Array(harness.recorder.commands.dropFirst(mark))
        #expect(
            !ran.contains {
                $0.executable == "/usr/bin/security" && ($0.arguments == ["-i"] || $0.arguments.first == "delete-generic-password")
            })
        #expect(tunnelText(harness).contains("<string>mediabox</string>") && !tunnelText(harness).contains("homebox"))
        #expect(backend.served == "mediabox")
        let config = ran.first {
            remoteScript($0).contains("cat > ") && remoteScript($0).contains("/config.yaml") && $0.arguments.contains("mediabox")
        }
        let written = String(decoding: config?.stdin ?? Data(), as: UTF8.self)
        #expect(written.contains(access ?? "missing") && written.contains(management ?? "missing"))
        let toNew = ran.filter { $0.arguments.contains("mediabox") }.map(remoteScript)
        #expect(!toNew.contains { $0.contains("rm -rf") })
        let toOld = ran.filter { $0.arguments.contains("homebox") }.map(remoteScript)
        #expect(toOld.contains { $0.contains("rm -rf \"$HOME/.local/share/relaybar-helper\"") })
        #expect(toOld.contains { $0.contains("systemctl unmask sleep.target") })
        #expect(steps.texts.contains("Setting up the helper on mediabox"))
        let settings = try harness.home.json(t3Path)
        #expect((settings["providerInstances"] as? [String: Any])?.keys.contains("claudeAgent_all_accounts") == true)
        #expect(FileManager.default.fileExists(atPath: harness.paths.claudePlus.path))
    }

    private func assertPutBack(_ harness: Harness, before: PoolState, backend: Backend, served: String, newHost: String?) throws {
        #expect(PoolState.load(harness.paths) == before)
        #expect(backend.answers && backend.served == served)
        let keychain = harness.env().keychain
        #expect(keychain.read(service: Pool.accessService) != nil && keychain.read(service: Pool.managementService) != nil)
        let ssh = harness.recorder.commands.filter { $0.executable == "/usr/bin/ssh" }
        let removals = ssh.filter { remoteScript($0).contains("rm -rf") }
        if let newHost {
            #expect(removals.count == 1 && removals.allSatisfy { $0.arguments.contains(newHost) })
        } else {
            #expect(removals.isEmpty)
        }
    }

    private func moving(_ harness: Harness, _ backend: Backend, host: String?) async throws -> PoolState {
        try await combined(harness, backend, host: host)
        let before = try #require(PoolState.load(harness.paths))
        harness.recorder.removeCommands()
        return before
    }

    @Test func aFailureBeforeTheSwitchPutsEverythingBack() async throws {
        let installFails = try Harness()
        let backend = Backend()
        var before = try await moving(installFails, backend, host: "homebox")
        wire(installFails, backend, failInstallOn: "mediabox")
        await #expect(throws: PoolInstallError.self) {
            _ = try await PoolSetup(env: installFails.env()).move(to: .computer("mediabox"))
        }
        try assertPutBack(installFails, before: before, backend: backend, served: "homebox", newHost: "mediabox")

        let neverAnswers = try Harness()
        let silent = Backend()
        before = try await moving(neverAnswers, silent, host: "homebox")
        silent.refuse = "mediabox"
        await #expect(throws: PoolSetupError.notAnswering) {
            _ = try await PoolSetup(env: neverAnswers.env()).move(to: .computer("mediabox"))
        }
        silent.refuse = nil
        try assertPutBack(neverAnswers, before: before, backend: silent, served: "homebox", newHost: "mediabox")
        #expect(neverAnswers.recorder.ran("/usr/bin/ssh", containing: "systemctl unmask sleep.target") == false)

        let stuck = try Harness()
        let stubborn = Backend()
        before = try await moving(stuck, stubborn, host: "homebox")
        stubborn.stubborn = true
        await #expect(throws: PoolMoveError.oldStillAnswers) { _ = try await PoolSetup(env: stuck.env()).move(to: .computer("mediabox")) }
        try assertPutBack(stuck, before: before, backend: stubborn, served: "homebox", newHost: "mediabox")
        #expect(stuck.recorder.commands.contains { remoteScript($0).contains("loginctl disable-linger") })
    }

    @Test func aFailureOnThisMacPutsBackTheLocalHelper() async throws {
        let harness = try Harness()
        let backend = Backend()
        let before = try await moving(harness, backend, host: nil)
        backend.refuse = "mediabox"
        await #expect(throws: PoolSetupError.notAnswering) {
            _ = try await PoolSetup(env: harness.env()).move(to: .computer("mediabox"))
        }
        backend.refuse = nil
        try assertPutBack(harness, before: before, backend: backend, served: "this Mac", newHost: "mediabox")
        #expect(!FileManager.default.fileExists(atPath: harness.paths.agent(Pool.tunnelLabel).path))
        #expect(FileManager.default.fileExists(atPath: harness.paths.agent(Pool.helperLabel).path))
        #expect(FileManager.default.fileExists(atPath: harness.paths.config.path))
    }

    @Test func aFailureWhileMovingOntoThisMacPutsBackTheTunnel() async throws {
        let harness = try Harness()
        let backend = Backend()
        let before = try await moving(harness, backend, host: "homebox")
        wire(harness, backend, failLocalInstall: true)
        await #expect(throws: PoolInstallError.self) { _ = try await PoolSetup(env: harness.env()).move(to: .thisMac) }
        try assertPutBack(harness, before: before, backend: backend, served: "homebox", newHost: nil)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.helper.path))
        #expect(!FileManager.default.fileExists(atPath: harness.paths.agent(Pool.helperLabel).path))
        #expect(tunnelText(harness).contains("<string>homebox</string>"))
    }

    private func harnessRespondsFree(_ harness: Harness) {
        harness.recorder.respond = { _ in CommandResult(output: "000") }
    }
}
