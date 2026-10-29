# Relaybar Design

## Overview

A menu bar item plus one dropdown menu, drawn with AppKit. Principles: compact width in the menu bar, colour identifies the account, numbers stay readable in light and dark menu bars, nothing dims to transparency.

## Colors

- Account colours: the AppKit system colours orange, blue, green, purple, pink, teal, yellow and red, plus "No color" (label colour). Owner: `Tint` in `Sources/Relaybar/Render.swift`.
- Low warning (10% left or less): light red, sRGB (1, 0.55, 0.55) in dark appearance and (0.88, 0.3, 0.3) in light. Owner: `Tint.low`.
- Text: `labelColor`, `secondaryLabelColor` and `tertiaryLabelColor`; bar track `quaternaryLabelColor`.
- Combined accounts: system cyan (`#32ade6`, `PoolSetup.combinedColor`) for the "in use" dot and text and for the T3 Code "all accounts" entries. "paused" uses `tertiaryLabelColor`; "signed out" uses system red.
- Desktop app icons: a tile filled with the account colour (18% lighter at the top, 14% darker at the bottom), a white logo and a white pill with the tag in the darker colour. Owner: `DesktopApp.icon`.

## Typography

System font only. Menu bar: monospaced digits 9 pt medium (two stacked numbers) or 12.5 pt medium (one number); tag 6 pt bold rounded. Dropdown: name 13 pt semibold, labels 11 pt, values 12 pt medium monospaced digits. Owners: `Render`, `AccountCard`.

## Layout

- Menu bar: one status item, accounts left to right, 7 pt apart; each account is a 15 pt logo with its tag pill at the bottom left, then the numbers right-aligned.
- Dropdown: cards 250 pt wide with a 14 pt inset; a 22 pt header row (logo and name), then one 18 pt row per limit: label, bar, value, reset time.

## Components

- Atoms: logo (Claude or Codex SVG, tinted), tag pill, bar, value text.
- Molecules: menu bar account group (logo, tag, stacked numbers); limit row (label, bar, value, reset).
- Organisms: `AccountCard` (one account, clickable when it has an app to open); the status item image (`Render.row`).
- Templates: the dropdown — account cards, then "Combine accounts…" or "All accounts ›" (subtitle "On homebox" or "On this Mac"), Customize, Add account, Open at login, Quit. The "All accounts" submenu has Claude and Codex section headers, one tickable row per account (states as a second line), "Change order…", a "Computers" section (one row per added computer, each with "Remove <host>…"), "Add a computer…" and "Stop combining…".
- Pages: the dropdown and the add, rename, remove and make-desktop-app dialogs (standard `NSAlert`).

## Do's and Don'ts

- Do keep each menu bar group as narrow as the numbers allow.
- Do use the account colour for its logo, tag and numbers; use light red only for low limits.
- Do show "…" while waiting for numbers and "Login expired" only for a rejected or expired login.
- Do show a pooled account's state as words on the right of its card header ("in use", "paused", "signed out"); no extra summary cards.
- Do build dialogs from native parts: `NSAlert` with the app icon, equal-width buttons, the default on the right, accessory views stacked with even spacing; destructive actions ask twice with Cancel as the default.
- Don't dim accounts with transparency; dark colours become unreadable.
- Don't show emails or account details in the menu bar or in tooltips.
