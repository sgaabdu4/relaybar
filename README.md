<div align="center">

<img src="Resources/AppIcon.png" alt="Relaybar icon" width="128">

# Relaybar

**Every Claude and Codex account. One menu bar.**

See how much of each Claude and Codex limit is left, live, for every account on your Mac or Windows PC.

[![Download the latest release](https://img.shields.io/badge/download-latest%20release-0a84ff)](https://github.com/sgaabdu4/relaybar/releases/latest)
![macOS 14 or later](https://img.shields.io/badge/macOS-14%2B-black)
![Windows 10 or 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078d4)
[![MIT licence](https://img.shields.io/badge/licence-MIT-blue)](LICENSE)

**[Download the latest release](https://github.com/sgaabdu4/relaybar/releases/latest)**

<img src="docs/hero.jpg" alt="Relaybar in the menu bar with four colour-tagged accounts and the open menu" width="900">

</div>

## Watch it work

Add a Claude account, sign in, open its own desktop app and use it in T3 Code. All names are sample accounts.

https://github.com/user-attachments/assets/65b1f635-a769-4021-8cd1-288c8367ca0d

## Why Relaybar

- **Know which account has room.** The 5-hour session and weekly limit of every account, at a glance.
- **Tell accounts apart instantly.** Each one gets its own colour and a short tag, such as WK or CL.
- **Add an account in one click.** Sign in through your browser. Relaybar sets up the rest.
- **Tiny and native.** About 15 MB of memory and almost no CPU. Pure Swift and AppKit.

## Read it at a glance

| You see | It means |
| --- | --- |
| Top number | Session (5-hour) limit left, in % |
| Bottom number | Weekly limit left, in % |
| Light red number | 10% or less left |
| `…` | Waiting for the first numbers |
| **Login expired** in the menu | Use that account once in Claude or Codex to renew it |

Click an account in the menu to open its desktop app.

## Add an account

1. Click Relaybar, then **Add account**, then **Claude** or **Codex**.
2. Type a name (for example *Work*), a short tag (*WK*) and pick a colour.
3. Your browser opens the sign-in page. Sign in.

The account appears in the menu bar a few seconds later. Relaybar also:

- creates its own folder (`~/.claude-work` or `~/.codex-work`), so it never mixes with your other accounts;
- makes a desktop app, such as **Claude Work**, with your tag and colour on the icon (you can turn this off);
- adds the account to [T3 Code](https://t3.codes), if T3 Code is installed.

<img src="docs/desktop-apps.jpg" alt="Desktop app icons for four accounts, each in its own colour with its tag" width="900">

In T3 Code, every account shows up in the model picker with its own tag, ready to choose per chat.

<img src="docs/t3-code.jpg" alt="T3 Code's model picker listing the new Studio account next to the other accounts, each with its tag" width="700">

## Remove an account

Click Relaybar, then **Customize**, the account, then **Remove**. You can hide it, or delete it from your Mac: its folder, desktop app, saved login and T3 Code entry. Deleting asks three times, and files go to the Trash. Your main `~/.claude` and `~/.codex` folders can only be hidden.

## How live is it?

- **Codex:** updates the moment you send a message, from Codex's own session logs.
- **Claude:** checks when that account is in use (at most once a minute) and every five minutes otherwise.
- **Logins:** Relaybar only reads them and never renews them, because renewing would sign the account out of Claude Code.

## Updates

Relaybar updates itself. It checks for a new version every hour and installs it the next time it starts. **Check for updates…** in the menu checks now.

## Privacy

- No analytics and no server of its own. Relaybar asks Anthropic and OpenAI for your usage with your own logins.
- Logins stay in your Keychain and in Claude's and Codex's own files. Relaybar never copies them.
- Desktop apps are clones of the official Claude and Codex apps on your disk. A clone takes almost no extra space.

## Requirements

- macOS 14 or later, on Apple silicon or Intel.
- [Claude Code](https://claude.com/claude-code) or the [Codex CLI](https://github.com/openai/codex), to sign in new accounts.
- The Claude or Codex desktop app, for per-account desktop apps.

## Windows

Relaybar also runs on Windows 10 and 11. It is one small `Relaybar.exe` with no installer and nothing else to install.

### Install on Windows

Download `RelaybarSetup-<version>.exe` from the [latest release](https://github.com/sgaabdu4/relaybar/releases/latest) and run it. The setup screen:

- lists the Claude and Codex accounts already on the PC;
- lets you add more accounts, each with a name, a short tag and a colour;
- installs Relaybar to `%LOCALAPPDATA%\Programs\Relaybar` (no admin rights needed) and adds it to the Start menu;
- signs in to each new account in turn. A terminal opens and your browser shows the Claude or Codex sign-in page. Relaybar never sees your password.

Signing in needs [Claude Code](https://claude.com/claude-code) for Claude accounts and the [Codex CLI](https://github.com/openai/codex) for Codex accounts. The setup screen tells you if one is missing.

The setup file is not code-signed yet. If Windows shows "Windows protected your PC", click **More info**, then **Run anyway**.

To remove Relaybar, open **Settings**, then **Apps** and **Installed apps**, and uninstall **Relaybar**. Your Claude and Codex accounts stay as they are.

To build it from source in PowerShell:

```powershell
git clone https://github.com/sgaabdu4/relaybar.git
cd relaybar
powershell -ExecutionPolicy Bypass -File windows\build.ps1 -Install
```

The build writes `build\windows\RelaybarSetup.exe`. `-Install` also copies Relaybar to `%LOCALAPPDATA%\Programs\Relaybar`, adds it to the Start menu and starts it. `windows\test.ps1` runs the Windows tests. The build uses the C# compiler that comes with Windows, so you do not need Visual Studio or the .NET SDK.

### Show the icons

Windows hides new tray icons. Open **Settings**, then **Personalization**, **Taskbar** and **Other system tray icons**, and turn on each Relaybar entry. You can also drag the icons from the `^` overflow onto the taskbar.

### How Windows differs

- **One tray icon per account.** Each icon shows session left on top and weekly left below, in the account's colour. Point at an icon to see its name. Click any icon for the menu.
- **Sign-in opens a terminal.** Setup and **Add account** open a small terminal window that runs `claude auth login` or `codex login`. It closes by itself after you sign in. **Add account** then **Several accounts…** opens the setup screen again.
- **Desktop apps are Start menu shortcuts.** **Make desktop app** adds a shortcut such as **Claude Work** with your tag and colour. It opens a separate Claude window with that account's login. This works with the Claude desktop app from the Microsoft Store or claude.ai. Codex desktop apps are not supported on Windows yet.
- **Logins.** Relaybar reads them from each account's `.credentials.json` or `auth.json`. It never copies or renews them.
- **Delete moves files to the Recycle Bin.** The account's login is in its folder, so it goes too.
- **Settings** are in `%APPDATA%\Relaybar\settings.json`. **Open at login** adds Relaybar to your startup apps.
- **No automatic updates yet.** Run the new setup file to update. It keeps your accounts and settings.

## Build from source

```bash
git clone https://github.com/sgaabdu4/relaybar.git
cd relaybar
./build.sh --install
```

`scripts/test.sh` runs the tests. `scripts/efficiency.sh` launches the built app and fails if it uses more than 30 MB of memory or more than 1% CPU while idle. Every merge to `main` that changes the app publishes the next version (1.0.1, 1.0.2 and so on), signed and notarised.

## Credits

- Claude and Codex logos from [OpenUsage](https://github.com/robinebers/openusage) by Robin Ebers, MIT licence (`Resources/LOGOS-LICENSE.txt`).
- Claude is a trademark of Anthropic. Codex, ChatGPT and OpenAI are trademarks of OpenAI. Relaybar is not affiliated with either company.
- Screenshots use sample accounts.

## Licence

[MIT](LICENSE)
