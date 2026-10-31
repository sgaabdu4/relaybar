import AppKit
import RelaybarCore

private final class MoveNotes: @unchecked Sendable {
    var unsigned: [String] = []
}

extension PoolController {
    @objc func moveHelper() {
        guard !busy, let state, state.canMoveHelper else { return }
        let env = environment()
        let config = paths.home.appendingPathComponent(".ssh/config")
        let hosts = PoolHubPicker.parseSSHConfig((try? String(contentsOf: config, encoding: .utf8)) ?? "")
        let services = CombineDialog.Services(
            discover: { await PoolHubPicker.discover(hosts: hosts, env: env) },
            check: { try await PoolHubPicker.check(typed: $0, env: env) },
            setUp: { [weak self] host in self?.setUpSSH(host) })
        let kept = loaded ? "Your paused accounts and order stay." : "Your order stays."
        let text =
            "Your accounts stop for a few minutes while you sign in to each one again on the new computer. \(kept) Other Macs and computers keep working."
        let skip = [state.ssh, state.tailscale].compactMap { $0 } + state.linuxClients.map(\.host)
        let dialog = CombineDialog(services: services, move: CombineDialog.Move(here: state.ssh, skip: skip, text: text))
        guard let choice = dialog.run() else { return }
        switch choice {
        case .thisMac: Task { await performMove(.thisMac) }
        case .computer(let host): Task { await performMove(.computer(host)) }
        case .another: break
        }
    }

    private func performMove(_ target: PoolMoveTarget) async {
        guard let start = state, start.canMoveHelper, !busy else { return }
        if target == .thisMac {
            let hosts = start.linuxClients.map(\.host)
            guard PoolDialogs.moveToThisMac(hosts: hosts) else { return }
            for host in hosts { await performRemoveComputer(host) }
            guard state?.linuxClients.isEmpty == true else { return }
        }
        let setup = PoolSetup(env: environment())
        if let old = start.ssh {
            var proceed = false
            while !proceed {
                if await Task.detached(operation: { setup.oldComputerAnswers() }).value {
                    proceed = true
                } else {
                    switch PoolDialogs.moveOldUnreachable(host: old) {
                    case .cancel: return
                    case .again: break
                    case .anyway: proceed = true
                    }
                }
            }
        }
        busy = true
        defer { busy = false }
        await runMove(to: target, from: start, setup: setup)
    }

    private func runMove(to target: PoolMoveTarget, from start: PoolState, setup: PoolSetup) async {
        var host: String?
        if case .computer(let name) = target { host = name }
        let computers = start.linuxClients.map(\.host)
        let old = start.ssh
        let title = "Moving to \(host ?? "this Mac")"
        let steps = Self.moveSteps(host: host, computers: host == nil ? [] : computers, old: old)
        let panel = PoolProgressPanel()
        panel.showSteps(title: title, steps: steps.map(\.text), current: 0)
        let paused = loaded ? PoolMove.pausedEmails(in: members) : []
        let notes = MoveNotes()
        var report = PoolMoveReport()
        let worked = await attempt(host: host, title: title, panel: panel) {
            report = try await setup.move(
                to: target,
                progress: { text in
                    guard let stage = PoolMoveStage(progress: text), let index = steps.firstIndex(where: { $0.stage == stage }) else {
                        return
                    }
                    Task { @MainActor in panel.advance(to: index) }
                },
                afterSwitch: { [weak self] in
                    guard let self else { return }
                    notes.unsigned = await self.signInAgain(
                        panel: panel, setup: setup, steps: steps, title: title, paused: paused)
                })
        }
        guard worked else {
            panel.close()
            clearCache()
            return await fetch()
        }
        var note: String?
        if report.sleep == .needsPassword, let host {
            panel.close()
            note = await keepOn(host: host, setup: setup)
        }
        var wrong = false
        while let name = report.needsPassword {
            panel.close()
            guard let password = PoolDialogs.restoreSleepPassword(host: name, wrong: wrong) else { break }
            wrong = true
            report = await setup.settleMove(sudoPassword: password)
        }
        panel.close()
        generation += 1
        clearCache()
        await fetch()
        var lines: [String] = []
        if let note { lines.append(note) }
        if !notes.unsigned.isEmpty {
            lines.append(
                "These accounts are not signed in yet: " + notes.unsigned.joined(separator: ", ")
                    + ". Click them in All accounts to sign in.")
        }
        if !report.computersLeft.isEmpty {
            lines.append(
                "Relaybar could not reach " + report.computersLeft.joined(separator: ", ")
                    + ". It points \(report.computersLeft.count == 1 ? "it" : "them") at the new computer when \(report.computersLeft.count == 1 ? "it is" : "they are") back."
            )
        }
        let pending = report.left != nil || report.needsPassword != nil
        let offer = old != nil && start.tailscale != nil && state?.needsTailscale == true
        let left = report.computersLeft
        let reached = computers.filter { !left.contains($0) }
        let wantsTailscale = PoolDialogs.moved(
            host: host, computers: host == nil ? [] : reached, old: old ?? "this Mac", pending: pending,
            note: lines.isEmpty ? nil : lines.joined(separator: "\n\n"), tailscale: offer)
        if wantsTailscale { setUpTailscale() }
    }

    private func signInAgain(panel: PoolProgressPanel, setup: PoolSetup, steps: [MoveStep], title: String, paused: [String]) async
        -> [String]
    {
        generation += 1
        clearCache()
        let ended = await signInAll(panel: panel, setup: setup, canStop: false)
        let next = (steps.firstIndex { $0.stage == .signIn } ?? 0) + 1
        panel.showSteps(title: title, steps: steps.map(\.text), current: min(next, steps.count - 1))
        let again = paused
        await Task.detached { try? await setup.pauseAgain(emails: again) }.value
        markKnown()
        return ended.unsigned
    }

    struct MoveStep {
        let stage: PoolMoveStage
        let text: String
    }

    static func moveSteps(host: String?, computers: [String], old: String?) -> [MoveStep] {
        var steps = [
            MoveStep(stage: .prepare, text: "Setting up the helper on \(host ?? "this Mac")"),
            MoveStep(stage: .connect, text: host.map { "Connecting this Mac to \($0)" } ?? "Starting the helper on this Mac"),
            MoveStep(stage: .signIn, text: "Sign in to each account"),
        ]
        if let host, !computers.isEmpty {
            steps.append(MoveStep(stage: .computers, text: "Pointing \(computers.joined(separator: ", ")) at \(host)"))
        }
        steps.append(MoveStep(stage: .remove, text: "Removing the helper from \(old ?? "this Mac")"))
        return steps
    }

    @objc func followMoved(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String, !busy else { return }
        Task { await follow(host) }
    }

    @objc func connectToNewComputer() {
        guard !busy, state?.joined == true,
            let typed = PoolDialogs.address(
                text: "", error: nil, title: "Where did your accounts move?",
                message: "Type the address or SSH name of the computer that now runs the helper.", accept: "Connect")
        else { return }
        Task { await follow(typed) }
    }

    private func follow(_ host: String) async {
        busy = true
        defer { busy = false }
        let title = "Connecting this Mac"
        let panel = PoolProgressPanel()
        panel.showSetup(title: title, message: "Connecting to \(host)")
        let setup = PoolSetup(env: environment())
        let worked = await attempt(host: host, title: title, panel: panel) { try await setup.follow(host: host) }
        panel.close()
        generation += 1
        clearCache()
        guard worked else { return await fetch() }
        await fetch()
        app.note("Connected to \(host)", "Your accounts moved there.", mark: .on)
    }
}
