#!/bin/bash
installStep() {
  local step=$1 name=$2 repo=${repo:?} work=${work:?} sites=file://${homeDir:?}/e2e-sites
  (
    cd "$repo" || exit 1
    env RELAYBAR_E2E_STEP="$step" RELAYBAR_E2E_SSH_CONFIG="$work/ssh_config" RELAYBAR_E2E_CLIENT_FILE="$work/client.json" \
      RELAYBAR_E2E_ACCESS_KEY_FILE="$work/access-key" RELAYBAR_E2E_PAIR_FILE="$work/pair-marker" \
      RELAYBAR_CLAUDE_INSTALL_URL="$sites/claude.sh" RELAYBAR_CODEX_INSTALL_URL="$sites/codex.sh" RELAYBAR_T3_INSTALL_URL="$sites/t3.sh" \
      perl -e 'alarm shift; exec @ARGV or exit 127' 900 swift test --skip-build --filter "$name"
  ) > "$work/swift-$step.log" 2>&1 || fail "the $step step failed: $(cat "$work/swift-$step.log")"
  grep -q "Test $name() passed" "$work/swift-$step.log" || fail "the $step test did not run: $(cat "$work/swift-$step.log")"
}

writeInstallFixtures() {
  mkdir -p "$work/sites"
  cat > "$work/sites/claude.sh" <<'EOF'
set -eu
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/claude/versions" "$HOME/.claude"
printf '#!/bin/sh\necho "1.0.0 (Claude Code)"\n' > "$HOME/.local/share/claude/versions/1.0.0"
chmod 755 "$HOME/.local/share/claude/versions/1.0.0"
ln -sf "$HOME/.local/share/claude/versions/1.0.0" "$HOME/.local/bin/claude"
echo '{"installMethod":"native"}' > "$HOME/.claude.json"
echo "Installed Claude Code"
EOF
  cat > "$work/sites/codex.sh" <<'EOF'
set -eu
[ "${CODEX_NON_INTERACTIVE:-}" = 1 ] || { echo "the codex fixture needs CODEX_NON_INTERACTIVE=1" >&2; exit 4; }
P="$HOME/.codex/packages/standalone"
mkdir -p "$HOME/.local/bin" "$P/releases/1.0.0/bin" "$HOME/.codex/tmp"
printf '#!/bin/sh\necho "codex-cli 1.0.0"\n' > "$P/releases/1.0.0/bin/codex"
printf '#!/bin/sh\ntrue\n' > "$P/releases/1.0.0/bin/codex-code-mode-host"
chmod 755 "$P/releases/1.0.0/bin/codex" "$P/releases/1.0.0/bin/codex-code-mode-host"
ln -sfn "$P/releases/1.0.0" "$P/current"
ln -sf "$P/current/bin/codex" "$HOME/.local/bin/codex"
printf '\n# >>> Codex installer >>>\nexport PATH="%s/.local/bin:$PATH"\n# <<< Codex installer <<<\n' "$HOME" >> "$HOME/.profile"
echo "Codex CLI 1.0.0 installed successfully."
EOF
  cat > "$work/sites/t3.sh" <<'EOF'
set -eu
[ "${T3CODE_CHANNEL:-}" = nightly ] || { echo "the t3 fixture needs T3CODE_CHANNEL=nightly" >&2; exit 4; }
echo "$T3CODE_CHANNEL" > "$HOME/e2e-sites/t3-channel"
mkdir -p "$HOME/.local/bin" "$HOME/.t3/runtime/versions/1.0.0"
cp "$HOME/e2e-sites/t3-fake" "$HOME/.t3/runtime/versions/1.0.0/t3"
chmod 755 "$HOME/.t3/runtime/versions/1.0.0/t3"
ln -sf "$HOME/.t3/runtime/versions/1.0.0/t3" "$HOME/.local/bin/t3"
echo "Installed T3 Code 1.0.0"
EOF
  cat > "$work/sites/t3-fake" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$HOME/e2e-sites/t3-calls.log"
U="$HOME/.config/systemd/user/t3code.service"
case "$1 $2" in
  "service install")
    mkdir -p "$HOME/.config/systemd/user" "$HOME/.t3/runtime"
    cat > "$HOME/.t3/runtime/server.sh" <<'SERVER'
#!/bin/sh
mkdir -p "$HOME/.t3/userdata"
printf '{"host":"%s","port":3773}' "${T3CODE_HOST:-0.0.0.0}" > "$HOME/.t3/userdata/server-runtime.json"
[ -e "$HOME/.t3/userdata/threads.db" ] || echo chats > "$HOME/.t3/userdata/threads.db"
exec sleep 100000
SERVER
    chmod 755 "$HOME/.t3/runtime/server.sh"
    cat > "$U" <<UNIT
[Unit]
Description=Fake T3 Code server
[Service]
EnvironmentFile=-$HOME/.t3/service.env
ExecStart=$HOME/.t3/runtime/server.sh
[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload && systemctl --user enable --now t3code.service
    ;;
  "service restart") systemctl --user restart t3code.service ;;
  "service uninstall")
    systemctl --user disable --now t3code.service
    rm -f "$U"
    systemctl --user daemon-reload
    ;;
  "pair --label")
    t=E2E"FIXTURE"
    printf 'App link: t3code://pair?pairingUrl=http%%3A%%2F%%2F127.0.0.1%%3A3773%%2Fpair%%23token%%3D%s\nToken: %s\n' "$t" "$t"
    ;;
  "uninstall -y")
    rm -f "$HOME/.local/bin/t3"
    rm -rf "$HOME/.t3/runtime"
    ;;
  *)
    echo "fake t3: unknown call $*" >&2
    exit 2
    ;;
esac
EOF
}

clientInstalls() {
  newCase
  umask 077
  local keysBefore out f homeDir=${homeDir:?} work=${work:?} repo=${repo:?} clientName=${clientName:?} sshPort=${sshPort:?} sshKey=${sshKey:?}
  [ -n "${remoteError:-}" ] && fail "$remoteError"
  clientPort="$(freePort)"
  launchBox "$clientName" "$clientPort" || fail "${boxError:-the client container did not start}"
  docker exec "$clientName" loginctl enable-linger homeuser || fail "cannot turn on lingering on the client"
  cat > "$work/ssh_config" <<EOF
Host e2e-hub
  HostName 127.0.0.1
  Port $sshPort
Host e2e-client
  HostName 127.0.0.1
  Port $clientPort
Host *
  User homeuser
  IdentityFile $sshKey
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF
  remote "cat $homeDir/.local/share/relaybar-helper/config.yaml" > "$work/hub-config.yaml" || fail "cannot read the hub settings"
  sed -n '/api-keys:/{n;s/^ *- *"\(.*\)"$/\1/p;}' "$work/hub-config.yaml" > "$work/access-key"
  [ -s "$work/access-key" ] || fail "the hub settings have no access key"
  keysBefore="$(remote "cat $homeDir/.ssh/authorized_keys")"
  [ -z "$(clientRemote 'command -v claude codex t3; true')" ] || fail "the client container already has one of the tools"
  writeInstallFixtures
  clientRemote "mkdir -p $homeDir/e2e-sites $homeDir/.codex && echo keep > $homeDir/.codex/keep.txt" || fail "cannot prepare the client"
  for f in claude.sh codex.sh t3.sh t3-fake; do
    clientRemote "cat > $homeDir/e2e-sites/$f" < "$work/sites/$f" || fail "cannot copy the fixture $f"
  done
  (cd "$repo" && perl -e 'alarm shift; exec @ARGV or exit 127' 1800 swift build --build-tests) > "$work/swift-build.log" 2>&1 || fail "swift build failed: $(cat "$work/swift-build.log")"

  installStep addInstalls e2eAddsTheClientWithInstalls

  for f in claude codex t3 claude-all codex-all; do
    clientRemote "test -x $homeDir/.local/bin/$f" || fail "$f is not in ~/.local/bin on the client"
  done
  [ "$(clientRemote "$homeDir/.local/bin/claude --version")" = "1.0.0 (Claude Code)" ] || fail "the installed Claude Code does not run"
  [ "$(clientRemote "cat $homeDir/e2e-sites/t3-channel")" = nightly ] || fail "T3 Code was not installed from the nightly channel"
  grep -q '^t3code://pair$' "$work/pair-marker" || fail "no pair link was handed to the app"
  clientRemote "grep -x 'service install' $homeDir/e2e-sites/t3-calls.log && grep -x 'pair --label Relaybar' $homeDir/e2e-sites/t3-calls.log" > /dev/null || fail "the fake t3 did not see service install and pair"
  [ "$(clientRemote 'systemctl --user is-active t3code.service')" = active ] || fail "the T3 Code service is not active on the client"
  clientRemote "grep -q 'exec \"\$HOME/.local/bin/claude\"' $homeDir/.local/bin/claude-all && grep -q 'exec \"\$HOME/.local/bin/codex\"' $homeDir/.local/bin/codex-all" || fail "claude-all and codex-all do not call the tools by their full path"
  clientRemote "cat $homeDir/.t3/userdata/settings.json" > "$work/settings-after.json" || fail "T3 Code settings were not written on the client"
  python3 -I -c '
import json, sys
data = json.load(open(sys.argv[1]))
found = data.get("providerInstances", {})
if sorted(found) != ["claudeAgent_all_accounts", "codex_all_accounts"]:
    sys.exit("entries: %s" % sorted(found))
home = sys.argv[2]
for key, tool in (("claudeAgent_all_accounts", "claude"), ("codex_all_accounts", "codex")):
    if found[key]["config"].get("binaryPath") != home + "/.local/bin/" + tool:
        sys.exit("binaryPath of %s: %s" % (key, found[key]["config"]))
' "$work/settings-after.json" "$homeDir" || fail "the T3 Code entries on the client are wrong"
  grep -rqF "E2EFIXTURE" "$work" && fail "the pair token was written to a file on this Mac"

  swiftStep remove e2eRemovesTheClient

  for f in .local/bin/claude .local/bin/codex .local/bin/t3 .local/bin/claude-all .local/bin/codex-all .local/share/claude .codex/packages .t3/runtime .config/systemd/user/t3code.service; do
    [ -z "$(clientRemote "ls -d $homeDir/$f 2> /dev/null; true")" ] || fail "Remove left $f on the client"
  done
  [ "$(clientRemote 'systemctl --user is-active t3code.service; true')" != active ] || fail "the T3 Code service is still active after Remove"
  clientRemote "grep -q 'Codex installer' $homeDir/.profile" && fail "Remove left the Codex block in ~/.profile"
  for f in .claude .claude.json .codex/keep.txt .t3/userdata/threads.db .t3/userdata/settings.json; do
    clientRemote "test -e $homeDir/$f" || fail "Remove deleted $f, which must stay"
  done
  out="$(clientRemote "find $homeDir -iname '*relaybar*' -not -name '*.relaybar-backup' 2> /dev/null; systemctl --user is-active relaybar-tunnel.service; true")"
  [ "$out" = "inactive" ] || [ "$out" = "unknown" ] || fail "the client still has Relaybar files or an active tunnel: $out"
  clientRemote "cat $homeDir/.t3/userdata/settings.json" > "$work/settings-restored.json"
  python3 -I -c '
import json, sys
data = json.load(open(sys.argv[1]))
sys.exit(1 if data.get("providerInstances") else 0)
' "$work/settings-restored.json" || fail "the T3 Code entries are still in the client settings"
  [ "$(remote "cat $homeDir/.ssh/authorized_keys")" = "$keysBefore" ] || fail "the hub authorized_keys is not as it was before the computer was added"
  echo "  none of the three tools were on the client; fixture installers put them in ~/.local/bin, the T3 Code service ran, entries got full paths, the pair link reached the app, and Remove left only chats, ~/.claude, ~/.claude.json and other files of the user"
}
