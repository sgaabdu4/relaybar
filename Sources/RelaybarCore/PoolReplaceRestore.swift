import Foundation

extension PoolJoin {
    static func restoreLogins(_ remote: PoolRemote, client: PoolLinuxClient) throws -> [String] {
        guard !client.kept.isEmpty else { return [] }
        let folder = "$HOME/\(PoolReplace.keptFolder)"
        var left: [String] = []
        var moves: [String] = []
        var problem: Error?
        for file in client.kept {
            guard let name = PoolReplace.names[file.path] else { continue }
            if file.edited {
                do {
                    if try restoreEdited(remote, file: file, name: name) { left.append("~/\(PoolReplace.keptFolder)/\(name)") }
                } catch { problem = problem ?? error }
            } else {
                moves.append(
                    "[ -e \"\(folder)/\(name)\" ] && [ ! -e \"$HOME/\(file.path)\" ] && [ ! -L \"$HOME/\(file.path)\" ] "
                        + "&& mv \"\(folder)/\(name)\" \"$HOME/\(file.path)\"")
            }
        }
        var steps = moves + ["rmdir \"\(folder)\" 2>/dev/null"]
        for created in client.createdFolders where [".claude", ".codex"].contains(created) {
            steps.append("rmdir \"$HOME/\(created)\" 2>/dev/null")
        }
        try remote.execute(steps.joined(separator: "; ") + "; true")
        if let problem { throw problem }
        return left
    }

    private static func restoreEdited(_ remote: PoolRemote, file: PoolKeptFile, name: String) throws -> Bool {
        let copy = "\(PoolReplace.keptFolder)/\(name)"
        let f = "\"$HOME/\(file.path)\""
        let k = "\"$HOME/\(copy)\""
        let state = try remote.execute(
            "f=\(f); k=\(k); if [ -L \"$f\" ]; then echo link; elif [ ! -e \"$f\" ]; then echo none; "
                + "elif [ -e \"$k\" ] && cmp -s \"$f\" \"$k\"; then echo original; "
                + "else echo sha:$(sha256sum \"$f\" 2>/dev/null | cut -d' ' -f1); fi; [ -e \"$k\" ] && echo backup; true"
        ).split(whereSeparator: \.isNewline).map(String.init)
        let hasBackup = state.contains("backup")
        let current = state.first ?? "none"
        if current == "link" || current == "none" { return hasBackup }
        if current == "original" {
            try remote.execute("rm -f \(k); true")
            return false
        }
        if let hash = file.hash, current == "sha:" + hash {
            if !file.existed {
                try remote.execute("rm -f \(f); true")
                return false
            }
            guard hasBackup else { return false }
            try remote.execute("cp -p \(k) \(f) && rm -f \(k)")
            return false
        }
        guard let now = try readFile(remote, file.path) else { return hasBackup }
        let before = hasBackup ? try readFile(remote, copy) : nil
        let merged: Data?
        if file.path == PoolReplace.claudeSettings {
            merged = PoolReplace.claudeWithout(current: Data(now.utf8), original: before.map { Data($0.utf8) })
        } else {
            merged = Data(PoolReplace.codexWithout(current: now, original: before).utf8)
        }
        guard let merged else { return hasBackup }
        let empty =
            file.path == PoolReplace.claudeSettings
            ? (try? JSONSerialization.jsonObject(with: merged) as? [String: Any])?.isEmpty == true : merged.isEmpty
        if !file.existed, empty {
            try remote.execute("rm -f \(f); true")
            return false
        }
        try remote.execute(
            "f=\(f); t=\"$f.relaybar-new\"; cp -p \"$f\" \"$t\" && cat > \"$t\" && mv \"$t\" \"$f\" || { rm -f \"$t\"; exit 1; }",
            stdin: merged)
        return hasBackup
    }
}
