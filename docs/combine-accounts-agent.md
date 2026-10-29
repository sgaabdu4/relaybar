# Combine accounts: guide for a coding agent

Give this file to Claude Code or Codex when Relaybar's **Combine accounts** needs help, or when you want to set parts up by hand. Relaybar normally does all of this itself.

## Rules for the agent

- Never print, log, paste or commit the access key, the management secret or any login file. Read secrets only into environment variables or pipes.
- The helper runs only on the user's own computers at home. Never on a cloud server or behind a VPN. Never make it listen on the network, and never open a router port.
- Claude plans are for Claude models in Claude Code only. Never point another app at the helper with a Claude plan.
- Change only the files and services listed here. Do not touch `~/.claude`, `~/.codex`, or an existing Tailscale setup (exit node, routes, accounts).
- Ask the user before you stop, remove or reinstall anything.

## What Relaybar set up

| Where | What |
| --- | --- |
| Mac helper | `~/Library/Application Support/Relaybar/Helper/` (`current/cli-proxy-api`, `config.yaml`, `auth/`, `helper.sb`) |
| Mac services | LaunchAgents `com.relaybar.helper`, `com.relaybar.helper-update` (nightly) and `com.relaybar.helper-tunnel` (SSH to a home computer) in `~/Library/LaunchAgents/` |
| Linux helper | `~/.local/share/relaybar-helper/` and `~/.local/share/relaybar/relaybar-helper.sh` |
| Linux services | user units `relaybar-helper.service`, `relaybar-helper-update.service` and `relaybar-helper-update.timer` |
| Keys | Mac Keychain items "Relaybar access key" and "Relaybar management secret" |
| Added computer | on the added Linux computer: user unit `relaybar-tunnel.service`, and in `~/.config/relaybar/` the files `hub_key`, `hub_key.pub`, `known_hosts` and `access-key`; on the home computer: one line ending `relaybar-client:<name>` in `~/.ssh/authorized_keys` (backup: `authorized_keys.relaybar-backup`) |
| Tools | `~/.local/bin/claude+` and `~/.local/bin/codex+` (they set the helper only at launch; nothing in `~/.claude` or `~/.codex` is edited) |
| Replaced logins | on an added computer where the user chose Replace: `~/.claude/settings.json` (`apiKeyHelper` and `env`), `~/.codex/config.toml` (the `relaybar` provider), and the old logins and settings kept in `~/.config/relaybar/kept/` until Remove puts them back |
| T3 Code | entries "Claude+" and "Codex+", and the usage source "All accounts" |

The helper always listens on `127.0.0.1:8317` of the computer that runs it. A Mac reaches a home helper through its SSH tunnel on its own `127.0.0.1:8317`.

## Set up SSH access to the home computer

Relaybar needs to log in without a password prompt.

1. On the Mac, check for a key: `ls ~/.ssh/id_ed25519.pub`. If it is missing, ask the user to run `ssh-keygen -t ed25519` in Terminal.
2. Ask the user to run `ssh-copy-id <user>@<address>` in Terminal and type the home computer's password once.
3. Test: `ssh -o BatchMode=yes <user>@<address> uname -s` must print `Linux` with no prompt.
4. Optional: add a `Host` entry to `~/.ssh/config` so Relaybar can find the computer by name.

## Check the helper

Without the key, the helper must refuse; this proves it runs and checks keys:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8317/v1/models   # expect 401
```

On a Mac:

```bash
launchctl print "gui/$(id -u)/com.relaybar.helper" | grep -E 'state|last exit'
launchctl print "gui/$(id -u)/com.relaybar.helper-tunnel" | grep -E 'state|last exit'
```

On the home computer:

```bash
systemctl --user status relaybar-helper.service --no-pager
systemctl --user list-timers relaybar-helper-update.timer --no-pager
```

With the key, from the Mac, without printing it:

```bash
key="$(security find-generic-password -s 'Relaybar access key' -w)"
curl -s -H "Authorization: Bearer $key" http://127.0.0.1:8317/v1/models | head -c 300; echo
unset key
```

## Fix common problems

- **401 with the key:** the key in the Keychain does not match the helper. Ask the user to stop combining and combine again in Relaybar.
- **Connection refused on the Mac, home helper:** restart the tunnel: `launchctl kickstart -k "gui/$(id -u)/com.relaybar.helper-tunnel"`. Then check SSH as above.
- **Helper not running on Linux:** `systemctl --user restart relaybar-helper.service`. If it fails, show the user `journalctl --user -u relaybar-helper.service -n 30 --no-pager`. The helper's own output is off on purpose.
- **Services stop after logout on Linux:** `loginctl show-user "$USER" -p Linger` must say `yes`. If not, ask the user to run `sudo loginctl enable-linger "$USER"`.
- **An account shows "signed out":** use Relaybar, **All accounts**, then click the account to sign in again.
- **Update problems:** run the update by hand and read its messages: `sh ~/.local/share/relaybar/relaybar-helper.sh update ~/.local/share/relaybar-helper` (Linux), or `sh "$HOME/Library/Application Support/Relaybar/relaybar-helper.sh" update "$HOME/Library/Application Support/Relaybar/Helper"` (Mac). It never installs a version younger than 3 days or on Relaybar's block list.

## Use combined accounts from a terminal

- On a Mac with Relaybar: `claude+` and `codex+`.
- On a Linux computer added in Relaybar: plain `claude` and `codex` if the user chose Replace, otherwise `claude+` and `codex+`. The key is in a private file there.
- Anywhere else: do not set this up by hand. Ask the user to use Relaybar: **All accounts**, then **Add a computer…**. A Mac runs Relaybar itself and connects in one click.

## Stop

Use Relaybar: **All accounts**, then **Stop combining…**. It removes everything in the table above and puts T3 Code back as it was. If a helper version is ever reported as bad, also ask the user to sign out of all sessions on claude.ai and chatgpt.com.
