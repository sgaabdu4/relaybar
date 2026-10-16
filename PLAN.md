# Public release with automatic updates

Status: Complete

## Outcome + scope

Relaybar ships as a public GitHub repository with Hard Eng checks, versioned releases built by GitHub Actions, Sparkle automatic updates and a simple README with mock screenshots. Not in scope: the demo video (a separate effort with the owner present), App Store distribution, Windows or Linux.

## Repository context

Owners: `Sources/Relaybar` (AppKit app: `App.swift` menu and flows, `AccountCard.swift`, `Render.swift`, `DesktopApp.swift`, `T3Code.swift`, `Watcher.swift`), `Sources/RelaybarCore` (logic without UI: `Usage.swift`, `AccountScanner.swift`, `T3Settings.swift`, `Launcher.swift`), `Tests/RelaybarCoreTests`, `Package.swift`, `build.sh`, `scripts/`, `Info.plist`, `Resources/`, `.github/workflows/release.yml`. Release pattern reference: the owner's Capture repository `release.yml` (Developer ID signing, notarisation, Sparkle appcast on the latest GitHub release).

## Decisions + authorization

Blockers: None
Authority: Owner chat 2026-10-16: release on GitHub as a public repo like Capture, with version control, the same automatic Mac updates, a simple README, and Hard Eng installed like Capture. The answer to the Hard Eng question also approved creating the public repo and pushing. Signing secrets are set by the owner; deploys run only through GitHub Actions.

## Acceptance + steps

- [x] Swift package → `./build.sh` builds a universal (arm64, x86_64) `Relaybar.app` with Sparkle 2.10.0 pinned exactly and bundled; `lipo -archs` shows both, `otool -L` links `@rpath/Sparkle.framework`, `codesign --verify --deep` passes.
- [x] Efficiency → `scripts/efficiency.sh` (gate `efficiency`) launches the built app on a fixture home with two demo accounts: 15 MB footprint (budget 30 MB) and 0.01 to 0.04 s CPU over 10 s idle (budget 0.1 s); with budgets 5 MB and 0 s it fails. Real app on the owner's Mac: 17 MB, CPU 0.45 → 0.17 s per minute after folder-level watching and the in-memory login cache.
- [x] Usage parsing → `UsageParserTests` and `FetchTests`: Claude limits and older fields, Codex weekly-only and 5-hour plus weekly, newest Codex limits in a long log and the newest session file in a folder, 401/403 expired, 429 with Retry-After 0 and 30, 500 failed, missing login and missing Codex token count as waiting, passed reset means full.
- [x] Account discovery → `AccountScannerTests`: fixture home finds `.claude`, `.claude-*`, `.codex*` with logins, skips folders without one, default tags; Keychain name matches an independent `shasum` vector.
- [x] T3 Code settings → `T3SettingsTests`: add, re-enable, remove with favorites, model preferences and default selections, unknown account leaves the file byte-identical, backup written.
- [x] Desktop app lookup → `LauncherTests`: finds Claude (double-quoted) and Codex (single-quoted) launchers with runtime folder and data folder, ignores a folder that only shares a prefix.
- [x] Tests are meaningful → four planted bugs (Keychain name, Retry-After 0, favorites left behind, new account shown as expired) each failed a named test; two trivial tests were removed on owner request.
- [x] Automatic updates → `Info.plist` has `SUFeedURL` (latest GitHub release), `SUPublicEDKey` (new key in the owner's login Keychain, account `relaybar`), `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, hourly `SUScheduledCheckInterval`; the menu has "Check for updates…" targeting `SPUStandardUpdaterController`.
- [x] Release workflow → `release.yml`: `hard-eng` job on macOS for pushes and pull requests; on main, `changes` finds app changes since the newest tag and picks the next patch (or the Info.plist floor); `release` needs both, signs with Developer ID and notarises when the secrets exist, writes `appcast.xml` with Sparkle's `generate_appcast`, publishes `vX.Y.Z` as latest. `actionlint` and `zizmor --persona=auditor` report no findings.
- [x] Open from the menu → clicking a card opens its desktop app (main accounts open Claude.app or the Codex app); lookup checked for all four of the owner's accounts; the tooltip shows "Open <app>", never an email.
- [x] Privacy → tracked files scanned for real names, emails and local paths: none (fixtures use example.com and `/Users/demo`); README images render mock accounts (ME, WK, CL, Codex).
- [x] README → icon, pitch, badges, download link, hero image, why, reading guide, add and remove, live updates, updates, privacy, requirements, build from source, credits and trademarks, licence; outside links return 200.

## Baseline + execution

Result: Passed
Evidence: `python3 .hooks/hard-eng.py check --plan-stage Draft` on 6fcba3c exited 0: secrets-files, secrets-history, security (Semgrep, 0 findings) and shellcheck passed. The first run failed on shellcheck SC2034 in `build.sh`; fixed in 6fcba3c.
Execution: One builder (this session), sequential: Swift package + tests first, then Sparkle, then gates and CI, then README, then repository creation and the first release run.

## Risks + recovery

Sparkle adds memory → measure footprint before and after; if it exceeds the budget, start Sparkle's updater lazily and report the numbers. Signing secrets missing → releases stay ad-hoc signed with no feed, as in Capture, until the owner sets them. macOS GitHub runners lack a tool → install it in the workflow step that needs it.

## ux_reference

Result: Passed
Evidence: Rendered the dropdown before and after with mock accounts from the app's own drawing code and inspected both.
Surface: Existing — `Sources/Relaybar/App.swift` menu items, `Sources/Relaybar/AccountCard.swift` cards.
Before: ![Menu before](docs/plan/menu-before.jpg)
Proposed: ![Menu with Check for updates](docs/hero.jpg)
Capture: Offscreen AppKit render at 2x in dark appearance with `Account`, `AccountCard` and `Render`; one new item "Check for updates…" above "Quit Relaybar", nothing else moves.
Review: Owner reviewed and approved the card layout, colours and low-limit colour earlier in this effort; the update item follows the existing menu style.

## Verification

Result: Passed
Evidence: `python3 .hooks/hard-eng.py check --plan-stage Draft` passed all gates (lockfile, format, tests 86% core coverage, build, efficiency, shellcheck, vulnerabilities, secrets, security); the pre-push run on main passed the same gates. First CI run on PR #1 failed before any check ran: this Hard Eng release installs its tools with Bun, not pnpm; the `hard-eng` job now uses `oven-sh/setup-bun` and the macOS mise package. Limits: Developer ID signing, notarisation and the appcast need the owner's secrets; until then releases are ad-hoc signed with no feed.
E2E: Passed — `scripts/efficiency.sh` launches the real built app with a fixture home holding a demo Claude and a demo Codex account, checks it stays running, under 30 MB and under 1% idle CPU.

Delivery target: Merge; Delivery: Passed — PR #1 merged as 6c53e6b after `hard-eng` passed on macOS (11 MB, 0.04 s idle CPU); the main run published https://github.com/sgaabdu4/relaybar/releases/tag/v1.0.0 with `Relaybar-1.0.0.dmg` (universal, version 1.0.0, build 3, ad-hoc signed). Developer ID signing, notarisation and `appcast.xml` wait for the owner's secrets. Hard Eng update PR #2 merged as 3bdf442. The main run after it failed in the docs-only secret scan: GitHub answered 403 to the tool installer, because that step passed `GH_TOKEN` but not `GITHUB_TOKEN`, so its downloads were anonymous; the step now passes both, as Hard Eng's generated workflow does. `./build.sh --install` now installs to `/Applications`, where the DMG installs it, so a local build replaces that copy instead of adding a second one.
