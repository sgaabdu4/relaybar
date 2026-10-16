import Foundation
import Testing

@testable import RelaybarCore

struct AccountScannerTests {
    @Test func findsSignedInClaudeAndCodexAccounts() throws {
        let home = try Fixture()
        try home.folder(".claude")
        try home.write(
            ".claude.json", #"{"oauthAccount": {"emailAddress": "sam@example.com", "organizationName": "sam@example.com's Organization"}}"#)
        try home.write(
            ".claude-work/.claude.json", #"{"oauthAccount": {"emailAddress": "sam@example.org", "organizationName": "Acme Studio"}}"#)
        try home.write(".claude-empty/settings.json", "{}")
        try home.write(".claude-notes", "not a folder")
        let claims = Data(#"{"email": "sam@example.net"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        try home.write(".codex/auth.json", #"{"tokens": {"id_token": "header.\#(claims).signature"}}"#)
        try home.write(".codex-client/auth.json", "{}")
        try home.folder(".codex-old")

        let accounts = AccountScanner.scan(home: home.root)

        #expect(accounts.map(\.label) == ["sam@example.com", "sam@example.org", "sam@example.net", ".codex-client"])
        #expect(accounts.map(\.defaultTag) == ["SA", "AS", "", "CL"])
        #expect(accounts[0].source == .claude(service: "Claude Code-credentials"))
        #expect(
            accounts[1].source
                == .claude(
                    service: AccountScanner.keychainService(
                        configDir: home.root.appendingPathComponent(".claude-work").path, isDefault: false)))
        #expect(accounts[2].source == .codex(authFile: home.root.appendingPathComponent(".codex/auth.json")))
    }

    @Test func keychainNameMatchesClaudeCode() {
        #expect(
            AccountScanner.keychainService(configDir: "/Users/demo/.claude-work", isDefault: false) == "Claude Code-credentials-4fbe0f72")
        #expect(AccountScanner.keychainService(configDir: "/Users/demo/.claude", isDefault: true) == "Claude Code-credentials")
    }
}
