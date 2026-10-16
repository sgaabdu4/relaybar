# Relaybar

A native macOS menu bar app that shows how much of each Claude and Codex subscription limit is left, live, for several accounts on one Mac.

## Register

Product — a free, open-source Mac utility for people who use more than one AI coding subscription.

## Users

Developers who sign in to two or more Claude or Codex accounts on one Mac (for example personal, work and client) and want to know which account still has room before they start a task.

## Problem

Each account's session and weekly limits are only visible inside that account's own app or web page. Juggling several accounts means hitting a limit mid-task, then guessing which other account can take over. Setting up a second account (its own folder, sign-in, desktop app and T3 Code entry) takes several manual steps, and removing one leaves files behind.

## Product Purpose

- One menu bar item shows every account: its logo in the account's colour, a short tag (such as PC or WK), session left on top and weekly left below. Numbers at 10% or less turn light red.
- The dropdown shows one card per account with bars and reset times; clicking a card opens that account's desktop app.
- Live updates: Codex numbers come from Codex's own session logs as you work; Claude numbers are re-read when that account is in use (at most once a minute) and every five minutes otherwise.
- Add account: creates the account folder, signs in through the browser in the background, can make a separate Claude or Codex desktop app with a colour-badged icon, and adds the account to T3 Code when T3 Code is installed.
- Remove account: hide it, or delete its folder, desktop app, Keychain login and T3 Code entry after three confirmations. Main `~/.claude` and `~/.codex` folders can only be hidden.
- Planned: automatic updates through Sparkle and signed releases on GitHub.

## Brand Personality / Tone

Calm, small and exact. Plain words, short labels ("5h", "7d", "Login expired"), no hype. The app should feel like part of macOS.

## Boundaries

- macOS 14 or later only; no Windows, Linux or iPhone.
- Reads usage; never changes plans, buys credits or renews logins (renewing would sign the account out of Claude Code).
- No analytics, no server of its own; tokens stay in the Keychain and the tools' own files.
- Not affiliated with Anthropic or OpenAI.

## Stack

Swift and AppKit only (no SwiftUI, no web views) to keep memory small. Sources in `Sources/Relaybar` (app) and `Sources/RelaybarCore` (logic without UI); bundle assembly in `build.sh`.
