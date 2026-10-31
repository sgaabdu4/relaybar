import Foundation
import Testing

@testable import RelaybarCore

final class Credentials: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [[String: Any]]
    private(set) var patches: [(path: String, body: [String: Any])] = []

    init(_ names: [(String, String)]) {
        files = names.map { kind, email in
            [
                "name": "\(kind)-\(email).json", "auth_index": "idx-\(email)", "provider": kind, "email": email, "disabled": false,
                "status": "active", "priority": 0,
            ]
        }
    }

    func handler(secret: String) -> @Sendable (HTTPRequest) -> HTTPResponse? {
        { [self] request in
            guard request.headers["Authorization"] == "Bearer \(secret)" else { return nil }
            return lock.withLock {
                let path = request.url.path.replacingOccurrences(of: "/v8/management/", with: "")
                if request.method == "GET", path == "credentials" { return ok(["files": files]) }
                guard request.method == "PATCH", let data = request.body,
                    let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { return nil }
                patches.append((path, body))
                if let index = files.firstIndex(where: { $0["name"] as? String == body["name"] as? String }) {
                    if let disabled = body["disabled"] { files[index]["disabled"] = disabled }
                    if let priority = body["priority"] { files[index]["priority"] = priority }
                }
                return ok([:])
            }
        }
    }
}

final class Switches: @unchecked Sendable {
    private let lock = NSLock()
    private var down: Set<String> = []

    func turnOff(_ host: String) { lock.withLock { _ = down.insert(host) } }
    func turnOn(_ host: String) { lock.withLock { _ = down.remove(host) } }
    func isOff(_ host: String) -> Bool { lock.withLock { down.contains(host) } }
}

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
        #expect(throws: PoolMoveError.addedComputer("linuxpc")) { try setup.checkMove(to: .thisMac) }
        let clean = try seeded()
        #expect(try PoolSetup(env: clean.env()).checkMove(to: .thisMac) == nil)
        try clean.home.write("Library/Application Support/Relaybar/Helper/config.yaml", "mine")
        #expect(throws: PoolSetupError.conflict(.foreignHelperFolder(clean.paths.helper.path))) {
            try PoolSetup(env: clean.env()).checkMove(to: .thisMac)
        }
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
        existing: [String: String] = [:], computers: FakeClientHost? = nil, switches: Switches = Switches()
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
            if switches.isOff(host) {
                return CommandResult(status: 255, error: "ssh: connect to host \(host) port 22: Connection timed out")
            }
            if text.contains("hub_key.pub") { return CommandResult(output: "ssh-ed25519 AAAAclientkey\n") }
            if text == "command -v ssh" { return CommandResult(output: "/usr/bin/ssh\n") }
            if text.contains("lingerNeeded") {
                return CommandResult(output: host == "homebox" ? "changed:sleep.target\n" : "changed:linger\n")
            }
            if text.contains(" install "), host == failInstallOn {
                return CommandResult(status: 1, error: "failed: cannot download CLIProxyAPI\n")
            }
            if let computers, let answer = computers.answer(command) { return answer }
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
        let signedIn = Messages()
        let harnessForClosure = harness
        let report = try await setup.move(
            to: .computer("mediabox"), progress: { steps.texts.append($0) },
            afterSwitch: {
                let during = PoolState.load(harnessForClosure.paths)
                let removed = harnessForClosure.recorder.commands.contains {
                    remoteScript($0).contains("rm -rf") && $0.arguments.contains("homebox")
                }
                signedIn.texts.append("\(during?.move?.phase.rawValue ?? "none") \(during?.ssh ?? "none") \(removed)")
            })
        #expect(signedIn.texts == ["switched mediabox false"])
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
        #expect(steps.texts.contains("Connecting this Mac to mediabox"))
        #expect(steps.texts.compactMap { PoolMoveStage(progress: $0) }.contains(.remove))
        #expect(
            PoolMoveStage(progress: "Pointing linuxpc at mediabox") == .computers
                && PoolMoveStage(progress: "Copying the helper installer to mediabox") == .prepare)
        #expect(PoolMoveStage(progress: "Making a key") == nil)
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
        await #expect(throws: PoolMoveError.oldStillAnswers) {
            _ = try await PoolSetup(env: stuck.env()).move(to: .computer("mediabox"), sudoPassword: "pw")
        }
        try assertPutBack(stuck, before: before, backend: stubborn, served: "homebox", newHost: "mediabox")
        #expect(
            stuck.recorder.commands.contains {
                remoteScript($0).contains("loginctl disable-linger") && $0.arguments.contains("mediabox") && $0.stdin == Data("pw\n".utf8)
            })
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

    private func interrupted(
        _ harness: Harness, _ backend: Backend, phase: PoolMovePhase, claimed: Bool = true, newKeepOn: PoolKeepOn = PoolKeepOn(linger: true)
    ) async throws {
        try await combined(harness, backend, host: "homebox")
        var state = try #require(PoolState.load(harness.paths))
        let old = PoolMoveOld(ssh: "homebox", tailscale: nil, keepOn: state.keepOn)
        state.move = PoolMove(target: "mediabox", phase: phase, old: old, claimed: claimed, newKeepOn: newKeepOn)
        if phase == .switched {
            state.ssh = "mediabox"
            state.keepOn = newKeepOn
        }
        try state.save(harness.paths)
        if phase == .switched {
            try PoolFile.write(
                Data(PoolTunnel.plist(paths: harness.paths, destination: "mediabox").utf8), to: harness.paths.agent(Pool.tunnelLabel),
                backup: false)
        }
        harness.recorder.removeCommands()
    }

    @Test func resumesOrUndoesAnInterruptedMove() async throws {
        var state = PoolState(ssh: "homebox")
        #expect(PoolMove.action(for: state) == .none)
        state.move = PoolMove(target: "mediabox", phase: .preparing, old: nil)
        #expect(PoolMove.action(for: state) == .undo)
        state.move?.phase = .switched
        #expect(PoolMove.action(for: state) == .finish)

        let before = try Harness()
        let backend = Backend()
        try await interrupted(before, backend, phase: .preparing)
        let original = try #require(PoolState.load(before.paths))
        try PoolFile.write(
            Data(PoolTunnel.plist(paths: before.paths, destination: "mediabox").utf8), to: before.paths.agent(Pool.tunnelLabel),
            backup: false)
        let undone = await PoolSetup(env: before.env()).settleMove()
        #expect(undone == PoolMoveReport())
        var expected = original
        expected.move = nil
        #expect(PoolState.load(before.paths) == expected)
        #expect(tunnelText(before).contains("<string>homebox</string>") && backend.served == "homebox")
        let removals = before.recorder.commands.filter { remoteScript($0).contains("rm -rf") }
        #expect(removals.count == 1 && removals[0].arguments.contains("mediabox"))
        #expect(
            before.recorder.commands.contains { remoteScript($0).contains("loginctl disable-linger") && $0.arguments.contains("mediabox") })

        let after = try Harness()
        let second = Backend()
        try await interrupted(after, second, phase: .switched, newKeepOn: PoolKeepOn(linger: true))
        let finished = await PoolSetup(env: after.env()).settleMove()
        #expect(finished == PoolMoveReport())
        let saved = try #require(PoolState.load(after.paths))
        #expect(saved.move == nil && saved.ssh == "mediabox")
        let old = after.recorder.commands.filter { $0.arguments.contains("homebox") }.map(remoteScript)
        #expect(old.contains { $0.contains("rm -rf \"$HOME/.local/share/relaybar-helper\"") })
        #expect(!after.recorder.commands.contains { $0.arguments.contains("mediabox") && remoteScript($0).contains("rm -rf") })
        let again = await PoolSetup(env: after.env()).settleMove()
        #expect(again == PoolMoveReport())

        let foreign = try Harness()
        try await interrupted(foreign, Backend(), phase: .preparing, claimed: false, newKeepOn: PoolKeepOn())
        _ = await PoolSetup(env: foreign.env()).settleMove()
        #expect(!foreign.recorder.commands.contains { $0.arguments.contains("mediabox") })
        #expect(PoolState.load(foreign.paths)?.move == nil)
    }

    private func launchOrder(_ harness: Harness) -> [String] {
        harness.recorder.commands.filter { $0.executable == "/bin/launchctl" }.map {
            let name = URL(fileURLWithPath: $0.arguments.last ?? "").lastPathComponent
            return ($0.arguments.first ?? "") + " " + (name.hasSuffix(".plist") ? String(name.dropLast(6)) : name)
        }
    }

    @Test func movesOffThisMac() async throws {
        let harness = try Harness()
        let backend = Backend()
        let before = try await moving(harness, backend, host: nil)
        let keychain = harness.env().keychain
        let access = try #require(keychain.read(service: Pool.accessService))
        let report = try await PoolSetup(env: harness.env()).move(to: .computer("mediabox"))
        #expect(report.sleep == .off && report.left == nil)
        let order = launchOrder(harness)
        let helperOut = try #require(order.firstIndex(of: "bootout com.relaybar.helper"))
        let tunnelIn = try #require(order.firstIndex(of: "bootstrap com.relaybar.helper-tunnel"))
        #expect(helperOut < tunnelIn)
        let state = try #require(PoolState.load(harness.paths))
        #expect(state.ssh == "mediabox" && state.move == nil && !state.joined)
        #expect(state.steps.starts(with: [.keychainAccessKey, .keychainManagementSecret, .remoteHelper, .keepOn, .tunnelAgent]))
        for step in [PoolStep.helperFolder, .helperAgent, .updateAgent] { #expect(!state.steps.contains(step)) }
        for step in [PoolStep.terminalCommands, .t3Entries, .t3Default, .t3UsageSource] { #expect(state.steps.contains(step)) }
        #expect(state.previousSelection == before.previousSelection && state.usageSourceAdded)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.helper.path))
        for label in [Pool.helperLabel, Pool.updateLabel] {
            #expect(!FileManager.default.fileExists(atPath: harness.paths.agent(label).path))
        }
        #expect(!FileManager.default.fileExists(atPath: harness.paths.updateScript.path))
        #expect(backend.served == "mediabox" && tunnelText(harness).contains("<string>mediabox</string>"))
        #expect(keychain.read(service: Pool.accessService) == access)
        let config = harness.recorder.commands.first { remoteScript($0).contains("cat > ") && remoteScript($0).contains("/config.yaml") }
        let written = String(decoding: config?.stdin ?? Data(), as: UTF8.self)
        #expect(written.contains(access))
        #expect(
            !harness.recorder.commands.contains { $0.executable == "/usr/bin/security" && $0.arguments.first == "delete-generic-password" })
    }

    @Test func movesOntoThisMac() async throws {
        let harness = try Harness()
        let backend = Backend()
        let before = try await moving(harness, backend, host: "homebox")
        let keychain = harness.env().keychain
        let access = try #require(keychain.read(service: Pool.accessService))
        let progress = Messages()
        let report = try await PoolSetup(env: harness.env()).move(to: .thisMac, progress: { progress.texts.append($0) })
        #expect(report.sleep == nil && report.left == nil)
        let order = launchOrder(harness)
        let tunnelOut = try #require(order.firstIndex(of: "bootout com.relaybar.helper-tunnel"))
        let helperIn = try #require(order.firstIndex(of: "bootstrap com.relaybar.helper"))
        #expect(tunnelOut < helperIn)
        let texts = progress.texts
        let downloaded = try #require(texts.firstIndex(of: "Downloading and checking the helper"))
        let started = try #require(texts.firstIndex(of: "Starting the helper on this Mac"))
        let stages = texts.compactMap { PoolMoveStage(progress: $0) }
        #expect(downloaded < started && stages == [.prepare, .prepare, .connect, .remove])
        let installed = try #require(
            harness.recorder.commands.firstIndex { $0.executable == "/bin/sh" && $0.arguments.dropFirst().first == "install" })
        let bootout = try #require(
            harness.recorder.commands.firstIndex {
                $0.executable == "/bin/launchctl" && ($0.arguments.last ?? "").hasSuffix(Pool.tunnelLabel)
            })
        #expect(bootout < installed)
        let state = try #require(PoolState.load(harness.paths))
        #expect(state.runsOnThisMac && state.tailscale == nil && state.move == nil && state.keepOn.isEmpty)
        #expect(
            state.steps.starts(with: [
                .keychainAccessKey, .keychainManagementSecret, .helperFolder, .helperAgent, .updateAgent, .terminalCommands,
            ]))
        for step in [PoolStep.tunnelAgent, .remoteHelper, .keepOn] { #expect(!state.steps.contains(step)) }
        #expect(state.steps.contains(.t3Entries) && state.previousSelection == before.previousSelection)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.agent(Pool.tunnelLabel).path))
        #expect(FileManager.default.fileExists(atPath: harness.paths.agent(Pool.helperLabel).path))
        #expect(try String(contentsOf: harness.paths.config, encoding: .utf8).contains(access))
        #expect(backend.served == "this Mac")
        let old = harness.recorder.commands.filter { $0.arguments.contains("homebox") }.map(remoteScript)
        #expect(old.contains { $0.contains("rm -rf \"$HOME/.local/share/relaybar-helper\"") })
        #expect(old.contains { $0.contains("systemctl unmask sleep.target") })
        #expect(keychain.read(service: Pool.accessService) == access)
    }

    @Test func pausesTheSameAccountsAgain() async throws {
        let harness = try seeded()
        let secret = String(repeating: "b2", count: 32)
        let helper = Credentials([("claude", "ann@example.com"), ("claude", "bob@example.com"), ("codex", "cy@example.com")])
        harness.http.handler = helper.handler(secret: secret)
        var state = try #require(PoolState.load(harness.paths))
        state.order = ["claude": ["bob@example.com", "ann@example.com"]]
        state.orderMode = .manual
        try state.save(harness.paths)
        let paused = PoolCredential(name: "x", authIndex: "i", email: "Bob@Example.com", kind: .claude, disabled: true, status: "disabled")
        let live = PoolCredential(name: "y", authIndex: "j", email: "ann@example.com", kind: .claude, disabled: false, status: "active")
        let members = [PoolMember(credential: paused, state: .paused), PoolMember(credential: live, state: .unavailable)]
        let emails = PoolMove.pausedEmails(in: members)
        #expect(emails == ["bob@example.com"])
        try await PoolSetup(env: harness.env()).pauseAgain(emails: emails)
        let status = helper.patches.filter { $0.path == "credentials/status" }
        #expect(status.count == 1)
        #expect(status[0].body["name"] as? String == "claude-bob@example.com.json" && status[0].body["disabled"] as? Bool == true)
        let priorities = helper.patches.filter { $0.path == "credentials/fields" }
        #expect(priorities.contains { $0.body["name"] as? String == "claude-bob@example.com.json" && $0.body["priority"] as? Int == 2 })
        #expect(priorities.contains { $0.body["name"] as? String == "claude-ann@example.com.json" && $0.body["priority"] as? Int == 1 })
        #expect(PoolState.load(harness.paths)?.order["claude"] == ["bob@example.com", "ann@example.com"])

        let none = Credentials([("claude", "ann@example.com"), ("claude", "bob@example.com")])
        harness.http.handler = none.handler(secret: secret)
        try await PoolSetup(env: harness.env()).pauseAgain(emails: [])
        #expect(none.patches.filter { $0.path == "credentials/status" }.isEmpty)
        #expect(!none.patches.filter { $0.path == "credentials/fields" }.isEmpty)

        let last = Credentials([("claude", "ann@example.com")])
        harness.http.handler = last.handler(secret: secret)
        try await PoolSetup(env: harness.env()).pauseAgain(emails: ["ann@example.com"])
        #expect(last.patches.filter { $0.path == "credentials/status" }.isEmpty)
    }

    private func clientCommands(_ harness: Harness, _ host: String) -> [Command] {
        harness.recorder.commands.filter { $0.arguments.contains(host) }
    }

    @Test func pointsAddedComputersAtTheNewHub() async throws {
        let harness = try Harness()
        let backend = Backend()
        try await combined(harness, backend)
        var state = try #require(PoolState.load(harness.paths))
        var client = PoolLinuxClient(host: "linuxpc", folders: [".config/relaybar"])
        client.hubKey = true
        client.hubCreated = ["keys"]
        state.linuxClients = [client]
        state.steps.append(.linuxClient)
        try state.save(harness.paths)
        harness.recorder.removeCommands()
        wire(harness, backend, computers: FakeClientHost())
        let progress = Messages()
        let report = try await PoolSetup(env: harness.env()).move(to: .computer("mediabox"), progress: { progress.texts.append($0) })
        #expect(report.computersLeft.isEmpty && report.left == nil)
        let saved = try #require(PoolState.load(harness.paths))
        #expect(saved.linuxClients.count == 1 && !saved.linuxClients[0].needsRepoint && saved.linuxClients[0].hubKey)
        #expect(saved.linuxClients[0].hubCreated.isEmpty)
        #expect(saved.steps.contains(.linuxClient) && saved.move == nil)
        let toHub = clientCommands(harness, "mediabox")
        let keyAdd = try #require(toHub.first { remoteScript($0).contains("cat >> ") })
        let line = String(decoding: keyAdd.stdin ?? Data(), as: UTF8.self)
        #expect(line.contains("permitopen=\"127.0.0.1:8317\"") && line.contains("ssh-ed25519 AAAAclientkey relaybar-client:linuxpc"))
        let toClient = clientCommands(harness, "linuxpc")
        let hosts = try #require(toClient.first { remoteScript($0).contains("/known_hosts") && $0.stdin != nil })
        #expect(String(decoding: hosts.stdin ?? Data(), as: UTF8.self).contains("192.168.1.20 ssh-ed25519 AAAAhubkey"))
        let unit = try #require(toClient.first { remoteScript($0).contains("relaybar-tunnel.service") && $0.stdin != nil })
        let unitText = String(decoding: unit.stdin ?? Data(), as: UTF8.self)
        #expect(unitText.contains("sam@$$a") && unitText.contains("192.168.1.20") && unitText.contains("100.64.0.7"))
        #expect(toClient.contains { remoteScript($0).contains("systemctl --user restart relaybar-tunnel.service") })
        #expect(toClient.contains { remoteScript($0).contains("http_code") })
        let order = harness.recorder.commands.map(remoteScript)
        let restart = try #require(order.firstIndex { $0.contains("restart relaybar-tunnel.service") })
        let cleanup = try #require(order.firstIndex { $0.contains("rm -rf \"$HOME/.local/share/relaybar-helper\"") })
        #expect(restart < cleanup)
        let removals = harness.recorder.commands.filter { plainScript($0).contains("awk '$NF ~ /^relaybar-client:/") }
        #expect(removals.count == 1 && removals[0].arguments.contains("homebox"))
        #expect(progress.texts.contains("Pointing linuxpc at mediabox"))
    }

    @Test func keepsAComputerPendingWhenTheHubChangesDuringItsRepoint() async throws {
        let harness = try Harness()
        var state = PoolState(ssh: "mediabox")
        state.steps = [.keychainAccessKey, .keychainManagementSecret, .remoteHelper, .tunnelAgent, .linuxClient]
        var client = PoolLinuxClient(host: "linuxpc", folders: [".config/relaybar"])
        client.needsRepoint = true
        state.linuxClients = [client]
        try state.save(harness.paths)
        let computers = FakeClientHost()
        let paths = harness.paths
        harness.recorder.respond = { command in
            let text = remoteScript(command)
            if text.contains("hub_key.pub") { return CommandResult(output: "ssh-ed25519 AAAAclientkey\n") }
            if text == "command -v ssh" { return CommandResult(output: "/usr/bin/ssh\n") }
            if text.contains("restart relaybar-tunnel.service"), var latest = PoolState.load(paths) {
                latest.ssh = "workbox"
                latest.linuxClients[0].needsRepoint = true
                try? latest.save(paths)
            }
            return computers.answer(command) ?? CommandResult()
        }
        let report = await PoolSetup(env: harness.env()).settleMove()
        #expect(report.computersLeft == ["linuxpc"])
        let saved = try #require(PoolState.load(harness.paths))
        #expect(saved.ssh == "workbox" && saved.linuxClients.map(\.needsRepoint) == [true])
    }

    @Test func retriesAnAddedComputerThatWasOff() async throws {
        let harness = try Harness()
        let backend = Backend()
        try await combined(harness, backend)
        var state = try #require(PoolState.load(harness.paths))
        state.linuxClients = [PoolLinuxClient(host: "linuxpc", folders: [".config/relaybar"])]
        state.steps.append(.linuxClient)
        try state.save(harness.paths)
        let switches = Switches()
        switches.turnOff("linuxpc")
        wire(harness, backend, computers: FakeClientHost(), switches: switches)
        let setup = PoolSetup(env: harness.env())
        let report = try await setup.move(to: .computer("mediabox"))
        #expect(report.computersLeft == ["linuxpc"])
        var saved = try #require(PoolState.load(harness.paths))
        #expect(saved.ssh == "mediabox" && saved.move == nil)
        #expect(saved.linuxClients.map(\.needsRepoint) == [true])
        let stillOff = await setup.settleMove()
        #expect(stillOff.computersLeft == ["linuxpc"])
        switches.turnOn("linuxpc")
        harness.recorder.removeCommands()
        let back = await setup.settleMove()
        #expect(back == PoolMoveReport())
        saved = try #require(PoolState.load(harness.paths))
        #expect(saved.linuxClients.map(\.needsRepoint) == [false])
        #expect(clientCommands(harness, "mediabox").contains { remoteScript($0).contains("cat >> ") })
        #expect(!harness.recorder.commands.contains { remoteScript($0).contains("rm -rf") })
        harness.recorder.removeCommands()
        let idle = await setup.settleMove()
        #expect(idle == PoolMoveReport() && harness.recorder.commands.isEmpty)
    }

    private func afterSwitch(_ harness: Harness) throws {
        var state = PoolState(ssh: "mediabox")
        state.steps = [.keychainAccessKey, .keychainManagementSecret, .remoteHelper, .tunnelAgent]
        state.move = PoolMove(
            target: "mediabox", phase: .switched,
            old: PoolMoveOld(ssh: "homebox", tailscale: "100.64.0.7", keepOn: PoolKeepOn(linger: true, masked: ["sleep.target"])),
            claimed: true)
        try state.save(harness.paths)
    }

    private func oldComputer(_ harness: Harness, answers: @escaping @Sendable (Command) -> CommandResult) {
        harness.recorder.respond = { command in
            command.arguments.contains("homebox") ? answers(command) : CommandResult()
        }
    }

    @Test func cleansTheOldComputer() async throws {
        let harness = try Harness()
        try afterSwitch(harness)
        oldComputer(harness) { command in
            command.arguments.contains("HostName=100.64.0.7") ? CommandResult(status: 255, error: "Connection timed out") : CommandResult()
        }
        let report = await PoolSetup(env: harness.env()).settleMove()
        #expect(report == PoolMoveReport())
        let ssh = harness.recorder.commands.filter { $0.executable == "/usr/bin/ssh" }
        let removal = ssh.filter { plainScript($0) == PoolTeardown.remoteRemoval }
        #expect(removal.count == 2)
        #expect(removal[0].arguments.contains("HostName=100.64.0.7") && !removal[1].arguments.contains("HostName=100.64.0.7"))
        #expect(removal.allSatisfy { $0.arguments.contains("homebox") })
        let restore = ssh.compactMap { command -> String? in
            let text = remoteScript(command)
            return text.contains("systemctl unmask sleep.target") ? text : nil
        }
        #expect(restore.contains { $0.contains("loginctl disable-linger") })
        #expect(!ssh.contains { $0.arguments.contains("mediabox") })
        #expect(PoolState.load(harness.paths)?.move == nil)
        #expect(PoolState.load(harness.paths)?.ssh == "mediabox")
    }

    @Test func cleansTheOldComputerWhenItIsBack() async throws {
        let harness = try Harness()
        try afterSwitch(harness)
        let switches = Switches()
        switches.turnOff("homebox")
        harness.recorder.respond = { command in
            command.arguments.contains("homebox") && switches.isOff("homebox")
                ? CommandResult(status: 255, error: "ssh: connect to host homebox port 22: Connection timed out") : CommandResult()
        }
        let setup = PoolSetup(env: harness.env())
        let first = await setup.settleMove()
        #expect(first.left == "homebox" && first.needsPassword == nil)
        var state = try #require(PoolState.load(harness.paths))
        #expect(state.move?.phase == .switched && state.move?.old?.ssh == "homebox" && state.move?.old?.tailscale == "100.64.0.7")
        #expect(PoolMove.action(for: state) == .finish)
        let second = await setup.settleMove()
        #expect(second.left == "homebox")
        switches.turnOn("homebox")
        harness.recorder.respond = { command in
            command.arguments.contains("homebox") && remoteScript(command).contains("systemctl unmask") && command.stdin == nil
                ? CommandResult(status: PoolRemote.needsPasswordStatus) : CommandResult()
        }
        let asked = await setup.settleMove()
        #expect(asked.needsPassword == "homebox" && asked.left == nil)
        state = try #require(PoolState.load(harness.paths))
        #expect(state.move?.old != nil)
        harness.recorder.respond = { _ in CommandResult() }
        let done = await setup.settleMove(sudoPassword: "pw")
        #expect(done == PoolMoveReport())
        #expect(harness.recorder.commands.contains { $0.stdin == Data("pw\n".utf8) && $0.arguments.contains("homebox") })
        state = try #require(PoolState.load(harness.paths))
        #expect(state.move == nil && state.ssh == "mediabox")
    }

    @Test func stopAlsoCleansAPendingOldComputer() async throws {
        let reachable = try Harness()
        try afterSwitch(reachable)
        let report = PoolSetup(env: reachable.env()).stop()
        #expect(report.finished && report.unreachable == nil)
        #expect(PoolState.load(reachable.paths) == nil)
        let hosts = Set(reachable.recorder.commands.filter { plainScript($0) == PoolTeardown.remoteRemoval }.flatMap { $0.arguments })
        #expect(hosts.contains("homebox") && hosts.contains("mediabox"))

        let off = try Harness()
        try afterSwitch(off)
        off.recorder.respond = { command in
            command.arguments.contains("homebox") ? CommandResult(status: 255, error: "Connection timed out") : CommandResult()
        }
        let setup = PoolSetup(env: off.env())
        let stuck = setup.stop()
        #expect(stuck.unreachable == "homebox" && !stuck.finished)
        let kept = try #require(PoolState.load(off.paths))
        #expect(kept.move?.old?.ssh == "homebox" && kept.steps.isEmpty)
        let forgot = setup.forgetRemote()
        #expect(forgot.finished)
        #expect(PoolState.load(off.paths) == nil)

        let preparing = try Harness()
        var half = PoolState(ssh: "homebox")
        half.steps = [.keychainAccessKey, .remoteHelper, .tunnelAgent]
        half.move = PoolMove(
            target: "mediabox", phase: .preparing, old: PoolMoveOld(ssh: "homebox", tailscale: nil, keepOn: PoolKeepOn()), claimed: true,
            newKeepOn: PoolKeepOn(linger: true))
        try half.save(preparing.paths)
        let both = PoolSetup(env: preparing.env()).stop()
        #expect(both.finished && PoolState.load(preparing.paths) == nil)
        let removed = preparing.recorder.commands.filter { plainScript($0) == PoolTeardown.remoteRemoval }.flatMap { $0.arguments }
        #expect(removed.contains("mediabox") && removed.contains("homebox"))
        #expect(preparing.recorder.commands.contains { $0.arguments.contains("mediabox") && remoteScript($0).contains("disable-linger") })
    }

    private func joinedMac(_ secrets: PoolSecrets) throws -> (Harness, Backend) {
        let harness = try seeded(joined: true)
        let keychain = harness.env().keychain
        _ = keychain.store(service: Pool.accessService, secret: secrets.accessKey)
        _ = keychain.store(service: Pool.managementService, secret: secrets.managementSecret)
        var state = try #require(PoolState.load(harness.paths))
        state.steps = [.keychainAccessKey, .keychainManagementSecret, .tunnelAgent, .terminalCommands]
        try state.save(harness.paths)
        try PoolFile.write(
            Data(PoolTunnel.plist(paths: harness.paths, destination: "homebox").utf8), to: harness.paths.agent(Pool.tunnelLabel),
            backup: false)
        let backend = Backend()
        backend.apply(Command("/bin/launchctl", ["bootstrap", "gui/501", harness.paths.agent(Pool.tunnelLabel).path]))
        harness.http.handler = backend.handler(accessKey: { secrets.accessKey })
        harness.recorder.removeCommands()
        return (harness, backend)
    }

    private func joinFile(_ secrets: PoolSecrets) -> String {
        String(
            decoding: json(["accessKey": secrets.accessKey, "managementSecret": secrets.managementSecret]), as: UTF8.self)
    }

    private func answerHosts(_ harness: Harness, backend: Backend, files: [String: String], home: Set<String> = []) {
        harness.recorder.respond = { command in
            backend.apply(command)
            if command.arguments.first == "-G" {
                return CommandResult(
                    output: home.contains(command.arguments.last ?? "") ? "hostname 203.0.113.9\n" : "hostname 192.168.1.20\n")
            }
            let host = command.arguments.dropLast().last ?? ""
            guard command.executable == "/usr/bin/ssh", let file = files[host] else {
                return command.executable == "/usr/bin/ssh" ? CommandResult(status: 255, error: "Connection refused") : CommandResult()
            }
            return CommandResult(output: remoteScript(command).hasPrefix("test -f") ? "pool\n" : file)
        }
    }

    @Test func aJoinedMacFindsTheMovedHelper() async throws {
        let mine = PoolSecrets(accessKey: String(repeating: "a1", count: 32), managementSecret: String(repeating: "b2", count: 32))
        let other = PoolSecrets(accessKey: String(repeating: "c3", count: 32), managementSecret: String(repeating: "d4", count: 32))
        let (harness, backend) = try joinedMac(mine)
        answerHosts(
            harness, backend: backend,
            files: ["workbox": joinFile(other), "mediabox": joinFile(mine), "linuxpc": "not json"], home: ["faraway"])
        let setup = PoolSetup(env: harness.env())
        let offer = await setup.findMovedHelper(hosts: ["homebox", "faraway", "linuxpc", "workbox", "mediabox"])
        #expect(offer == PoolJoinOffer(host: "mediabox"))
        #expect(!harness.recorder.commands.contains { $0.executable == "/usr/bin/security" && $0.arguments == ["-i"] })
        let probes = harness.recorder.commands.filter { $0.arguments.first != "-G" }
        #expect(!probes.contains { $0.arguments.contains("homebox") || $0.arguments.contains("faraway") })
        let none = await setup.findMovedHelper(hosts: ["workbox", "linuxpc"])
        #expect(none == nil)
        let before = try #require(PoolState.load(harness.paths))
        try await setup.follow(host: "mediabox")
        let state = try #require(PoolState.load(harness.paths))
        #expect(state.ssh == "mediabox" && state.tailscale == nil && state.joined)
        #expect(state.steps == before.steps)
        #expect(tunnelText(harness).contains("<string>mediabox</string>") && backend.served == "mediabox")
        let keychain = harness.env().keychain
        #expect(keychain.read(service: Pool.accessService) == mine.accessKey)
        let files = try FileManager.default.subpathsOfDirectory(atPath: harness.paths.appSupport.path)
        for file in files where !file.hasSuffix("/") {
            let text = try? String(contentsOf: harness.paths.appSupport.appendingPathComponent(file), encoding: .utf8)
            #expect(text?.contains(other.accessKey) != true)
        }
    }

    @Test func aJoinedMacPointsItsOwnComputersAtTheMovedHelper() async throws {
        let mine = PoolSecrets(accessKey: String(repeating: "a1", count: 32), managementSecret: String(repeating: "b2", count: 32))
        let (harness, backend) = try joinedMac(mine)
        var state = try #require(PoolState.load(harness.paths))
        var client = PoolLinuxClient(host: "linuxpc", folders: [".config/relaybar"])
        client.hubKey = true
        state.linuxClients = [client]
        state.steps.append(.linuxClient)
        try state.save(harness.paths)
        let computers = FakeClientHost()
        let file = joinFile(mine)
        harness.recorder.respond = { command in
            backend.apply(command)
            guard command.executable == "/usr/bin/ssh" else { return CommandResult() }
            let text = remoteScript(command)
            if text.contains("join.json\"") { return CommandResult(output: text.hasPrefix("test -f") ? "pool\n" : file) }
            if text.contains("hub_key.pub") { return CommandResult(output: "ssh-ed25519 AAAAclientkey\n") }
            if text == "command -v ssh" { return CommandResult(output: "/usr/bin/ssh\n") }
            return computers.answer(command) ?? CommandResult()
        }
        let left = try await PoolSetup(env: harness.env()).follow(host: "mediabox")
        #expect(left.isEmpty)
        let saved = try #require(PoolState.load(harness.paths))
        #expect(saved.ssh == "mediabox" && saved.joined && saved.linuxClients.map(\.needsRepoint) == [false])
        let toHub = harness.recorder.commands.filter { $0.arguments.contains("mediabox") }
        let keyAdd = try #require(toHub.first { remoteScript($0).contains("cat >> ") })
        #expect(String(decoding: keyAdd.stdin ?? Data(), as: UTF8.self).contains("relaybar-client:linuxpc"))
        #expect(
            harness.recorder.commands.contains {
                $0.arguments.contains("linuxpc") && remoteScript($0).contains("restart relaybar-tunnel.service")
            })
    }

    @Test func aJoinedMacRefusesADifferentHelper() async throws {
        let mine = PoolSecrets(accessKey: String(repeating: "a1", count: 32), managementSecret: String(repeating: "b2", count: 32))
        let other = PoolSecrets(accessKey: String(repeating: "c3", count: 32), managementSecret: String(repeating: "d4", count: 32))
        let sameKeyOtherSecret = PoolSecrets(accessKey: mine.accessKey, managementSecret: other.managementSecret)
        let (harness, backend) = try joinedMac(mine)
        answerHosts(
            harness, backend: backend,
            files: ["workbox": joinFile(other), "tricky": joinFile(sameKeyOtherSecret), "mediabox": joinFile(mine)])
        let setup = PoolSetup(env: harness.env())
        let before = try #require(PoolState.load(harness.paths))
        let plist = tunnelText(harness)
        await #expect(throws: PoolMoveError.differentSetup) { try await setup.follow(host: "workbox") }
        await #expect(throws: PoolMoveError.differentSetup) { try await setup.follow(host: "tricky") }
        #expect(PoolMoveError.differentSetup.errorDescription == "That computer runs a different setup. Use Stop combining, then join it.")
        #expect(PoolState.load(harness.paths) == before && tunnelText(harness) == plist && backend.served == "homebox")
        backend.refuse = "mediabox"
        await #expect(throws: PoolSetupError.notAnswering) { try await setup.follow(host: "mediabox") }
        backend.refuse = nil
        #expect(PoolState.load(harness.paths) == before && tunnelText(harness) == plist && backend.served == "homebox")
        await #expect(throws: PoolInputError.self) { try await setup.follow(host: "-x") }
        let owner = try seeded()
        await #expect(throws: PoolSetupError.notCombining) { try await PoolSetup(env: owner.env()).follow(host: "mediabox") }
    }

    @Test func saysWhetherTheOldComputerAnswers() throws {
        let harness = try seeded(tailscale: "100.64.0.7")
        harness.recorder.respond = { command in
            command.arguments.contains("HostName=100.64.0.7") ? CommandResult(status: 255) : CommandResult()
        }
        #expect(PoolSetup(env: harness.env()).oldComputerAnswers())
        harness.recorder.respond = { _ in CommandResult(status: 255, error: "Connection timed out") }
        #expect(!PoolSetup(env: harness.env()).oldComputerAnswers())
        let local = try seeded(ssh: nil)
        #expect(PoolSetup(env: local.env()).oldComputerAnswers())
        #expect(!PoolSetup(env: try Harness().env()).oldComputerAnswers())
    }

    @Test func movingOntoThisMacWarnsAndDoesNotPromiseAReconnect() {
        let home = PoolMove.doneText(target: "mediabox", computers: ["linuxpc"], old: "homebox", pending: false)
        #expect(home.contains("This Mac and linuxpc use mediabox now."))
        #expect(home.contains("Relaybar removed the helper and its logins from homebox."))
        #expect(home.contains("Other Macs that use your accounts reconnect in one click."))
        let late = PoolMove.doneText(target: "mediabox", computers: [], old: "homebox", pending: true)
        #expect(late.contains("It removes the helper and its logins from homebox when it is back."))
        let here = PoolMove.doneText(target: nil, computers: [], old: "homebox", pending: false)
        #expect(here.contains("This Mac runs the helper now."))
        #expect(!here.contains("reconnect") && !here.contains("Other Macs that use"))
        #expect(here.contains("Other Macs and computers that use these accounts stop working."))
        let warning = PoolMove.thisMacWarning(computers: [])
        #expect(warning.contains("Other Macs and computers that use these accounts stop working."))
        #expect(!warning.contains("Computers first"))
        let listed = PoolMove.thisMacWarning(computers: ["linuxpc", "workbox"])
        #expect(listed.contains("Relaybar removes linuxpc and workbox from Computers first."))
    }

    private func harnessRespondsFree(_ harness: Harness) {
        harness.recorder.respond = { _ in CommandResult(output: "000") }
    }
}
