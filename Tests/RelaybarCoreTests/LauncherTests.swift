import Foundation
import Testing

@testable import RelaybarCore

struct LauncherTests {
    @Test func findsTheLauncherForAnAccount() throws {
        let apps = try Fixture()
        try apps.write(
            "Claude Work.app/Contents/MacOS/launch",
            """
            #!/bin/bash
            export CLAUDE_CONFIG_DIR="/h/.claude-work"
            exec "/h/Library/Application Support/Work-Claude-Runtime/Claude Work.app/Contents/MacOS/Claude" --user-data-dir="/h/Library/Application Support/Claude-Work"
            """)
        try apps.write(
            "Codex Client.app/Contents/MacOS/launch",
            """
            #!/bin/bash
            export CODEX_HOME='/h/.codex-client'
            exec '/h/Library/Application Support/Client-Codex-Runtime/Codex Client.app/Contents/MacOS/ChatGPT' --user-data-dir='/h/Library/Application Support/Codex-Client'
            """)
        try apps.folder("Notes.app/Contents/MacOS")

        let claude = try #require(Launcher.find(configDir: "/h/.claude-work", in: apps.root))
        #expect(claude.app == apps.root.appendingPathComponent("Claude Work.app").path)
        #expect(!claude.isCodex)
        #expect(
            claude.targets == [
                apps.root.appendingPathComponent("Claude Work.app").path,
                "/h/Library/Application Support/Work-Claude-Runtime",
                "/h/Library/Application Support/Claude-Work",
            ])

        let codex = try #require(Launcher.find(configDir: "/h/.codex-client", in: apps.root))
        #expect(codex.isCodex)
        #expect(codex.dataDir == "/h/Library/Application Support/Codex-Client")
    }

    @Test func ignoresOtherAccountsAndPrefixes() throws {
        let apps = try Fixture()
        try apps.write("Claude Work.app/Contents/MacOS/launch", #"export CLAUDE_CONFIG_DIR="/h/.claude-work-old""#)
        #expect(Launcher.find(configDir: "/h/.claude-work", in: apps.root) == nil)
    }
}
