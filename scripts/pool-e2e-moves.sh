#!/bin/bash
targetRemote() { boxSsh "$targetPort" "$@"; }

writeClientQuery() {
  cat > "$1" <<'EOF'
umask 077
H=$(mktemp)
trap 'rm -f "$H"' EXIT
printf 'Authorization: Bearer %s\n' "$(cat "$HOME/.config/relaybar/access-key")" > "$H"
plain=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8317/v1/models)
keyed=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "@$H" http://127.0.0.1:8317/v1/models)
echo "$plain $keyed"
EOF
}

expectNoHelper() {
  local who=$1 run=$2 keys=$3 out homeDir=${homeDir:?}
  out="$($run "systemctl --user list-unit-files 'relaybar-*' --no-legend 2> /dev/null; ls -A $homeDir/.local/share/relaybar-helper $homeDir/.local/share/relaybar 2> /dev/null; grep -lx cli-proxy-api /proc/[0-9]*/comm 2> /dev/null; true")"
  [ -z "$out" ] || fail "$who still has helper units, folders or a helper process: $out"
  [ "$($run 'curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8317/v1/models; true')" = 000 ] || fail "port 8317 still answers on $who"
  [ "$($run "grep -c relaybar-client $homeDir/.ssh/authorized_keys; true")" = 0 ] || fail "$who still holds a tagged client key"
  [ "$($run "cat $homeDir/.ssh/authorized_keys")" = "$keys" ] || fail "the authorized_keys of $who is not as it was before the move"
}

expectClientAnswers() {
  local out work=${work:?}
  out="$(clientRemote sh -s < "$work/query.sh")" || fail "cannot query the helper from the client"
  [ "$out" = "401 200" ] || fail "through the client tunnel models answered '$out' (without key, with key), expected '401 200'"
}

expectNewHelper() {
  local who=$1 run=$2 keys=$3 homeDir=${homeDir:?} work=${work:?}
  [ "$($run 'systemctl --user is-active relaybar-helper.service; true')" = active ] || fail "the helper is not active on $who"
  $run "cat $homeDir/.local/share/relaybar-helper/config.yaml" > "$work/new-config.yaml" || fail "cannot read the settings on $who"
  [ "$(sed -n '/api-keys:/{n;s/^ *- *"\(.*\)"$/\1/p;}' "$work/new-config.yaml")" = "$(cat "$work/access-key")" ] || fail "the access key on $who is not the same"
  secretHeader "$work/mgmt-header" "$(cat "$work/mgmt-secret")"
  [ "$($run 'curl -s -o /dev/null -w "%{http_code}" --max-time 5 -H @- http://127.0.0.1:8317/v8/management/credentials; true' < "$work/mgmt-header")" = 200 ] || fail "the management secret on $who is not the same"
  [ "$($run "grep -c ' relaybar-client:' $homeDir/.ssh/authorized_keys")" = 1 ] || fail "$who does not hold exactly one tagged key"
  [ "$($run "grep -c ' relaybar-client:e2e-client\$' $homeDir/.ssh/authorized_keys")" = 1 ] || fail "the tagged key on $who is not the one of the added computer"
  [ "$($run "grep -v ' relaybar-client:' $homeDir/.ssh/authorized_keys")" = "$keys" ] || fail "the other keys on $who changed"
}

helperMoves() {
  newCase
  umask 077
  local clientPort targetPort aIp bIp keysA keysB report i homeDir=${homeDir:?} work=${work:?} repo=${repo:?}
  local clientName=${clientName:?} targetName=${targetName:?} containerName=${containerName:?} sshPort=${sshPort:?} sshKey=${sshKey:?}
  local helperScript=${helperScript:?}
  [ -n "${remoteError:-}" ] && fail "$remoteError"
  clientPort="$(freePort)"
  launchBox "$clientName" "$clientPort" || fail "${boxError:-the client container did not start}"
  targetPort="$(freePort)"
  launchBox "$targetName" "$targetPort" || fail "${boxError:-the target container did not start}"
  docker exec "$clientName" loginctl enable-linger homeuser || fail "cannot turn on lingering on the client"
  docker exec "$targetName" loginctl enable-linger homeuser || fail "cannot turn on lingering on the target"
  aIp="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$containerName")"
  bIp="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$targetName")"
  [ -n "$aIp" ] && [ -n "$bIp" ] || fail "cannot read the container addresses"
  cat > "$work/ssh_config" <<EOF
Host e2e-hub
  HostName 127.0.0.1
  Port $sshPort
Host e2e-client
  HostName 127.0.0.1
  Port $clientPort
Host e2e-target
  HostName 127.0.0.1
  Port $targetPort
Host *
  User homeuser
  IdentityFile $sshKey
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF
  randomHex > "$work/mgmt-secret"
  remote "sed -i 's|^\( *secret-key: *\).*\$|\1\"$(cat "$work/mgmt-secret")\"|' $homeDir/.local/share/relaybar-helper/config.yaml && systemctl --user restart relaybar-helper.service" || fail "cannot set a known management secret on the hub"
  remote "cat $homeDir/.local/share/relaybar-helper/config.yaml" > "$work/hub-config.yaml" || fail "cannot read the hub settings"
  sed -n '/api-keys:/{n;s/^ *- *"\(.*\)"$/\1/p;}' "$work/hub-config.yaml" > "$work/access-key"
  [ -s "$work/access-key" ] && [ "$(sed -n 's/^ *secret-key: *"\(.*\)"$/\1/p' "$work/hub-config.yaml")" = "$(cat "$work/mgmt-secret")" ] || fail "the hub settings do not hold the known keys"
  for ((i = 0; i < 30; i++)); do
    [ "$(remote 'curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8317/v1/models; true')" = 401 ] && break
    sleep 1
  done
  [ "$(remote 'curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8317/v1/models; true')" = 401 ] || fail "the hub helper did not come back after the restart"
  remote "cat $homeDir/e2e/releases.json" | targetRemote "mkdir -p $homeDir/e2e && cat > $homeDir/e2e/releases.json" || fail "cannot copy the release list to the target"
  remote "cat $homeDir/e2e/blocked.txt" | targetRemote "cat > $homeDir/e2e/blocked.txt" || fail "cannot copy the block list to the target"
  sed -e "s|https://api.github.com/repos/router-for-me/CLIProxyAPI/releases?per_page=30|file://$homeDir/e2e/releases.json|" \
    -e "s|https://raw.githubusercontent.com/sgaabdu4/relaybar/main/pool/blocked-versions.txt|file://$homeDir/e2e/blocked.txt|" \
    "$helperScript" > "$work/relaybar-helper.patched.sh"
  [ "$(grep -c "file://$homeDir/e2e/" "$work/relaybar-helper.patched.sh")" = 2 ] || fail "cannot point the update script at the fixture release list"
  keysA="$(remote "cat $homeDir/.ssh/authorized_keys")"
  keysB="$(targetRemote "cat $homeDir/.ssh/authorized_keys")"
  writeClientQuery "$work/query.sh"
  (cd "$repo" && perl -e 'alarm shift; exec @ARGV or exit 127' 1800 swift build --build-tests) > "$work/swift-build.log" 2>&1 || fail "swift build failed: $(cat "$work/swift-build.log")"

  swiftStep add e2eAddsTheClient
  expectClientAnswers

  RELAYBAR_E2E_LOCAL_PORT="$(freePort)"
  export RELAYBAR_E2E_HOME="$work/mac-home" RELAYBAR_E2E_LOCAL_PORT RELAYBAR_E2E_SCRIPT_FILE="$work/relaybar-helper.patched.sh" \
    RELAYBAR_E2E_MGMT_FILE="$work/mgmt-secret" RELAYBAR_E2E_REPORT="$work/move-report"
  mkdir -p "$RELAYBAR_E2E_HOME"
  trap 'stopTracked "$work"; pkill -f "127.0.0.1:$RELAYBAR_E2E_LOCAL_PORT:127.0.0.1:8317" 2> /dev/null' EXIT

  RELAYBAR_E2E_MOVE_FROM=e2e-hub RELAYBAR_E2E_MOVE_TO=e2e-target swiftStep move e2eMovesTheHelper
  report="$(cat "$work/move-report")"
  [ "$report" = "$(printf 'left=\ncomputers=\npassword=')" ] || fail "the first move left something undone: $report"
  expectClientAnswers
  expectNoHelper "the old computer" remote "$keysA"
  expectNewHelper "the new computer" targetRemote "$keysB"
  clientRemote "cat $homeDir/.config/systemd/user/relaybar-tunnel.service" > "$work/client-unit" || fail "cannot read the tunnel unit on the client"
  grep -q "$bIp" "$work/client-unit" || fail "the tunnel unit on the client does not point at the new computer"
  ! grep -q "$aIp" "$work/client-unit" || fail "the tunnel unit on the client still points at the old computer"
  echo "  moved the helper A to B: the client answers 401 and 200 through B; A has no helper unit, folder, process, port 8317 or tagged key; B holds the same keys and exactly the client's tagged key"

  RELAYBAR_E2E_MOVE_FROM=e2e-target RELAYBAR_E2E_MOVE_TO=e2e-hub RELAYBAR_E2E_STOP_AFTER_SWITCH="$targetName" swiftStep move e2eMovesTheHelper
  report="$(cat "$work/move-report")"
  [ "$report" = "$(printf 'left=e2e-target\ncomputers=\npassword=')" ] || fail "the move with the old computer off did not report it as left: $report"
  expectClientAnswers
  expectNewHelper "the first computer again" remote "$keysA"
  docker start "$targetName" > /dev/null || fail "cannot start the old computer again"
  for ((i = 0; i < 90; i++)); do
    targetRemote true > /dev/null 2>&1 && break
    sleep 1
  done
  targetRemote true > /dev/null 2>&1 || fail "the old computer did not answer SSH after it was started"
  [ "$(targetRemote "[ -e $homeDir/.local/share/relaybar-helper ] && echo there; true")" = there ] || fail "the old helper folder was already gone before the pending cleanup ran"

  RELAYBAR_E2E_MOVE_FROM=e2e-target RELAYBAR_E2E_MOVE_TO=e2e-hub swiftStep settle e2eSettlesTheMove
  report="$(cat "$work/move-report")"
  [ "$report" = "$(printf 'left=\ncomputers=\npassword=')" ] || fail "the pending cleanup left something undone: $report"
  expectNoHelper "the old computer after the pending cleanup" targetRemote "$keysB"
  expectClientAnswers
  expectNewHelper "the first computer after the pending cleanup" remote "$keysA"
  echo "  moved the helper B to A with B stopped during the move; the pending cleanup removed everything from B when it was back; the client still answers 401 and 200"
}
