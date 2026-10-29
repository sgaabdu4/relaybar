import Foundation

public enum PoolInstallError: Error, Equatable, LocalizedError {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let reason):
            return "The helper could not be installed (\(reason)). Nothing was changed. Check the internet connection, then try again."
        }
    }
}

public enum PoolInstall {
    public static func command(paths: PoolPaths) -> Command {
        Command(
            "/bin/sh", [paths.updateScript.path, "install", paths.helper.path], environment: Pool.scriptEnvironment,
            limit: 900)
    }

    public static func install(paths: PoolPaths, run: CommandRunner) throws {
        let result = run(command(paths: paths))
        guard result.succeeded else {
            let reason = result.error.split(separator: "\n").last.map(String.init) ?? "the download was refused."
            throw PoolInstallError.failed(reason.hasPrefix("failed: ") ? String(reason.dropFirst(8)) : reason)
        }
    }

    public static func sandboxProfile(paths: PoolPaths) -> String {
        let versions = quote(paths.helper.appendingPathComponent("versions").path)
        return """
            (version 1)
            (allow default)
            (deny file-read* file-write* (subpath "\(quote(paths.home.path))"))
            (allow file-read* file-write* (subpath "\(quote(paths.helper.path))"))
            (deny file-write* (subpath "\(versions)"))
            (allow file-read-metadata (literal "\(quote(paths.home.path))"))
            (deny process-exec*)
            (allow process-exec* (subpath "\(versions)"))
            (deny process-fork)
            (deny appleevent-send)
            (deny mach-lookup (global-name "com.apple.SecurityServer") (global-name "com.apple.securityd.xpc") (global-name "com.apple.secd") (global-name "com.apple.security.keychaind") (global-name "com.apple.coreservices.launchservicesd") (global-name "com.apple.lsd.mapdb") (global-name "com.apple.coreservices.quarantine-resolver"))
            (deny file-write* (subpath "/private/tmp") (subpath "/tmp") (subpath "/Users/Shared"))

            """
    }

    public static func helperPlist(paths: PoolPaths) -> String {
        plist(
            label: Pool.helperLabel,
            arguments: ["/usr/bin/sandbox-exec", "-f", paths.sandbox.path, paths.binary.path, "-config", paths.config.path],
            workingDirectory: paths.helper.path, keepAlive: true)
    }

    public static func updatePlist(paths: PoolPaths) -> String {
        plist(
            label: Pool.updateLabel, arguments: ["/bin/sh", paths.updateScript.path, "update", paths.helper.path],
            workingDirectory: paths.appSupport.path, keepAlive: false, runAtLoad: false,
            extra:
                "    <key>StartCalendarInterval</key>\n    <dict>\n        <key>Hour</key>\n        <integer>4</integer>\n        <key>Minute</key>\n        <integer>0</integer>\n    </dict>\n"
        )
    }

    static func plist(
        label: String, arguments: [String], workingDirectory: String, keepAlive: Bool, runAtLoad: Bool = true, extra: String = ""
    ) -> String {
        let list = arguments.map { "        <string>\(xml($0))</string>\n" }.joined()
        let flag: (Bool) -> String = { $0 ? "<true/>" : "<false/>" }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(xml(label))</string>
                <key>ProgramArguments</key>
                <array>
            \(list)    </array>
                <key>WorkingDirectory</key>
                <string>\(xml(workingDirectory))</string>
                <key>KeepAlive</key>
                \(flag(keepAlive))
                <key>RunAtLoad</key>
                \(flag(runAtLoad))
                <key>StandardOutPath</key>
                <string>/dev/null</string>
                <key>StandardErrorPath</key>
                <string>/dev/null</string>
            \(extra)</dict>
            </plist>

            """
    }

    static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func quote(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
