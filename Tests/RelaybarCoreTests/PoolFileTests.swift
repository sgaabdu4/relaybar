import Foundation
import Testing

@testable import RelaybarCore

struct PoolFileTests {
    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
    }

    @Test func refusesToWriteThroughALink() throws {
        let home = try Fixture()
        try home.write("real/file.txt", "keep")
        try FileManager.default.createSymbolicLink(
            at: home.root.appendingPathComponent("link.txt"), withDestinationURL: home.root.appendingPathComponent("real/file.txt"))
        #expect(throws: PoolFileError.link(home.root.appendingPathComponent("link.txt").path)) {
            try PoolFile.write(Data("new".utf8), to: home.root.appendingPathComponent("link.txt"))
        }
        try FileManager.default.createSymbolicLink(
            at: home.root.appendingPathComponent("linked-folder"), withDestinationURL: home.root.appendingPathComponent("real"))
        #expect(throws: PoolFileError.self) {
            try PoolFile.write(Data("new".utf8), to: home.root.appendingPathComponent("linked-folder/other.txt"))
        }
        #expect(throws: PoolFileError.self) { try PoolFile.makeFolder(home.root.appendingPathComponent("linked-folder")) }
        #expect(try String(contentsOf: home.root.appendingPathComponent("real/file.txt"), encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: home.root.appendingPathComponent("real/other.txt").path))
        #expect(PoolFileError.link("/x").errorDescription?.contains("/x") == true)
    }

    @Test func backsUpBeforeEditing() throws {
        let home = try Fixture()
        let file = home.root.appendingPathComponent("config.toml")
        try PoolFile.write(Data("one".utf8), to: file)
        #expect(!FileManager.default.fileExists(atPath: file.path + ".relaybar-backup"))
        try PoolFile.write(Data("two".utf8), to: file)
        try PoolFile.write(Data("three".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "three")
        #expect(try String(contentsOfFile: file.path + ".relaybar-backup", encoding: .utf8) == "one")
        let plain = home.root.appendingPathComponent("plain.txt")
        try PoolFile.write(Data("a".utf8), to: plain, backup: false)
        try PoolFile.write(Data("b".utf8), to: plain, backup: false)
        #expect(!FileManager.default.fileExists(atPath: plain.path + ".relaybar-backup"))
    }

    @Test func secretFilesArePrivate() throws {
        let home = try Fixture()
        let file = home.root.appendingPathComponent("a/b/key.bin")
        try PoolFile.write(Data("k".utf8), to: file, secret: true)
        #expect(try mode(file) == 0o600)
        #expect(try mode(file.deletingLastPathComponent()) == 0o700)
        #expect(try mode(file.deletingLastPathComponent().deletingLastPathComponent()) == 0o700)
        let script = home.root.appendingPathComponent("run.sh")
        try PoolFile.write(Data("x".utf8), to: script, executable: true)
        #expect(try mode(script) == 0o755)
    }

    @Test func writesOwnedFilesOnly() throws {
        let home = try Fixture()
        let file = home.root.appendingPathComponent("bin/claude-all")
        try PoolFile.writeOwned("#!/bin/sh\n# \(PoolFile.marker).\n", to: file, executable: true)
        #expect(PoolFile.isOwned(file))
        try PoolFile.writeOwned("#!/bin/sh\n# \(PoolFile.marker).\nnew\n", to: file)
        let foreign = home.root.appendingPathComponent("bin/codex-all")
        try Data("mine".utf8).write(to: foreign)
        #expect(throws: PoolFileError.notRelaybars(foreign.path)) { try PoolFile.writeOwned("x", to: foreign) }
        #expect(!PoolFile.isOwned(foreign))
        #expect(PoolFileError.notRelaybars("/y").errorDescription?.contains("/y") == true)
        PoolFile.remove(file)
        #expect(PoolFile.contents(file) == nil)
    }
}
