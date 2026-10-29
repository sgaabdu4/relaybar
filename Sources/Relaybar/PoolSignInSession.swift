import AppKit
import RelaybarCore

struct SignInEnd {
    let stopped: Bool
    let unsigned: [String]
}

@MainActor
final class SignInSession {
    private let pool: PoolController
    private let panel: PoolProgressPanel
    private let management: PoolManagement
    private var ids: [String]
    private var done: Set<String> = []
    private var waiting: Int?
    private var link: URL?
    private var cancelling = false
    private var task: Task<Void, Never>?
    private var ended: CheckedContinuation<SignInEnd, Never>?
    private(set) var active = true

    init(pool: PoolController, panel: PoolProgressPanel, management: PoolManagement) {
        self.pool = pool
        self.panel = panel
        self.management = management
        ids = pool.app.accounts.map(\.id)
    }

    func run() async -> SignInEnd {
        panel.showSignIn(ids.compactMap(entry))
        panel.onAction = { [weak self] index, action in self?.handle(index, action) }
        panel.onAdd = { [weak self] in self?.pool.app.chooseAndAddAccount() }
        return await withCheckedContinuation { continuation in
            ended = continuation
            panel.onDone = { [weak self] in self?.end(stopped: false) }
            panel.onStop = { [weak self] in self?.end(stopped: true) }
        }
    }

    func accountsChanged() {
        let known = Set(ids)
        for account in pool.app.accounts where !known.contains(account.id) {
            ids.append(account.id)
            if let item = entry(account.id) { panel.append(item) }
        }
    }

    private func account(_ id: String) -> Account? {
        pool.app.accounts.first { $0.id == id }
    }

    private func entry(_ id: String) -> SignInEntry? {
        guard let account = account(id) else { return nil }
        return SignInEntry(
            name: account.menuName, email: account.label, logo: pool.app.logo(for: account),
            color: account.tint == .plain ? .labelColor : account.tint.color)
    }

    private func end(stopped: Bool) {
        guard let continuation = ended else { return }
        ended = nil
        active = false
        task?.cancel()
        pool.signing = false
        let unsigned = ids.filter { !done.contains($0) }.compactMap { account($0)?.menuName }
        continuation.resume(returning: SignInEnd(stopped: stopped, unsigned: unsigned))
    }

    private func handle(_ index: Int, _ action: SignInAction) {
        guard active, ids.indices.contains(index) else { return }
        switch action {
        case .signIn:
            guard waiting == nil else { return }
            guard !pool.signing else {
                return pool.app.show("A sign-in is already open", "Finish it in the browser, then try again.")
            }
            start(index)
        case .openAgain:
            Task { await reopen(index) }
        case .cancel:
            guard !cancelling else { return }
            cancelling = true
            let old = task
            old?.cancel()
            Task {
                await old?.value
                cancelling = false
                guard active, waiting == index else { return }
                task = nil
                waiting = nil
                pool.signing = false
                panel.set(index, .ready)
            }
        }
    }

    private func signInTool() -> PoolSignIn {
        PoolSignIn(
            management: management,
            open: { [weak self] url in
                Task { @MainActor in self?.link = url }
                _ = NSWorkspace.shared.open(url)
            })
    }

    private func reopen(_ index: Int) async {
        guard waiting == index, !cancelling else { return }
        if let link, await signInTool().isLive(link) {
            _ = NSWorkspace.shared.open(link)
            return
        }
        guard waiting == index, !cancelling else { return }
        let old = task
        old?.cancel()
        await old?.value
        guard active, waiting == index else { return }
        start(index)
    }

    private func start(_ index: Int) {
        guard let account = account(ids[index]) else { return }
        waiting = index
        link = nil
        pool.signing = true
        panel.set(index, .waiting)
        let tool = signInTool()
        let kind = pool.kind(of: account)
        let inputs = pool.inputs()
        let row = inputs.first { $0.id == account.id }
        task = Task { [weak self] in
            let outcome = await tool.signIn(kind: kind)
            guard !Task.isCancelled, let self, let row else { return }
            let result = await tool.settle(outcome, for: row, in: self.pool.inputs(), done: self.done)
            guard !Task.isCancelled else { return }
            self.finish(index, row: row, result: result)
        }
    }

    private func finish(_ index: Int, row: PoolAccountInput, result: SignInResult) {
        waiting = nil
        pool.signing = false
        switch result {
        case .credited(let id):
            done.insert(id)
            if let at = ids.firstIndex(of: id) { panel.set(at, .done) }
            if id != row.id { panel.set(index, .ready) }
        case .wrong(let email):
            panel.set(index, .problem("That was \(email). Sign in as \(row.email ?? row.name)."))
        case .unfinished(let outcome):
            panel.set(index, .problem(outcome == .timedOut ? "That took too long." : outcome.message))
        }
    }
}
