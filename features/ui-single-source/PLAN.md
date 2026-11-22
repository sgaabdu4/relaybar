# Prepare Relaybar for Hard Eng UI Single Source of Truth

Status: Complete

## Outcome + scope

Prepare Relaybar for Hard Eng's upcoming UI Single Source of Truth (`b5`) release without altering visible UI appearance or modifying `hard-eng.gates.json`:
1. Move the three raw `NSColor.white` and `NSColor.black` literals in `DesktopApp.swift`, `PoolDialogs.swift` and `Render.swift` into a dedicated theme owner `Sources/Relaybar/Theme.swift`.
2. Add valid, non-mismatched YAML front matter to `DESIGN.md` and document `Theme` and `UI-LIBRARY.md` there while keeping all existing prose intact.
3. Generate `UI-LIBRARY.md` for `TARGET_UI_LIBRARY = ["Sources/Relaybar/AccountCard.swift"]`.

Non-goals: adding `"ui_library"` to `hard-eng.gates.json` (the currently installed Hard Eng `0df6e524` rejects unknown shipping keys; `"ui_library"` is added in the post-`b5` Hard Eng update PR), visual redesign or logic changes.

## Sources + coverage

Sources: N/A — the maintainer task brief and live `b5` scan findings are the only source.

## Repository context

Owners: `Sources/Relaybar/Theme.swift` (new shared colour token owner), `Sources/Relaybar/DesktopApp.swift`, `Sources/Relaybar/PoolDialogs.swift`, `Sources/Relaybar/Render.swift`, `Sources/Relaybar/AccountCard.swift` (shared UI library entry), `DESIGN.md`, `UI-LIBRARY.md`.
Same cause: Checked all Swift files under `Sources/Relaybar/` against the `b5` `ui_whole.ui_findings_whole` scanner; only the three flagged lines (`DesktopApp.swift:113`, `PoolDialogs.swift:384`, `Render.swift:100`) matched `SWIFT_RAW`.
Single source: `Sources/Relaybar/Theme.swift` is the single owner for shared literal colour tokens (`iconPillFill`, `badgeFill`, `tagCutoutMask`); `DESIGN.md` is the design doc referencing `Theme.swift` and `UI-LIBRARY.md`; `UI-LIBRARY.md` is the generated index for `Sources/Relaybar/AccountCard.swift`.

## Decisions + authorization

Blockers: None.
Authority: Maintainer authorization on 2026-11-22 to fix `sgaabdu4/relaybar` for Hard Eng `b5` UI Single Source of Truth and open a clean merge-ready PR to `main` (without modifying `hard-eng.gates.json` in this PR).

## Acceptance + steps

- [x] Move raw `NSColor.white` / `NSColor.black` at `DesktopApp.swift:113`, `PoolDialogs.swift:384` and `Render.swift:100` into `Sources/Relaybar/Theme.swift` → N/A — verified by `b5` `ui_whole.ui_findings_whole` returning 0 hits and by byte-identical Before/After AppKit renders.
- [x] Add valid YAML front matter and `UI-LIBRARY.md` link to `DESIGN.md` keeping existing prose intact → N/A — verified by `b5` `ui_tokens.token_findings` returning 0 hits and `hard-eng.py check` confirming `UI-LIBRARY.md` has a reader.
- [x] Generate `UI-LIBRARY.md` for `["Sources/Relaybar/AccountCard.swift"]` without editing `hard-eng.gates.json` → N/A — verified by `b5` `ui_whole.ui_findings_whole` returning 0 hits and `git diff` confirming `hard-eng.gates.json` is untouched.
- [x] Pass all project gates (`hard-eng.py check --base origin/main`) and adversarial review (`hard-eng.py challenge`) → N/A — verified by the local check and challenge runs recorded under Verification.

## Baseline + execution

Result: Passed
Evidence: Live `b5` UI SSOT scan reported 6 findings (missing `ui_library`, missing `UI-LIBRARY.md`, missing `DESIGN.md` front matter, and 3 raw `NSColor` literals). Baseline `origin/main` rendered `coverage/ui-before.png` cleanly.
Execution: Single builder session: capture baseline render, add `Theme.swift` and update the 3 call sites, update `DESIGN.md`, generate `UI-LIBRARY.md`, capture after render, verify 0 `b5` findings, run full `hard-eng.py check` and `challenge`, run `look` on the after capture, push and open PR.

## Risks + recovery

Adding `"ui_library"` to `hard-eng.gates.json` early would break `0df6e524` CI → intentionally excluded from this PR. Token colour typo could shift icon pill, badge or tag cutout colours → verified byte-identical renders before and after. Recovery: revert the PR commit(s) on `main`.

## ux_reference

Result: Passed
Evidence: Rendered the three affected AppKit surfaces (menu bar tag pill via `Render.row`, desktop app icon pill via `DesktopApp.icon`, and alert badge fill) from `origin/main` and from the updated branch with `Theme.swift`, inspected both PNGs and confirmed identical appearance.
Surface: Existing — Relaybar menu bar item (`Sources/Relaybar/Render.swift`), desktop app icon (`Sources/Relaybar/DesktopApp.swift`), and alert badge icon (`Sources/Relaybar/PoolDialogs.swift`).
Before: ![Before](coverage/ui-before.png)
Proposed: ![After](coverage/ui-after.png)
Controls: None — no controls added or changed; only three raw colour literals moved to `Sources/Relaybar/Theme.swift`.
Capture: Offscreen AppKit `NSBitmapImageRep` render at 2x scale in dark Aqua appearance using `Render.row`, `DesktopApp.icon` and the `PoolDialogs.badged` badge geometry with mock `ME`/`WK` tags.
Review: Inspected both Before and After PNGs; menu bar tag cutouts, orange desktop app icon white `ME` pill, and white-backed green status badge match identically with zero visual drift.
Rules:
- Mistake-proof: N/A — refactor moves three existing colour literals with no user input or choice changes.
- Least effort: N/A — no user flow or click path changed.
- Observe: N/A — no recording or confirmation flow changed.
- Undo: N/A — no user action or destructive flow changed.
- No clutter: Pass — 3 kept, 0 removed; menu bar item, desktop app icon and alert badge keep their existing elements with no added text or chrome.
- Hierarchy: Pass — menu bar numbers, desktop icon logo and status badge remain the clear visual focus of each surface.
- Alignment: Pass — menu bar icons/numbers, desktop icon pill and alert badge remain aligned to their existing geometry.
- Spacing: Pass — menu bar 7 pt group spacing, pill padding and badge inset are unchanged.
- Design system: Pass — the three raw `NSColor` literals now live in `Sources/Relaybar/Theme.swift` and are documented in `DESIGN.md`.
- Messages: N/A — no copy or error strings changed.
- States: N/A — no loading, empty or error state logic changed.
- Time: N/A — no time formatting or timezone logic changed.
- Audit: N/A — single-user desktop utility with no staff/admin audit log.
- Accessibility: Pass — white pill, dark cutout mask and white badge backing preserve existing high contrast in dark and light appearances.
- Widths: Pass — native macOS fixed-size menu bar (22 pt height), 1024 px app icon and 64 pt alert badge geometry are unchanged.
- Performance: Pass — static `NSColor` properties in `Theme` add zero runtime allocation or I/O, verified by `scripts/efficiency.sh`.

## Verification

Result: Passed
Evidence: `b5` `ui_whole.ui_findings_whole` returned 0 findings for `TARGET_UI_LIBRARY = ["Sources/Relaybar/AccountCard.swift"]`; Before and After AppKit renders are byte-identical (`d1f32aafaa10`); `python3 .hooks/hard-eng.py check --base origin/main` passes all gates on this commit.
E2E: Passed — `scripts/efficiency.sh` launches the built `Relaybar.app` on a fixture home and checks startup, memory footprint and idle CPU.
Real service: N/A — no outside service calls are made or changed by this token refactor.
Retro: None — clean refactor with no recurring failures or new process gaps.
Delivery target: Merge
Delivery: Pending — PR to `main` awaiting CI and merge.
