import Foundation

public enum PoolFileError: Error, Equatable, LocalizedError {
    case link(String)
    case notRelaybars(String)

    public var errorDescription: String? {
        switch self {
        case .link(let path):
            return "\(path) is a link. Relaybar never writes through a link. Replace it with a real file or folder, then try again."
        case .notRelaybars(let path):
            return "\(path) already exists and Relaybar did not write it, so Relaybar left it alone. Rename or remove it, then try again."
        }
    }
}

public enum PoolFile {
    public static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    public static func makeFolder(_ url: URL, secret: Bool = false) throws {
        if isLink(url) { throw PoolFileError.link(url.path) }
        let manager = FileManager.default
        var missing: [URL] = []
        var cursor = url
        while !manager.fileExists(atPath: cursor.path) {
            missing.append(cursor)
            cursor = cursor.deletingLastPathComponent()
        }
        for folder in missing.reversed() {
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            if secret { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        }
    }

    public static func write(
        _ data: Data, to url: URL, secret: Bool = false, executable: Bool = false, backup: Bool = true
    ) throws {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        if isLink(url) { throw PoolFileError.link(url.path) }
        try makeFolder(folder, secret: secret)
        if backup, manager.fileExists(atPath: url.path) {
            let copy = url.appendingPathExtension("relaybar-backup")
            if !manager.fileExists(atPath: copy.path) { try manager.copyItem(at: url, to: copy) }
        }
        let mode = secret ? 0o600 : (executable ? 0o755 : 0o644)
        let temporary = folder.appendingPathComponent(".relaybar-" + UUID().uuidString)
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? manager.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public static let marker = "Written by Relaybar"

    public static func writeOwned(_ text: String, to url: URL, executable: Bool = false) throws {
        if let existing = contents(url), !existing.contains(marker) { throw PoolFileError.notRelaybars(url.path) }
        try write(Data(text.utf8), to: url, executable: executable, backup: false)
    }

    public static func isOwned(_ url: URL) -> Bool {
        contents(url)?.contains(marker) == true
    }

    public static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public static func contents(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}
