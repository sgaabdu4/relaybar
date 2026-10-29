#!/bin/bash
installStep() {
  local step=$1 name=$2 repo=${repo:?} work=${work:?} sites=file://${homeDir:?}/e2e-sites
  (
    cd "$repo" || exit 1
    env RELAYBAR_E2E_STEP="$step" RELAYBAR_E2E_SSH_CONFIG="$work/ssh_config" RELAYBAR_E2E_CLIENT_FILE="$work/client.json" \
      RELAYBAR_E2E_ACCESS_KEY_FILE="$work/access-key" RELAYBAR_E2E_PAIR_FILE="$work/pair-marker" RELAYBAR_E2E_REPLACE="${replaceLogins:-keep}" \
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
    echo 2 > "$HOME/.t3/fake-pending"
    printf 'App link: t3code://pair?pairingUrl=http%%3A%%2F%%2F127.0.0.1%%3A3773%%2Fpair%%23token%%3D%s\nToken: %s\n' "$t" "$t"
    ;;
  "auth pairing")
    if [ -e "$HOME/.t3/fake-pending" ]; then printf '[{"id":"pairing-1","label":"Relaybar","scopes":["owner"]}]\n'; else echo '[]'; fi
    ;;
  "auth session")
    case "$3" in
      list)
        if [ -e "$HOME/.t3/fake-pending" ]; then
          n=$(cat "$HOME/.t3/fake-pending")
          if [ "$n" -le 1 ]; then rm -f "$HOME/.t3/fake-pending"; echo e2e-session-1 > "$HOME/.t3/fake-session"; else echo $((n - 1)) > "$HOME/.t3/fake-pending"; fi
        fi
        if [ -e "$HOME/.t3/fake-session" ]; then printf '[{"sessionId":"%s","method":"one-time-token","client":{"label":"Relaybar"}}]\n' "$(cat "$HOME/.t3/fake-session")"; else echo '[]'; fi
        ;;
      revoke) rm -f "$HOME/.t3/fake-session" ;;
      *) echo "fake t3: unknown call $*" >&2; exit 2 ;;
    esac
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

writeLoginFixtures() {
  printf '%s' '{"claudeAiOauth":{"accessToken":"fixture-login"}}' | clientRemote "cat > $homeDir/.claude/.credentials.json" || fail "cannot write the Claude login fixture"
  printf '%s\n' '{"model":"sample-model","env":{"ANTHROPIC_AUTH_TOKEN":"old-token","KEEP":"1"}}' | clientRemote "cat > $homeDir/.claude/settings.json" || fail "cannot write the Claude settings fixture"
  printf '%s' '{"tokens":{"fixture":true}}' | clientRemote "cat > $homeDir/.codex/auth.json" || fail "cannot write the Codex login fixture"
  printf '%s\n' 'model = "sample"' 'model_provider = "other"' '' '[mcp_servers.x]' 'command = "x"' '' '[model_providers.relaybar]' 'name = "old"' | clientRemote "cat > $homeDir/.codex/config.toml" || fail "cannot write the Codex config fixture"
}

checkLoginsBack() {
  local homeDir=${homeDir:?} loginsBefore=${loginsBefore:?}
  [ "$(clientRemote "cd $homeDir && sha256sum .claude/.credentials.json .claude/settings.json .codex/auth.json .codex/config.toml")" = "$loginsBefore" ] || fail "$1: the Claude Code and Codex login and settings files are not as they were"
  [ -z "$(clientRemote "ls -d $homeDir/.config/relaybar/kept $homeDir/.claude-hub $homeDir/.codex-hub 2> /dev/null; true")" ] || fail "$1: a kept folder or an old hub folder is left"
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
  clientRemote "mkdir -p $homeDir/e2e-sites $homeDir/.codex $homeDir/.claude && echo keep > $homeDir/.codex/keep.txt" || fail "cannot prepare the client"
  writeLoginFixtures
  loginsBefore="$(clientRemote "cd $homeDir && sha256sum .claude/.credentials.json .claude/settings.json .codex/auth.json .codex/config.toml")" || fail "cannot read the client logins"
  for f in claude.sh codex.sh t3.sh t3-fake; do
    clientRemote "cat > $homeDir/e2e-sites/$f" < "$work/sites/$f" || fail "cannot copy the fixture $f"
  done
  (cd "$repo" && perl -e 'alarm shift; exec @ARGV or exit 127' 1800 swift build --build-tests) > "$work/swift-build.log" 2>&1 || fail "swift build failed: $(cat "$work/swift-build.log")"

  replaceLogins=keep installStep addInstalls e2eAddsTheClientWithInstalls

  for f in claude codex t3 claude+ codex+; do
    clientRemote "test -x $homeDir/.local/bin/$f" || fail "$f is not in ~/.local/bin on the client"
  done
  [ "$(clientRemote "$homeDir/.local/bin/claude --version")" = "1.0.0 (Claude Code)" ] || fail "the installed Claude Code does not run"
  [ "$(clientRemote "$homeDir/.local/bin/claude+ --version")" = "1.0.0 (Claude Code)" ] || fail "claude+ does not run Claude Code"
  clientRemote "$homeDir/.local/bin/codex+ --version" | grep -q '^codex-cli 1.0.0$' || fail "codex+ does not run Codex"
  [ "$(clientRemote "cat $homeDir/e2e-sites/t3-channel")" = nightly ] || fail "T3 Code was not installed from the nightly channel"
  grep -q '^t3code://pair$' "$work/pair-marker" || fail "no pair link was handed to the app"
  clientRemote "grep -x 'service install' $homeDir/e2e-sites/t3-calls.log && grep -x 'pair --label Relaybar' $homeDir/e2e-sites/t3-calls.log" > /dev/null || fail "the fake t3 did not see service install and pair"
  [ "$(clientRemote 'systemctl --user is-active t3code.service')" = active ] || fail "the T3 Code service is not active on the client"
  clientRemote "test -e $homeDir/.t3/fake-session && ! test -e $homeDir/.t3/fake-pending" || fail "the add did not wait for the link to be confirmed in T3 Code"
  grep -q 'e2e-session-1' "$work/client.json" || fail "the T3 Code session was not recorded"
  clientRemote "grep -q 'exec \"\$HOME/.local/bin/claude\"' $homeDir/.local/bin/claude+ && grep -q 'exec \"\$HOME/.local/bin/codex\" -c ' $homeDir/.local/bin/codex+" || fail "claude+ and codex+ do not call the tools by their full path"
  clientRemote "grep -q CODEX_HOME $homeDir/.local/bin/codex+ || grep -q CLAUDE_CONFIG_DIR $homeDir/.local/bin/claude+" && fail "the launchers set a config folder"
  [ -z "$(clientRemote "ls -d $homeDir/.claude-hub $homeDir/.codex-hub 2> /dev/null; true")" ] || fail "a hub folder was made on the client"
  [ "$(clientRemote "cd $homeDir && sha256sum .claude/.credentials.json .claude/settings.json .codex/auth.json .codex/config.toml")" = "$loginsBefore" ] || fail "Keep Them changed a login or settings file"
  clientRemote "cat $homeDir/.t3/userdata/settings.json" > "$work/settings-after.json" || fail "T3 Code settings were not written on the client"
  python3 -I -c '
import json, sys
data = json.load(open(sys.argv[1]))
found = data.get("providerInstances", {})
if sorted(found) != ["claudeAgent_all_accounts", "codex_all_accounts"]:
    sys.exit("entries: %s" % sorted(found))
home = sys.argv[2]
want = {"claudeAgent_all_accounts": ("Claude+", home + "/.local/bin/claude"), "codex_all_accounts": ("Codex+", home + "/.local/bin/codex+")}
for key, (name, binary) in want.items():
    if found[key]["displayName"] != name or found[key]["config"] != {"binaryPath": binary}:
        sys.exit("entry %s: %s" % (key, found[key]))
' "$work/settings-after.json" "$homeDir" || fail "the T3 Code entries on the client are wrong"
  grep -rqF "E2EFIXTURE" "$work" && fail "the pair token was written to a file on this Mac"

  swiftStep remove e2eRemovesTheClient

  for f in .local/bin/claude .local/bin/codex .local/bin/t3 .local/bin/claude+ .local/bin/codex+ .local/share/claude .codex/packages .t3/runtime .config/systemd/user/t3code.service; do
    [ -z "$(clientRemote "ls -d $homeDir/$f 2> /dev/null; true")" ] || fail "Remove left $f on the client"
  done
  checkLoginsBack "after Keep Them"

  replaceLogins=replace installStep addInstalls e2eAddsTheClientWithInstalls
  [ -z "$(clientRemote "ls $homeDir/.claude/.credentials.json $homeDir/.codex/auth.json 2> /dev/null; true")" ] || fail "Replace left a login file in place"
  [ -z "$(clientRemote "ls $homeDir/.local/bin/claude+ $homeDir/.local/bin/codex+ 2> /dev/null; true")" ] || fail "Replace made claude+ or codex+"
  [ "$(clientRemote "stat -c %a $homeDir/.config/relaybar/kept")" = 700 ] || fail "the kept folder is not mode 0700"
  [ "$(clientRemote "cd $homeDir/.config/relaybar/kept && sha256sum claude-credentials.json codex-auth.json | cut -d' ' -f1")" = "$(printf '%s\n' "$loginsBefore" | sed -n '1p;3p' | cut -d' ' -f1)" ] || fail "the kept logins are not the originals"
  clientRemote "cat $homeDir/.claude/settings.json" > "$work/claude-settings.json"
  clientRemote "cat $homeDir/.codex/config.toml" > "$work/codex-config.toml"
  python3 -I -c '
import json, sys, tomllib
home = sys.argv[3]
settings = json.load(open(sys.argv[1]))
if settings.get("apiKeyHelper") != "/bin/cat \x27%s/.config/relaybar/access-key\x27" % home:
    sys.exit("apiKeyHelper: %s" % settings.get("apiKeyHelper"))
if settings.get("env") != {"ANTHROPIC_BASE_URL": "http://127.0.0.1:8317", "KEEP": "1"} or settings.get("model") != "sample-model":
    sys.exit("settings: %s" % settings)
config = tomllib.load(open(sys.argv[2], "rb"))
provider = config["model_providers"]["relaybar"]
if config.get("model_provider") != "relaybar" or config.get("model") != "sample" or config["mcp_servers"]["x"] != {"command": "x"}:
    sys.exit("config: %s" % config)
if provider["base_url"] != "http://127.0.0.1:8317/v1" or provider["auth"] != {"command": "/bin/cat", "args": [home + "/.config/relaybar/access-key"]}:
    sys.exit("provider: %s" % provider)
' "$work/claude-settings.json" "$work/codex-config.toml" "$homeDir" || fail "the Claude Code settings or Codex config on the client are wrong"
  ! grep -qF -f "$work/access-key" "$work/claude-settings.json" "$work/codex-config.toml" || fail "the access key was written into the settings or the config"
  helper="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["apiKeyHelper"])' "$work/claude-settings.json")"
  cat > "$work/helper-headers.sh" <<EOF
key=\$($helper)
other=\$(cat "\$HOME/.config/relaybar/access-key")
[ "\$key" = "\$other" ] || { echo "the helper command and the key file differ"; exit 0; }
c() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "\$@" http://127.0.0.1:8317/v1/models; }
echo "\$(c -H "x-api-key: \$key" -H "Authorization: Bearer \$key") \$(c -H "x-api-key: \$key") \$(c -H "Authorization: Bearer \$key") \$(c) \$(c -H "x-api-key: wrong" -H "Authorization: Bearer wrong")"
EOF
  out="$(clientRemote sh -s < "$work/helper-headers.sh")" || fail "cannot query the helper from the client"
  case "$out" in "200 "*" "*" 401 401") ;; *) fail "the apiKeyHelper key was not accepted by the real helper (both headers, x-api-key only, bearer only, none, wrong: '$out')" ;; esac
  headersResult="$out"
  clientRemote "cat $homeDir/.t3/userdata/settings.json" > "$work/settings-replace.json"
  python3 -I -c '
import json, sys
sys.exit(1 if json.load(open(sys.argv[1])).get("providerInstances") else 0)
' "$work/settings-replace.json" || fail "Replace added T3 Code entries"
  swiftStep remove e2eRemovesTheClient
  checkLoginsBack "after Replace"
  [ -z "$(clientRemote "ls -d $homeDir/.local/bin/claude+ $homeDir/.local/bin/codex+ 2> /dev/null; true")" ] || fail "Remove left claude+ or codex+"
  clientRemote "cat $homeDir/.t3/userdata/settings.json" > "$work/settings-restored.json"
  python3 -I -c '
import json, sys
data = json.load(open(sys.argv[1]))
sys.exit(1 if data.get("providerInstances") else 0)
' "$work/settings-restored.json" || fail "the T3 Code entries are still in the client settings"
  [ "$(remote "cat $homeDir/.ssh/authorized_keys")" = "$keysBefore" ] || fail "the hub authorized_keys is not as it was before the computer was added"
  echo "  none of the three tools were on the client; Keep Them gave claude+ and codex+ and the Claude+ and Codex+ entries; Replace set apiKeyHelper and the Codex provider, the real helper answered '$headersResult' (both headers, x-api-key only, bearer only, none, wrong), and Remove put every login and settings file back byte for byte"
}
