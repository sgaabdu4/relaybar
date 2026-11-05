import AppKit
import RelaybarCore

extension PoolController {
    var tailscaleOnThisMac: Bool { FileManager.default.fileExists(atPath: PoolTailscale.macCLI) }

    func autoSwitch() async {
        guard state?.needsTailscale == true, tailscaleOnThisMac else { return }
        let tailscale = PoolTailscale(env: environment())
        _ = await Task.detached { await tailscale.automaticSwitch() }.value
    }

    @objc func setUpTailscale() {
        guard !busy, let current = state, current.needsTailscale, let host = current.ssh else { return }
        busy = true
        let panel = PoolTailscalePanel(host: host)
        panel.show()
        let tailscale = PoolTailscale(env: environment())
        let hooks = PoolTailscaleHooks(
            install: { await Self.installPackage($0) },
            password: { wrong in await MainActor.run { PoolDialogs.tailscalePassword(host: host, wrong: wrong) } },
            report: { stage, stageState in Task { @MainActor in panel.set(stage, stageState) } })
        let task = Task {
            defer { busy = false }
            do {
                let outcome = try await tailscale.setUp(host: host, hooks: hooks)
                panel.close()
                await fetch()
                tell(outcome, host: host)
            } catch is CancellationError {
                panel.close()
            } catch {
                panel.close()
                app.show("Relaybar could not set up Tailscale", error.localizedDescription)
            }
        }
        panel.onCancel = {
            task.cancel()
            panel.close()
        }
    }

    private func tell(_ outcome: PoolSwitchOutcome, host: String) {
        switch outcome {
        case .switched:
            app.show(
                "Tailscale is ready", "Relaybar now reaches \(host) through Tailscale, so your combined accounts work away from home too.")
        case .stayed(.differentTailnet):
            app.show(
                "This Mac and \(host) use different Tailscale accounts",
                "Sign in to the same Tailscale account on both, then choose Use it away from home again. Your connection was left as it was."
            )
        case .stayed(.notAnswering), .notApplicable:
            app.show(
                "\(host) did not answer through Tailscale",
                "Your connection was left as it was. Check that \(host) is on, then choose Use it away from home again.")
        }
    }

    nonisolated static func installPackage(_ package: URL) async -> Bool {
        if Task.isCancelled { return false }
        await MainActor.run { NSApp.activate() }
        return await Task.detached { PoolProcess.run(PoolTailscale.installCommand(package: package)).succeeded }.value
    }
}
