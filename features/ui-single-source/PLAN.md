# Prepare Relaybar for Hard Eng UI Single Source of Truth

Status: Complete

## Outcome + scope

Prepare Relaybar for Hard Eng's upcoming UI Single Source of Truth (`b5`) release without altering visible UI appearance or modifying `hard-eng.gates.json`:
1. Move the three raw `NSColor.white` and `NSColor.black` literals in `DesktopApp.swift`, `PoolDialogs.swift` and `Render.swift` into a dedicated theme owner `Sources/Relaybar/Theme.swift`.
2. Add valid, non-mismatched YAML front matter to `DESIGN.md` and document `Theme` and `[UI-LIBRARY.md](UI-LIBRARY.md)` there while keeping all existing prose intact.
3. Generate `UI-LIBRARY.md` for `TARGET_UI_LIBRARY = ["Sources/Relaybar/AccountCard.swift"]`.

Non-goals: adding `"ui_library"` to `hard-eng.gates.json` (the currently installed Hard Eng `0df6e524` rejects unknown shipping keys; `"ui_library"` is added in the post-`b5` Hard Eng update PR), visual redesign or logic changes.

## Sources + coverage

Sources: N/A — the maintainer task brief and live `b5` scan findings are the only source.

## Repository context

Owners: `Sources/Relaybar/Theme.swift` (new shared colour token owner), `Sources/Relaybar/DesktopApp.swift`, `Sources/Relaybar/PoolDialogs.swift`, `Sources/Relaybar/Render.swift`, `Sources/Relaybar/AccountCard.swift` (shared UI library entry), `DESIGN.md`, `UI-LIBRARY.md`.
Same cause: Checked all Swift files under `Sources/Relaybar/` against the `b5` `ui_whole.ui_findings_whole` scanner; only the three flagged lines (`DesktopApp.swift:113`, `PoolDialogs.swift:384`, `Render.swift:100`) matched `SWIFT_RAW`.
Single source: `Sources/Relaybar/Theme.swift` is the single owner for shared literal colour tokens (`iconPillFill`, `badgeFill`, `tagCutoutMask`); `DESIGN.md` is the design doc linking `Theme.swift` and `UI-LIBRARY.md`; `UI-LIBRARY.md` is the generated index for `Sources/Relaybar/AccountCard.swift`.

## Decisions + authorization

Blockers: None.
Authority: Maintainer authorization on 2026-11-22 to fix `sgaabdu4/relaybar` for Hard Eng `b5` UI Single Source of Truth and open a clean merge-ready PR to `main` (without modifying `hard-eng.gates.json` in this PR).

## Acceptance + steps

- [x] Move raw `NSColor.white` / `NSColor.black` at `DesktopApp.swift:113`, `PoolDialogs.swift:384` and `Render.swift:100` into `Sources/Relaybar/Theme.swift` → N/A — verified by `b5` `ui_whole.ui_findings_whole` returning 0 hits, byte-identical Before/After AppKit renders for `Render.row` and `DesktopApp.icon`, and build + code inspection for private `PoolDialogs.badged`.
- [x] Add valid YAML front matter and `[UI-LIBRARY.md](UI-LIBRARY.md)` link to `DESIGN.md` keeping existing prose intact → N/A — verified by `b5` `ui_tokens.token_findings` returning 0 hits and `hard-eng.py check` confirming `UI-LIBRARY.md` has a reader.
- [x] Generate `UI-LIBRARY.md` for `["Sources/Relaybar/AccountCard.swift"]` without editing `hard-eng.gates.json` → N/A — verified by `b5` `ui_whole.ui_findings_whole` returning 0 hits and `git diff` confirming `hard-eng.gates.json` is untouched.
- [x] Pass all project gates (`python3 .hooks/hard-eng.py check --base origin/main`) → N/A — verified by the local check run recorded under Verification; independent review (`hard-eng.py challenge`) runs on the committed revision after the check.

## Baseline + execution

Result: Passed
Evidence: Live `b5` UI SSOT scan reported 6 findings (missing `ui_library`, missing `UI-LIBRARY.md`, missing `DESIGN.md` front matter, and 3 raw `NSColor` literals). Baseline `origin/main` rendered `coverage/ui-before.png` cleanly.
Execution: Single builder session: extract the three colour literals into `Theme.swift`, update `DESIGN.md`, generate `UI-LIBRARY.md`, render Before (`origin/main`) and After (branch) AppKit previews, verify 0 `b5` findings, commit, run `look`, full `hard-eng.py check` and `challenge`, then push and open PR.

## Risks + recovery

Adding `"ui_library"` to `hard-eng.gates.json` early would break `0df6e524` CI → intentionally excluded from this PR. Token colour typo could shift icon pill, badge or tag cutout colours → verified byte-identical renders before and after for `Render.row` and `DesktopApp.icon`, and `Theme.badgeFill == NSColor.white` in `Theme.swift`. Recovery: revert the PR commits on `main`.

## ux_reference

Result: Passed
Evidence: Rendered the menu bar item (`Render.row`), dropdown account card (`AccountCard`) and desktop app icon (`DesktopApp.icon`) from `origin/main` and from this branch with `Theme.swift`, inspected both PNGs and confirmed byte-identical output (`f65a5a0b7287`). `PoolDialogs.badged` is private and uses `Theme.badgeFill` (`.white`), matching `NSColor.white`.
Surface: Existing — Relaybar menu bar item (`Sources/Relaybar/Render.swift`), dropdown card (`Sources/Relaybar/AccountCard.swift`) and desktop app icon (`Sources/Relaybar/DesktopApp.swift`).
Before: ![Before](../../coverage/ui-before.png)
Proposed: ![After](../../coverage/ui-after.png)
Controls: None — no controls added or changed; only three raw colour literals moved to `Sources/Relaybar/Theme.swift`.
Capture: Offscreen AppKit `NSBitmapImageRep` render at 2x scale in dark Aqua appearance calling `Render.row`, `AccountCard` and `DesktopApp.icon` directly from `origin/main` (Before) and from this branch (After) with mock `ME` account data (`82%` 5h, `64%` 7d).
Review: Inspected both Before and After PNGs; menu bar `ME` tag cutout, `5h`/`7d` dropdown card and orange desktop app icon with white `ME` pill are byte-for-byte identical.
Rules:
- Mistake-proof: Pass — menu bar `82`/`64` numbers sit directly above the `AccountCard` rows labelled `5h` (`82%`) and `7d` (`64%`), and no user input or choice changed.
- Least effort: N/A — no user flow or click path changed.
- Observe: N/A — no recording or confirmation flow changed.
- Undo: N/A — no user action or destructive flow changed.
- No clutter: Pass — 3 kept, 0 removed; menu bar item, dropdown card and desktop app icon keep their existing elements with no added helper text.
- Hierarchy: Pass — single orange accent identifies the account across menu bar, card bars and desktop icon tile with quiet neutral surfaces.
- Alignment: Pass — column headings share the left edge of the 250 pt menu/card stack and the 170 pt icon card.
- Spacing: Pass — uniform 24 pt outer margin, 12 pt stack gap and native card padding keep groups distinct.
- Design system: Pass — the three raw `NSColor` literals now live in `Sources/Relaybar/Theme.swift` and are documented in `DESIGN.md`.
- Messages: N/A — no copy or error strings changed.
- States: N/A — no loading, empty or error state logic changed.
- Time: N/A — no time formatting or timezone logic changed.
- Audit: N/A — single-user desktop utility with no staff/admin audit log.
- Accessibility: Pass — white pill, dark cutout mask and orange-on-dark labels preserve existing contrast in dark and light appearances.
- Widths: Pass — native macOS fixed-size menu bar (22 pt height), 250 pt dropdown card and 1024 px app icon geometry are unchanged.
- Performance: Pass — static `NSColor` properties in `Theme` add zero runtime allocation or I/O, verified by `scripts/efficiency.sh`.

## Verification

Result: Passed
Evidence: `b5` `ui_whole.ui_findings_whole` returned 0 findings for `TARGET_UI_LIBRARY = ["Sources/Relaybar/AccountCard.swift"]`; Before (`origin/main`) and After (branch) AppKit renders of `Render.row`, `AccountCard` and `DesktopApp.icon` are byte-identical (SHA-256 `f65a5a0b7287`); `python3 .hooks/hard-eng.py check --base origin/main` passed lockfile, format, tests, universal build, efficiency (15 MB footprint, 0.01 s idle CPU), secrets-files, secrets-history, vulnerabilities, zizmor, actionlint, shellcheck and security (0 findings).
E2E: Passed — `scripts/efficiency.sh` launched the built `Relaybar.app` on a fixture home and stayed within memory (15 MB vs 30 MB budget) and idle CPU (0.01 s vs 0.1 s budget) limits; offscreen AppKit renders of `Render.row`, `AccountCard` and `DesktopApp.icon` matched byte-for-byte against `origin/main`, while private `PoolDialogs.badged` was verified by compilation and inspection (`Theme.badgeFill == .white`).
Real service: N/A — no outside service calls are made or changed by this token refactor.
Retro: None — clean refactor with no recurring failures or new process gaps.
Delivery target: Merge
Delivery: Pending — PR to `main` awaiting CI and merge.
