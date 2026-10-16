import Foundation

public struct Launcher: Equatable, Sendable {
    public let app: String
    public let runtime: String?
    public let dataDir: String?
    public let isCodex: Bool

    public var targets: [String] {
        var targets = [app]
        if let runtime {
            let folder = (runtime as NSString).deletingLastPathComponent
            targets.append(folder.hasSuffix("-Runtime") ? folder : runtime)
        }
        if let dataDir { targets.append(dataDir) }
        return targets
    }

    public static func find(configDir: String, in applications: URL) -> Launcher? {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []
        for name in apps.sorted() where name.hasSuffix(".app") {
            let app = applications.appendingPathComponent(name).path
            guard let script = try? String(contentsOfFile: app + "/Contents/MacOS/launch", encoding: .utf8),
                let variable = ["CLAUDE_CONFIG_DIR", "CODEX_HOME"].first(where: { variable in
                    script.contains("\(variable)=\"\(configDir)\"") || script.contains("\(variable)='\(configDir)'")
                })
            else { continue }
            return Launcher(
                app: app, runtime: match(#"["']([^"']+\.app)/Contents/MacOS/"#, in: script),
                dataDir: match(#"--user-data-dir=["']([^"']+)["']"#, in: script), isCodex: variable == "CODEX_HOME")
        }
        return nil
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(found.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
