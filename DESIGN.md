# Relaybar Design

## Overview

A menu bar item plus one dropdown menu, drawn with AppKit. Principles: compact width in the menu bar, colour identifies the account, numbers stay readable in light and dark menu bars, nothing dims to transparency.

## Colors

- Account colours: the AppKit system colours orange, blue, green, purple, pink, teal, yellow and red, plus "No color" (label colour). Owner: `Tint` in `Sources/Relaybar/Render.swift`.
- Low warning (10% left or less): light red, sRGB (1, 0.55, 0.55) in dark appearance and (0.88, 0.3, 0.3) in light. Owner: `Tint.low`.
- Text: `labelColor`, `secondaryLabelColor` and `tertiaryLabelColor`; bar track `quaternaryLabelColor`.
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
- Templates: the dropdown — account cards, then Customize, Add account, Open at login, Quit.
- Pages: the dropdown and the add, rename, remove and make-desktop-app dialogs (standard `NSAlert`).

## Do's and Don'ts

- Do keep each menu bar group as narrow as the numbers allow.
- Do use the account colour for its logo, tag and numbers; use light red only for low limits.
- Do show "…" while waiting for numbers and "Login expired" only for a rejected or expired login.
- Don't dim accounts with transparency; dark colours become unreadable.
- Don't show emails or account details in the menu bar or in tooltips.
