import Foundation

public enum PoolSSHSetup {
    public static func needsKey(_ message: String) -> Bool {
        message.hasPrefix(PoolHubPicker.keyProblem)
    }

    public static func hasKey(in folder: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { $0.hasPrefix("id_") && $0.hasSuffix(".pub") }
    }

    public static func copyCommand(host typed: String) throws -> String {
        "ssh-copy-id " + Shell.quote(try PoolHubPicker.validate(typed))
    }

    public static func prepare(home: URL, run: CommandRunner) -> Bool {
        let folder = home.appendingPathComponent(".ssh")
        if hasKey(in: folder) { return true }
        if !FileManager.default.fileExists(atPath: folder.path) {
            guard (try? PoolFile.makeFolder(folder, secret: true)) != nil else { return false }
        }
        let key = folder.appendingPathComponent("id_ed25519")
        return run(Command("/usr/bin/ssh-keygen", ["-t", "ed25519", "-N", "", "-C", "relaybar", "-f", key.path])).succeeded
    }
}
