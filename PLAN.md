# Public release with automatic updates

Status: Draft

## Outcome + scope

Relaybar ships as a public GitHub repository with Hard Eng checks, versioned releases built by GitHub Actions, Sparkle automatic updates and a simple README with mock screenshots. Not in scope: the demo video (a separate effort with the owner present), App Store distribution, Windows or Linux.

## Repository context

Owners: `Sources/` (AppKit menu bar app: `App.swift` menu and flows, `Account.swift` discovery, `Usage.swift` usage requests, `DesktopApp.swift` per-account desktop apps, `T3Code.swift` T3 Code settings, `Render.swift` and `AccountCard.swift` drawing), `build.sh` (bundle assembly), `Info.plist`, `Resources/` (logos, app icon, logo licence). Release pattern reference: the owner's Capture repository `.github/workflows/release.yml` (Developer ID signing, notarisation, Sparkle appcast on the latest GitHub release).

## Decisions + authorization

Blockers: None
Handoff: Approval
Authority: Owner chat 2026-10-16: release on GitHub as a public repo like Capture, with version control, the same automatic Mac updates, a simple README, and Hard Eng installed like Capture. The answer to the Hard Eng question also approved creating the public repo and pushing. Signing secrets are set by the owner; deploys run only through GitHub Actions.

## Acceptance + steps

- [ ] Swift package: `swift build -c release` builds the app with Sparkle 2.10.0 pinned exactly, and `./build.sh` assembles `Relaybar.app` with `Sparkle.framework` → build exit 0 and `codesign --verify` passes on the bundle.
- [ ] Memory stays small with Sparkle → the `memory` gate launches the built app with a fixture home and fails above 30 MB footprint; actual value recorded, and the gate fails when the budget is set below the measured value.
- [ ] Usage parsing → unit tests feed recorded-shape Claude and Codex responses (mock values) and Codex session log lines, and assert session and weekly percent left, reset times, the 429, 401 and missing-login results.
- [ ] Account discovery → a test with a fixture home finds `.claude`, `.claude-*` and `.codex*` accounts with the right Keychain service names (SHA-256 prefix of the folder path) and skips folders without a login.
- [ ] T3 Code settings → tests add an account, re-enable an existing one, and remove one with its favorites, model preferences and default selections, on a fixture settings file; other settings stay unchanged.
- [ ] Desktop app lookup → a test finds the launcher, runtime folder and data folder from a fixture launcher script.
- [ ] Automatic updates → `Info.plist` has `SUFeedURL` on the latest GitHub release, `SUPublicEDKey`, an hourly check, and the menu has "Check for updates…" wired to Sparkle's updater.
- [ ] Release workflow → pull requests build and pack a DMG; a merge to main publishes `vX.Y.Z` (next patch after the newest tag, or the `CFBundleShortVersionString` floor) as the latest release; with the signing secrets it is Developer ID signed, notarised and carries `appcast.xml`; without them it stays ad-hoc signed with no feed. `actionlint` passes.
- [ ] Privacy → no real names, emails, account details or local paths in tracked files or images; README screenshots use mock accounts.
- [ ] README → icon, one-line pitch, screenshot, download link with release badge, features, how adding and removing accounts works, privacy, build from source, credits for the logos and their trademark owners, MIT licence.

## Baseline + execution

Result: Pending
Evidence: Pending — starting `python3 .hooks/hard-eng.py check --plan-stage Draft` on the installed scaffold.
Execution: One builder (this session), sequential: Swift package + tests first, then Sparkle, then gates and CI, then README, then repository creation and the first release run.

## Risks + recovery

Sparkle adds memory → measure footprint before and after; if it exceeds the budget, start Sparkle's updater lazily and report the numbers. Signing secrets missing → releases stay ad-hoc signed with no feed, as in Capture, until the owner sets them. macOS GitHub runners lack a tool → install it in the workflow step that needs it.

## ux_reference

Result: Pending
Evidence: Pending — rendered menu with the new "Check for updates…" item.
Surface: Existing — `Sources/App.swift` menu, `Sources/AccountCard.swift` cards.
Before: Pending
Proposed: Pending
Capture: Pending
Review: Pending

## Verification

Result: Pending
Evidence: Pending
E2E: Required — the `memory` gate launches the real built app against a fixture home and a local fake usage server, and checks it starts, reads the fixture accounts and stays under the memory budget; Sparkle update delivery is proven by a published release whose `appcast.xml` lists it.

Delivery target: Merge; Delivery: Pending — first release run on main and its published GitHub release.
