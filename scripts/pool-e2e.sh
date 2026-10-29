#!/bin/bash
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd -P)"
helperScript="$repo/Resources/relaybar-helper.sh"
dockerfile="$repo/scripts/pool-linux.Dockerfile"
releaseVersion=8.0.44
githubDownload=https://github.com/router-for-me/CLIProxyAPI/releases/download
cache="${RELAYBAR_E2E_CACHE:-${TMPDIR:-/tmp}/relaybar-pool-e2e-cache}"
containerName=rb-pool-e2e
clientName=rb-pool-e2e-client
homeDir=/home/homeuser
imageTag=relaybar-pool-linux

usage() {
  cat <<'EOF'
Usage: scripts/pool-e2e.sh [--local] [--update] [--remote]
  no flag   the local real-binary cases: modelsNeedTheKey picksUpANewLogin prioritySticks sandboxBlocksHomeFiles
  --local   the local real-binary cases (when combined with other flags)
  --update  updateRules: the update script against a fixture release server
  --remote  remoteInstall, tunnelComesBack, clientConnects and remoteStop against Linux containers in Docker
Set RELAYBAR_E2E_CACHE to keep the downloaded release between runs.
EOF
}

wantLocal=0
wantUpdate=0
wantRemote=0
for arg in "$@"; do
  case "$arg" in
    --local) wantLocal=1 ;;
    --update) wantUpdate=1 ;;
    --remote) wantRemote=1 ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done
if [ $wantUpdate = 0 ] && [ $wantRemote = 0 ]; then
  wantLocal=1
fi

root="$(mktemp -d "${TMPDIR:-/tmp}/relaybar-pool-e2e.XXXXXX")"
root="$(cd "$root" && pwd -P)"
failures=0

stopTracked() {
  local dir=$1 pid file tries
  for file in "$dir/pids" "$dir/fake.pid"; do
    [ -f "$file" ] || continue
    while read -r pid; do
      kill "$pid" 2> /dev/null
    done < "$file"
    while read -r pid; do
      tries=0
      while kill -0 "$pid" 2> /dev/null && [ $tries -lt 50 ]; do
        sleep 0.1
        tries=$((tries + 1))
      done
      kill -9 "$pid" 2> /dev/null
    done < "$file"
  done
  return 0
}

cleanupAll() {
  local dir
  for dir in "$root"/case.*; do
    [ -d "$dir" ] && stopTracked "$dir"
  done
  if [ -f "$root/docker-started" ]; then
    docker rm -f "$containerName" "$clientName" > /dev/null 2>&1
  fi
  rm -rf "$root"
}
trap cleanupAll EXIT
trap 'exit 130' INT TERM

fail() {
  printf '%s\n' "$*" > "$root/reason"
  exit 1
}

runCase() {
  local name=$1
  rm -f "$root/reason"
  if ("$name"); then
    echo "PASS $name"
  else
    echo "FAIL $name: $(cat "$root/reason" 2> /dev/null || echo "unexpected error, see the lines above")"
    failures=$((failures + 1))
  fi
}

newCase() {
  work="$(mktemp -d "$root/case.XXXXXX")"
  trap 'stopTracked "$work"' EXIT
}

trackPid() {
  echo "$1" >> "$work/pids"
  disown "$1" 2> /dev/null
}

randomHex() { head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

freePort() {
  python3 -I -c '
import socket, sys
for port in range(int(sys.argv[1]), 65000):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", port))
    except OSError:
        s.close()
        continue
    s.close()
    print(port)
    break
' "$((18500 + RANDOM % 3000))"
}

httpCode() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }

waitFor401() {
  local url=$1 seconds=$2 i
  for ((i = 0; i < seconds; i++)); do
    [ "$(httpCode "$url")" = 401 ] && return 0
    sleep 1
  done
  return 1
}

chipName() {
  case "$(uname -m)" in
    arm64 | aarch64) echo aarch64 ;;
    *) echo amd64 ;;
  esac
}

checksumOf() { shasum -a 256 "$1" | awk '{ print $1 }'; }

fetchRelease() {
  local chip asset expected
  chip="$(chipName)"
  asset="CLIProxyAPI_${releaseVersion}_darwin_${chip}.tar.gz"
  mkdir -p "$cache"
  [ -s "$cache/checksums.txt" ] || curl -fsSL --max-time 60 -o "$cache/checksums.txt" "$githubDownload/v$releaseVersion/checksums.txt" || fail "cannot download checksums.txt"
  if [ ! -s "$cache/$asset" ]; then
    curl -fsSL --max-time 600 -o "$cache/$asset.part" "$githubDownload/v$releaseVersion/$asset" || fail "cannot download $asset"
    mv "$cache/$asset.part" "$cache/$asset"
  fi
  expected="$(awk -v f="$asset" '$2 == f { print $1 }' "$cache/checksums.txt")"
  [ -n "$expected" ] || fail "no checksum for $asset in checksums.txt"
  if [ "$(checksumOf "$cache/$asset")" != "$expected" ]; then
    rm -f "$cache/$asset"
    fail "checksum mismatch for $asset"
  fi
  releaseAsset="$cache/$asset"
}

secretHeader() { printf 'Authorization: Bearer %s\n' "$2" > "$1"; }

writeConfig() {
  cat > "$helper/config.yaml" <<EOF
config-version: 8
server:
  host: "127.0.0.1"
  port: $port
management:
  allow-remote: false
  secret-key: "$secret"
  disable-control-panel: true
access:
  api-keys:
    - "$key"
routing:
  strategy: "round-robin"
  session-affinity: true
  session-affinity-ttl: "1h"
  session-affinity-subagents: true
  session-affinity-rebind-on: "quota"
  retry:
    request-retry: 3
    max-retry-interval: 30
oauth:
  auth-dir: "$helper/auth"
observability:
  logs:
    logging-to-file: false
    request-log: false
  usage:
    usage-statistics-enabled: false
plugins:
  enabled: false
EOF
}

keychainDeny='(deny mach-lookup (global-name "com.apple.SecurityServer") (global-name "com.apple.securityd.xpc") (global-name "com.apple.secd") (global-name "com.apple.security.keychaind"))'

setupRealFixture() {
  newCase
  umask 077
  fetchRelease
  home="$work/home"
  helper="$home/Library/Application Support/Relaybar/Helper"
  mkdir -p "$helper/auth" "$helper/versions/$releaseVersion"
  tar -xzf "$releaseAsset" -C "$helper/versions/$releaseVersion" cli-proxy-api || fail "cannot unpack the release"
  ln -s "versions/$releaseVersion" "$helper/current"
  port="$(freePort)"
  key="$(randomHex)"
  secret="$(randomHex)"
  secretHeader "$work/key.hdr" "$key"
  secretHeader "$work/mgmt.hdr" "$secret"
  writeConfig
  echo canary > "$home/canary.txt"
  cat > "$work/helper.sb" <<EOF
(version 1)
(allow default)
(deny file-read* file-write* (subpath "$home"))
(allow file-read* file-write* (subpath "$helper"))
(deny file-write* (subpath "$helper/versions"))
(allow file-read-metadata (literal "$home"))
(deny process-exec*)
(allow process-exec* (subpath "$helper/versions"))
(deny process-fork)
(deny appleevent-send)
(deny mach-lookup (global-name "com.apple.SecurityServer") (global-name "com.apple.securityd.xpc") (global-name "com.apple.secd") (global-name "com.apple.security.keychaind") (global-name "com.apple.coreservices.launchservicesd") (global-name "com.apple.lsd.mapdb") (global-name "com.apple.coreservices.quarantine-resolver"))
(deny file-write* (subpath "/private/tmp") (subpath "/tmp") (subpath "/Users/Shared"))
EOF
  { cat "$work/helper.sb"; echo '(allow process-exec* (literal "/bin/cat") (literal "/usr/bin/touch") (literal "/bin/sh") (literal "/bin/bash"))'; } > "$work/probe.sb"
  printf '(version 1)\n(allow default)\n%s\n' "$keychainDeny" > "$work/keychain.sb"
}

startHelper() {
  (cd "$helper" && exec /usr/bin/sandbox-exec -f "$work/helper.sb" "$helper/current/cli-proxy-api" -config "$helper/config.yaml") > /dev/null 2>&1 < /dev/null &
  trackPid $!
  waitFor401 "http://127.0.0.1:$port/v1/models" 40 || fail "the helper did not answer on port $port within 40 s"
}

emails() {
  python3 -I -c '
import json, sys
def walk(x):
    if isinstance(x, dict):
        if "email" in x:
            yield x
        for v in x.values():
            yield from walk(v)
    elif isinstance(x, list):
        for v in x:
            yield from walk(v)
for e in walk(json.load(open(sys.argv[1]))):
    print(e["email"])
' "$1"
}

modelsNeedTheKey() {
  setupRealFixture
  startHelper
  local url="http://127.0.0.1:$port/v1/models" code
  code="$(httpCode "$url")"
  [ "$code" = 401 ] || fail "without the key the answer was $code, expected 401"
  secretHeader "$work/bad.hdr" "$(randomHex)"
  code="$(httpCode -H "@$work/bad.hdr" "$url")"
  [ "$code" = 401 ] || fail "with a wrong key the answer was $code, expected 401"
  code="$(curl -s -o "$work/models.json" -w '%{http_code}' --max-time 5 -H "@$work/key.hdr" "$url")"
  [ "$code" = 200 ] || fail "with the key the answer was $code, expected 200"
  python3 -I -c '
import json, sys
data = json.load(open(sys.argv[1]))
sys.exit(0 if data.get("data") in ([], None) else 1)
' "$work/models.json" || fail "the model list is not empty before any sign-in"
}

picksUpANewLogin() {
  setupRealFixture
  startHelper
  local url="http://127.0.0.1:$port/v8/management/credentials" code i
  code="$(curl -s -o "$work/before.json" -w '%{http_code}' --max-time 5 -H "@$work/mgmt.hdr" "$url")"
  [ "$code" = 200 ] || fail "the credential list answered $code before the login, expected 200"
  emails "$work/before.json" | grep -qx 'demo@example.com' && fail "the sample login is listed before it was added"
  printf '%s' '{"type":"claude","email":"demo@example.com","access_token":"x","refresh_token":"y","expired":"2099-01-01T00:00:00Z"}' > "$work/login.part"
  mv "$work/login.part" "$helper/auth/claude-demo@example.com.json"
  for ((i = 1; i <= 12; i++)); do
    sleep 1
    curl -s -o "$work/after.json" --max-time 5 -H "@$work/mgmt.hdr" "$url"
    if emails "$work/after.json" 2> /dev/null | grep -qx 'demo@example.com'; then
      python3 -I -c '
import json, sys
def walk(x):
    if isinstance(x, dict):
        if x.get("email") == "demo@example.com":
            yield x
        for v in x.values():
            yield from walk(v)
    elif isinstance(x, list):
        for v in x:
            yield from walk(v)
entries = list(walk(json.load(open(sys.argv[1]))))
missing = [k for k in ("email", "provider", "name", "auth_index", "disabled", "status") if k not in entries[0]]
if missing:
    print("missing fields: " + ", ".join(missing))
    sys.exit(1)
' "$work/after.json" || fail "the listed login lacks expected fields"
      echo "  login listed after $i s without a restart"
      return 0
    fi
  done
  fail "the new login did not appear in the credential list within 12 s"
}

prioritySticks() {
  setupRealFixture
  startHelper
  local base="http://127.0.0.1:$port/v8/management/credentials" name="claude-demo@example.com.json" code i seen=""
  printf '%s' '{"type":"claude","email":"demo@example.com","access_token":"x","refresh_token":"y","expired":"2099-01-01T00:00:00Z"}' > "$work/login.part"
  mv "$work/login.part" "$helper/auth/$name"
  for ((i = 1; i <= 12; i++)); do
    sleep 1
    curl -s -o "$work/list.json" --max-time 5 -H "@$work/mgmt.hdr" "$base"
    if emails "$work/list.json" 2> /dev/null | grep -qx 'demo@example.com'; then
      seen=1
      break
    fi
  done
  [ -n "$seen" ] || fail "the sample login did not appear in the credential list within 12 s"
  code="$(curl -s -o "$work/patch.json" -w '%{http_code}' --max-time 5 -X PATCH -H "@$work/mgmt.hdr" -H 'Content-Type: application/json' -d "{\"name\":\"$name\",\"priority\":7}" "$base/fields")"
  [ "$code" = 200 ] || fail "setting the priority answered $code, expected 200"
  curl -s -o "$work/list.json" --max-time 5 -H "@$work/mgmt.hdr" "$base"
  python3 -I -c '
import json, sys
def walk(x):
    if isinstance(x, dict):
        if x.get("email") == "demo@example.com":
            yield x
        for v in x.values():
            yield from walk(v)
    elif isinstance(x, list):
        for v in x:
            yield from walk(v)
entries = list(walk(json.load(open(sys.argv[1]))))
sys.exit(0 if entries and entries[0].get("priority") == 7 else 1)
' "$work/list.json" || fail "the list does not show priority 7 after setting it"
}

sandboxBlocksHomeFiles() {
  setupRealFixture
  local profile="$work/probe.sb" plain sandboxed outside="/private/tmp/relaybar-e2e-probe-$$" code
  startHelper
  [ "$(httpCode "http://127.0.0.1:$port/v1/models")" = 401 ] || fail "the sandboxed helper does not answer 401 on /v1/models"
  if /usr/bin/sandbox-exec -f "$profile" /bin/cat "$home/canary.txt" > /dev/null 2>&1; then
    fail "a file in the fixture home was readable under the profile"
  fi
  /bin/cat "$home/canary.txt" > /dev/null 2>&1 || fail "the canary file is not readable outside the profile (bad fixture)"
  /usr/bin/sandbox-exec -f "$profile" /bin/cat "$helper/auth/../config.yaml" > /dev/null 2>&1 || fail "a file inside the helper folder was not readable under the profile"
  /usr/bin/sandbox-exec -f "$profile" /usr/bin/touch "$helper/auth/probe-write" > /dev/null 2>&1 || fail "the helper folder was not writable under the profile"
  if /usr/bin/sandbox-exec -f "$profile" /usr/bin/touch "$home/probe-write" > /dev/null 2>&1; then
    fail "the fixture home was writable under the profile"
  fi
  /usr/bin/sandbox-exec -f "$work/helper.sb" /bin/sh -c true > /dev/null 2>&1
  code=$?
  [ $code = 71 ] || fail "starting /bin/sh under the helper profile gave exit $code, expected 71 (refused)"
  /usr/bin/sandbox-exec -f "$work/helper.sb" /usr/bin/open -h > /dev/null 2>&1
  code=$?
  [ $code = 71 ] || fail "starting /usr/bin/open under the helper profile gave exit $code, expected 71 (refused)"
  /usr/bin/sandbox-exec -f "$profile" /bin/sh -c true > /dev/null 2>&1 || fail "the probe profile could not start /bin/sh (bad fixture)"
  if /usr/bin/sandbox-exec -f "$profile" /usr/bin/touch "$outside" > /dev/null 2>&1; then
    rm -f "$outside"
    fail "a file in /private/tmp was writable under the profile"
  fi
  [ ! -e "$outside" ] || fail "the refused write left a file in /private/tmp"
  [ "$(httpCode -H "@$work/key.hdr" "http://127.0.0.1:$port/v1/models")" = 200 ] || fail "the sandboxed helper does not answer 200 with the key"
  echo "  the helper still answers 401 and 200 under the profile; sh, open and writes to /private/tmp are refused"
  /usr/bin/security find-generic-password -s relaybar-e2e-no-such-service > /dev/null 2> "$work/keychain-plain.txt" < /dev/null
  plain=$?
  /usr/bin/sandbox-exec -f "$work/keychain.sb" /usr/bin/security find-generic-password -s relaybar-e2e-no-such-service > /dev/null 2> "$work/keychain-denied.txt" < /dev/null
  sandboxed=$?
  if [ "$plain" != "$sandboxed" ] || ! cmp -s "$work/keychain-plain.txt" "$work/keychain-denied.txt"; then
    echo "  Keychain service lookup behaves differently under the deny rule (exit $plain without, $sandboxed with)"
  else
    echo "  skipped the Keychain check: same exit code ($plain) and message with and without the deny rule"
  fi
}

fakeTemplate() {
  cat > "$work/fake-template.sh" <<'EOF'
#!/bin/sh
exec python3 -I -c '
import re, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
version, mode = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
text = open(args[args.index("-config") + 1]).read()
port = int(re.search(r"^\s*port:\s*(\d+)", text, re.M).group(1))
if mode == "dead":
    time.sleep(3600)
key = re.search(r"api-keys:\s*\n\s*-\s*\"([^\"]*)\"", text).group(1)
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        allowed = mode != "deaf" and self.headers.get("Authorization") == "Bearer " + key
        self.send_response(200 if allowed else 401)
        self.send_header("X-Fake-Version", version)
        self.send_header("Content-Length", "0")
        self.end_headers()
    def log_message(self, *rest):
        pass
HTTPServer(("127.0.0.1", port), Handler).serve_forever()
' "@VERSION@" "@MODE@" "$@"
EOF
}

publish() {
  local ver=$1 mode=$2 target=${3:-} asset stage sum
  [ -n "$target" ] || target="darwin_$(chipName)"
  asset="CLIProxyAPI_${ver}_${target}.tar.gz"
  stage="$work/stage-$ver"
  rm -rf "$stage"
  mkdir -p "$stage" "$srv/v$ver"
  sed -e "s/@VERSION@/$ver/" -e "s/@MODE@/$mode/" "$work/fake-template.sh" > "$stage/cli-proxy-api"
  chmod 755 "$stage/cli-proxy-api"
  COPYFILE_DISABLE=1 tar -czf "$srv/v$ver/$asset" -C "$stage" cli-proxy-api
  sum="$(checksumOf "$srv/v$ver/$asset")"
  if [ "$mode" = badsum ]; then
    sum="$(printf '%064d' 0)"
  fi
  printf '%s  %s\n%s  %s\n' "$sum" "$asset" "$(printf '%064d' 1)" "CLIProxyAPI_${ver}_windows_amd64.zip" > "$srv/v$ver/checksums.txt"
}

writeReleases() {
  local first=1 spec ver age draft pre when
  {
    echo '['
    for spec in "$@"; do
      IFS=: read -r ver age draft pre <<< "$spec"
      when="$(date -u -v-"${age}"d '+%Y-%m-%dT%H:%M:%SZ')"
      [ $first = 1 ] || echo ','
      first=0
      printf '{\n  "url": "https://api.github.com/repos/example/example/releases/1",\n  "id": 1,\n  "author": {\n    "login": "example",\n    "id": 2\n  },\n  "tag_name": "v%s",\n  "target_commitish": "main",\n  "name": "v%s",\n  "draft": %s,\n  "prerelease": %s,\n  "created_at": "%s",\n  "published_at": "%s",\n  "assets": [],\n  "body": ""\n}' "$ver" "$ver" "$draft" "$pre" "$when" "$when"
    done
    echo
    echo ']'
  } > "$srv/releases.json"
}

runHelper() {
  local action=$1
  shift
  env "RELAYBAR_RELEASES_URL=$base/releases.json" "RELAYBAR_DOWNLOAD_URL=$base" "RELAYBAR_BLOCKLIST_URL=$base/blocked.txt" \
    RELAYBAR_MIN_AGE_DAYS=3 RELAYBAR_MAJOR=8 "RELAYBAR_HEALTH_URL=http://127.0.0.1:$port/v1/models" RELAYBAR_HEALTH_SECONDS=6 \
    "RELAYBAR_RESTART_CMD=/bin/sh '$work/restart.sh' '$helper' '$work/fake.pid'" \
    "$@" /bin/sh "$helperScript" "$action" "$helper" > "$work/out" 2> "$work/err"
  rc=$?
  outText="$(cat "$work/out")"
  errText="$(cat "$work/err")"
}

runningVersion() {
  curl -s -D - -o /dev/null --max-time 3 "http://127.0.0.1:$port/v1/models" | tr -d '\r' | awk -F': ' 'tolower($1) == "x-fake-version" { print $2 }'
}

expectStatus() {
  local step=$1 want=$2 wantRc=$3 wantCurrent=$4
  if [ "$wantRc" = 0 ] && [ "$rc" != 0 ]; then
    fail "$step: exit $rc, expected 0 (stderr: $errText)"
  fi
  if [ "$wantRc" != 0 ] && [ "$rc" = 0 ]; then
    fail "$step: exit 0, expected a failure"
  fi
  [ "$outText" = "$want" ] || fail "$step: printed '$outText', expected '$want'"
  [ "$(readlink "$helper/current" 2> /dev/null)" = "versions/$wantCurrent" ] || fail "$step: current is '$(readlink "$helper/current" 2> /dev/null)', expected versions/$wantCurrent"
  [ "$(runningVersion)" = "$wantCurrent" ] || fail "$step: the running helper reports '$(runningVersion)', expected $wantCurrent"
}

expectDisk() {
  local step=$1 want=$2 got
  got=""
  for entry in "$helper/versions"/*; do
    got="${got:+$got }${entry##*/}"
  done
  [ "$got" = "$want" ] || fail "$step: versions on disk are '$got', expected '$want'"
}

expectErrorHas() {
  case "$errText" in
    *"$2"*) ;;
    *) fail "$1: stderr was '$errText', expected it to mention '$2'" ;;
  esac
}

updateRules() {
  newCase
  umask 077
  srv="$work/srv"
  helper="$work/home/Library/Application Support/Relaybar/Helper"
  mkdir -p "$srv" "$helper/auth"
  port="$(freePort)"
  local srvPort closedPort
  srvPort="$(freePort)"
  while [ "$srvPort" = "$port" ]; do srvPort="$(freePort)"; done
  closedPort="$(freePort)"
  base="http://127.0.0.1:$srvPort"
  local fixtureKey
  fixtureKey="$(randomHex)"
  cat > "$helper/config.yaml" <<EOF
config-version: 8
server:
  host: "127.0.0.1"
  port: $port
access:
  api-keys:
    - "$fixtureKey"
EOF
  cat > "$work/restart.sh" <<'EOF'
#!/bin/sh
helper=$1
pidfile=$2
if [ -f "$pidfile" ]; then
  pid=$(cat "$pidfile")
  kill "$pid" 2> /dev/null
  tries=0
  while kill -0 "$pid" 2> /dev/null && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
fi
cd "$helper" || exit 1
"$helper/current/cli-proxy-api" -config "$helper/config.yaml" > /dev/null 2>&1 < /dev/null &
echo $! > "$pidfile"
EOF
  fakeTemplate
  printf '# fixture block list\n\n8.0.63\n v8.0.99 # trailing comment\n' > "$srv/blocked.txt"
  publish 8.0.60 ok
  publish 8.0.61 ok
  publish 8.0.62 ok
  publish 8.0.63 ok
  publish 8.0.64 ok
  publish 8.0.65 ok
  publish 9.0.1 ok
  (cd "$work" && exec python3 -I -m http.server "$srvPort" --bind 127.0.0.1 --directory "$srv") > /dev/null 2>&1 < /dev/null &
  trackPid $!
  local i ready=0
  for ((i = 0; i < 20; i++)); do
    [ "$(httpCode "$base/blocked.txt")" = 200 ] && ready=1 && break
    sleep 0.5
  done
  [ $ready = 1 ] || fail "the fixture release server did not start"

  local unusable=(8.0.62:1:false:false 9.0.1:20:false:false 8.0.63:10:false:false 8.0.64:20:true:false 8.0.65:20:false:true)

  writeReleases "${unusable[@]}"
  runHelper install
  [ "$rc" != 0 ] || fail "install with only too-new, next-major, blocked, draft and pre-release versions exited 0"
  expectErrorHas "install with nothing allowed" "failed:"
  [ ! -e "$helper/current" ] || fail "install with nothing allowed left a current link"

  writeReleases 8.0.60:30:false:false "${unusable[@]}"
  runHelper install
  expectStatus "first install" "installed 8.0.60" 0 8.0.60
  [ "$(stat -f %Lp "$helper/versions/8.0.60/cli-proxy-api")" = 700 ] || fail "first install: the helper file is not mode 0700"
  [ "$(stat -f %Lp "$helper/versions/8.0.60")" = 700 ] || fail "first install: the version folder is not mode 0700"

  local pidBefore
  pidBefore="$(cat "$work/fake.pid")"
  runHelper update
  expectStatus "second run" "unchanged 8.0.60" 0 8.0.60
  [ "$(cat "$work/fake.pid")" = "$pidBefore" ] || fail "second run: a no-change update restarted the helper"

  publish 8.0.61 ok
  writeReleases 8.0.60:30:false:false 8.0.61:20:false:false "${unusable[@]}"
  runHelper update
  expectStatus "newer good release" "installed 8.0.61" 0 8.0.61
  expectDisk "newer good release" "8.0.60 8.0.61"

  publish 8.0.67 badsum
  writeReleases 8.0.60:30:false:false 8.0.61:20:false:false 8.0.67:20:false:false "${unusable[@]}"
  runHelper update
  expectStatus "bad checksum" "" 1 8.0.61
  expectErrorHas "bad checksum" "checksum"
  expectDisk "bad checksum" "8.0.60 8.0.61"

  publish 8.0.68 dead
  writeReleases 8.0.60:30:false:false 8.0.61:20:false:false 8.0.68:20:false:false "${unusable[@]}"
  runHelper update
  expectStatus "failing release" "rolled-back 8.0.61" 1 8.0.61
  expectErrorHas "failing release" "health check"
  expectDisk "failing release" "8.0.60 8.0.61"

  publish 8.0.66 deaf
  writeReleases 8.0.60:30:false:false 8.0.61:20:false:false 8.0.66:20:false:false "${unusable[@]}"
  runHelper update
  expectStatus "release that answers 401 to everyone" "rolled-back 8.0.61" 1 8.0.61
  expectErrorHas "release that answers 401 to everyone" "health check"
  expectDisk "release that answers 401 to everyone" "8.0.60 8.0.61"
  case "$outText$errText" in
    *"$fixtureKey"*) fail "the access key appeared in the update output" ;;
  esac

  publish 8.0.69 ok
  writeReleases 8.0.61:20:false:false 8.0.69:15:false:false "${unusable[@]}"
  runHelper update
  expectStatus "good release after a failure" "installed 8.0.69" 0 8.0.69
  expectDisk "good release after a failure" "8.0.61 8.0.69"

  publish 8.0.70 ok
  writeReleases 8.0.61:20:false:false 8.0.69:15:false:false 8.0.70:15:false:false "${unusable[@]}"
  runHelper update "RELAYBAR_BLOCKLIST_URL=http://127.0.0.1:$closedPort/blocked.txt"
  expectStatus "unreachable block list" "" 1 8.0.69
  expectErrorHas "unreachable block list" "block list"
  expectDisk "unreachable block list" "8.0.61 8.0.69"

  runHelper update "RELAYBAR_RELEASES_URL=http://127.0.0.1:$closedPort/releases.json"
  expectStatus "unreachable release list" "" 1 8.0.69
  expectDisk "unreachable release list" "8.0.61 8.0.69"

  mv "$srv/v8.0.70/checksums.txt" "$work/checksums-8.0.70.txt"
  runHelper update
  expectStatus "unreachable checksums" "" 1 8.0.69
  expectErrorHas "unreachable checksums" "checksums"
  expectDisk "unreachable checksums" "8.0.61 8.0.69"
  mv "$work/checksums-8.0.70.txt" "$srv/v8.0.70/checksums.txt"

  mkdir "$helper/.lock"
  echo $$ > "$helper/.lock/pid"
  runHelper update
  rm -rf "$helper/.lock"
  expectStatus "overlapping run" "" 1 8.0.69
  expectErrorHas "overlapping run" "in progress"

  printf '# fixture block list\n8.0.63\n8.0.69\n' > "$srv/blocked.txt"
  runHelper update
  expectStatus "installed version blocked" "rolled-back 8.0.61" 0 8.0.61
  expectDisk "installed version blocked" "8.0.61"

  runHelper update
  expectStatus "after the block" "installed 8.0.70" 0 8.0.70
  expectDisk "after the block" "8.0.61 8.0.70"

  pidBefore="$(cat "$work/fake.pid")"
  runHelper update
  expectStatus "final repeat" "unchanged 8.0.70" 0 8.0.70
  [ "$(cat "$work/fake.pid")" = "$pidBefore" ] || fail "final repeat: a no-change update restarted the helper"
  expectDisk "final repeat" "8.0.61 8.0.70"

  publish 8.0.71 ok linux_amd64_no-plugin
  writeReleases 8.0.61:20:false:false 8.0.69:15:false:false 8.0.70:15:false:false 8.0.71:15:false:false "${unusable[@]}"
  runHelper update RELAYBAR_SYSTEM=Linux RELAYBAR_MACHINE=x86_64
  expectStatus "linux amd64 asset" "installed 8.0.71" 0 8.0.71
  expectDisk "linux amd64 asset" "8.0.70 8.0.71"
  publish 8.0.72 ok linux_aarch64_no-plugin
  writeReleases 8.0.61:20:false:false 8.0.69:15:false:false 8.0.70:15:false:false 8.0.71:15:false:false 8.0.72:15:false:false "${unusable[@]}"
  runHelper update RELAYBAR_SYSTEM=Linux RELAYBAR_MACHINE=x86_64
  expectStatus "linux amd64 has no newer asset" "" 1 8.0.71
  expectErrorHas "linux amd64 has no newer asset" "CLIProxyAPI_8.0.72_linux_amd64_no-plugin"
  runHelper update RELAYBAR_SYSTEM=Linux RELAYBAR_MACHINE=aarch64
  expectStatus "linux aarch64 asset" "installed 8.0.72" 0 8.0.72
  expectDisk "linux aarch64 asset" "8.0.71 8.0.72"

  local left
  left="$(find "$helper" -maxdepth 1 \( -name '.lock' -o -name '.tmp.*' -o -name '.current.new' \))"
  [ -z "$left" ] || fail "leftover files in the helper folder: $left"
}

sshOpts=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)

boxSsh() {
  local port=$1
  shift
  ssh "${sshOpts[@]}" -i "$sshKey" -p "$port" homeuser@127.0.0.1 "$@"
}

remote() { boxSsh "$sshPort" "$@"; }

clientRemote() { boxSsh "$clientPort" "$@"; }

launchBox() {
  local name=$1 port=$2 i state
  docker rm -f "$name" > /dev/null 2>&1
  docker run -d --user root --name "$name" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --security-opt label=disable \
    -p "127.0.0.1:$port:22" "$imageTag" > /dev/null 2> "$root/docker-run.log" || {
    boxError="docker run failed: $(cat "$root/docker-run.log")"
    return 1
  }
  touch "$root/docker-started"
  for ((i = 0; i < 90; i++)); do
    state="$(docker exec "$name" systemctl is-system-running 2> /dev/null)"
    if [ "$state" = running ] || [ "$state" = degraded ]; then
      break
    fi
    sleep 1
  done
  if [ "$state" != running ] && [ "$state" != degraded ]; then
    boxError="systemd in the container did not finish starting (state: $state)"
    return 1
  fi
  docker exec -i "$name" sh -c 'cat > /home/homeuser/.ssh/authorized_keys && chown homeuser:homeuser /home/homeuser/.ssh/authorized_keys && chmod 600 /home/homeuser/.ssh/authorized_keys' < "$sshKey.pub" || {
    boxError="cannot install the test public key"
    return 1
  }
  for ((i = 0; i < 60; i++)); do
    boxSsh "$port" true > /dev/null 2>&1 && return 0
    sleep 1
  done
  boxError="ssh to the container did not come up"
  return 1
}

remoteSetup() {
  mkdir -p "$root/dockerctx"
  docker build -q -t "$imageTag" -f "$dockerfile" "$root/dockerctx" > "$root/docker-build.log" 2>&1 || {
    remoteError="docker build failed: $(cat "$root/docker-build.log")"
    return 1
  }
  sshPort="$(freePort)"
  sshKey="$root/id_e2e"
  ssh-keygen -q -t ed25519 -N '' -f "$sshKey" > /dev/null || {
    remoteError="ssh-keygen failed"
    return 1
  }
  launchBox "$containerName" "$sshPort" || {
    remoteError="$boxError"
    return 1
  }
}

remoteInstall() {
  newCase
  local when out rhome
  when="$(date -u -v-20d '+%Y-%m-%dT%H:%M:%SZ')"
  [ -n "${remoteError:-}" ] && fail "$remoteError"
  printf '[\n{\n  "tag_name": "v%s",\n  "name": "v%s",\n  "draft": false,\n  "prerelease": false,\n  "created_at": "%s",\n  "published_at": "%s",\n  "assets": [],\n  "body": ""\n}\n]\n' \
    "$releaseVersion" "$releaseVersion" "$when" "$when" > "$work/releases.json"
  printf '# fixture block list\n' > "$work/blocked.txt"
  rhome="$(remote pwd)" || fail "cannot read the home folder of the container user"
  remote "umask 077; mkdir -p '$rhome/e2e' '$rhome/.local/share/relaybar' && cat > '$rhome/e2e/releases.json'" < "$work/releases.json" || fail "cannot copy the release list"
  remote "umask 077; cat > '$rhome/e2e/blocked.txt'" < "$work/blocked.txt" || fail "cannot copy the block list"
  remote "umask 077; cat > '$rhome/.local/share/relaybar/relaybar-helper.sh' && chmod 700 '$rhome/.local/share/relaybar/relaybar-helper.sh'" < "$helperScript" || fail "cannot copy the update script"
  cat > "$work/setup.sh" <<'EOF'
set -eu
umask 077
D="$HOME/.local/share/relaybar-helper"
S="$HOME/.local/share/relaybar/relaybar-helper.sh"
mkdir -p "$D/auth" "$HOME/.config/systemd/user"
K=$(head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')
M=$(head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')
cat > "$D/config.yaml" <<CFG
config-version: 8
server:
  host: "127.0.0.1"
  port: 8317
management:
  allow-remote: false
  secret-key: "$M"
  disable-control-panel: true
access:
  api-keys:
    - "$K"
routing:
  strategy: "round-robin"
  session-affinity: true
  session-affinity-ttl: "1h"
  session-affinity-subagents: true
  session-affinity-rebind-on: "quota"
  retry:
    request-retry: 3
    max-retry-interval: 30
oauth:
  auth-dir: "$D/auth"
observability:
  logs:
    logging-to-file: false
    request-log: false
  usage:
    usage-statistics-enabled: false
plugins:
  enabled: false
CFG
unset K M
cat > "$HOME/.config/systemd/user/relaybar-helper.service" <<UNIT
[Unit]
Description=Relaybar helper

[Service]
WorkingDirectory=$D
ExecStart=$D/current/cli-proxy-api -config $D/config.yaml
Restart=always
RestartSec=5
StandardOutput=null
StandardError=null
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=tmpfs
BindPaths=$D
InaccessiblePaths=/run/user
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes

[Install]
WantedBy=default.target
UNIT
cat > "$HOME/.config/systemd/user/relaybar-helper-update.service" <<UNIT
[Unit]
Description=Relaybar helper update

[Service]
Type=oneshot
ExecStart=/bin/sh $S update $D
UNIT
cat > "$HOME/.config/systemd/user/relaybar-helper-update.timer" <<UNIT
[Unit]
Description=Relaybar helper nightly update

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
UNIT
EOF
  remote sh -s < "$work/setup.sh" > "$work/setup.out" 2>&1 || fail "remote setup failed: $(cat "$work/setup.out")"
  remote 'loginctl enable-linger homeuser' > /dev/null 2>&1 || docker exec "$containerName" loginctl enable-linger homeuser || fail "cannot turn on lingering"
  [ "$(remote 'loginctl show-user homeuser -p Linger --value')" = yes ] || fail "lingering is not on"
  remote 'systemctl --user daemon-reload && systemctl --user enable --now relaybar-helper-update.timer' > "$work/timer.out" 2>&1 || fail "cannot enable the update timer: $(cat "$work/timer.out")"
  local env="RELAYBAR_RELEASES_URL='file://$rhome/e2e/releases.json' RELAYBAR_BLOCKLIST_URL='file://$rhome/e2e/blocked.txt'"
  local run="/bin/sh '$rhome/.local/share/relaybar/relaybar-helper.sh'"
  local dir="'$rhome/.local/share/relaybar-helper'"
  out="$(remote "$env $run install $dir" 2> "$work/install.err")" || fail "install failed: $out $(cat "$work/install.err")"
  [ "$out" = "installed $releaseVersion" ] || fail "install printed '$out', expected 'installed $releaseVersion'"
  out="$(remote "$env $run install $dir" 2> "$work/install.err")" || fail "second install failed: $out $(cat "$work/install.err")"
  [ "$out" = "unchanged $releaseVersion" ] || fail "second install printed '$out', expected 'unchanged $releaseVersion'"
  [ "$(remote 'systemctl --user is-active relaybar-helper.service')" = active ] || fail "the helper service is not active"
  [ "$(remote "readlink '$rhome/.local/share/relaybar-helper/current'")" = "versions/$releaseVersion" ] || fail "current does not point at versions/$releaseVersion"
  local codes
  cat > "$work/query.sh" <<'EOF'
set -eu
umask 077
D="$HOME/.local/share/relaybar-helper"
H=$(mktemp)
trap 'rm -f "$H"' EXIT
K=$(sed -n '/api-keys:/{n;s/^ *- *"\(.*\)"$/\1/p;}' "$D/config.yaml")
printf 'Authorization: Bearer %s\n' "$K" > "$H"
unset K
plain=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8317/v1/models)
keyed=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "@$H" http://127.0.0.1:8317/v1/models)
echo "$plain $keyed"
EOF
  codes="$(remote sh -s < "$work/query.sh")" || fail "cannot query the helper inside the container"
  [ "$codes" = "401 200" ] || fail "models answered '$codes' (without key, with key), expected '401 200'"
  remote "echo sample > '$rhome/probe-secret'" || fail "cannot write the home canary"
  local pid
  pid="$(remote 'systemctl --user show -p MainPID --value relaybar-helper.service')"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail "no main process for the helper service ('$pid')"
  if docker exec "$containerName" nsenter -t "$pid" -m cat /home/homeuser/probe-secret > /dev/null 2>&1; then
    fail "the service can read a file in the home folder"
  fi
  docker exec "$containerName" nsenter -t "$pid" -m cat /home/homeuser/.local/share/relaybar-helper/config.yaml > /dev/null 2>&1 || fail "the service cannot read its own folder"
  docker exec "$containerName" nsenter -t "$pid" -m touch /home/homeuser/.local/share/relaybar-helper/auth/probe-write > /dev/null 2>&1 || fail "the service cannot write its own folder"
  cat > "$work/probe.sh" <<'EOF'
set -eu
D="$HOME/.local/share/relaybar-helper"
U="$HOME/.config/systemd/user"
make() {
  name=$1
  shift
  sed -n '1,/^\[Install\]/p' "$U/relaybar-helper.service" | sed -e '/^\[Install\]/d' -e '/^ExecStart=/d' -e '/^Restart/d' "$@" > "$U/$name.service"
  printf 'Type=oneshot\nExecStart=/bin/sh -c '"'"'systemd-run --user --collect --wait true > /dev/null 2>&1; echo $$? > "%s/%s.rc"'"'"'\n' "$D" "$name" >> "$U/$name.service"
}
make probe-open -e '/^ProtectHome=/d' -e '/^InaccessiblePaths=/d' -e '/^RestrictAddressFamilies=/d'
make probe-locked
systemctl --user daemon-reload
systemctl --user start probe-open.service
systemctl --user start probe-locked.service
echo "open=$(cat "$D/probe-open.rc") locked=$(cat "$D/probe-locked.rc")"
rm -f "$D/probe-open.rc" "$D/probe-locked.rc" "$U/probe-open.service" "$U/probe-locked.service"
systemctl --user daemon-reload
EOF
  local probe
  probe="$(remote sh -s < "$work/probe.sh" 2>&1)" || fail "cannot run the unit probe: $probe"
  case "$probe" in
    "open=0 locked="[1-9]*) echo "  systemd-run --user works from a copy of the unit without ProtectHome, InaccessiblePaths and RestrictAddressFamilies, and is refused with them ($probe)" ;;
    *) fail "the unit does not stop the helper from starting user services ($probe), expected 'open=0 locked=<not 0>'" ;;
  esac
  remote 'systemctl --user show relaybar-helper.service -p InaccessiblePaths -p RestrictAddressFamilies' > "$work/props.out" 2>&1 || fail "cannot read the unit properties"
  grep -q 'InaccessiblePaths=.*/run/user' "$work/props.out" || fail "the loaded unit lacks InaccessiblePaths=/run/user"
  grep -q 'RestrictAddressFamilies=.*AF_INET6' "$work/props.out" || fail "the loaded unit lacks RestrictAddressFamilies"
  remote 'systemctl --user list-timers --all' 2> /dev/null | grep -q 'relaybar-helper-update.timer' || fail "the update timer is not listed"
  [ "$(remote 'systemctl --user is-enabled relaybar-helper-update.timer')" = enabled ] || fail "the update timer is not enabled"
  [ "$(remote 'systemctl --user is-enabled relaybar-helper.service')" = enabled ] || fail "the helper service is not enabled"
  remote 'systemd-analyze --user verify relaybar-helper.service relaybar-helper-update.service relaybar-helper-update.timer' > "$work/verify.out" 2>&1 || fail "systemd rejects the units: $(cat "$work/verify.out")"
  remote 'systemd-analyze calendar "*-*-* 04:00:00"' > /dev/null 2>&1 || fail "systemd rejects the update schedule"
}

remoteStop() {
  newCase
  local rhome left
  [ -n "${remoteError:-}" ] && fail "$remoteError"
  rhome="$(remote pwd)" || fail "cannot read the home folder of the container user"
  sed -n '/static let remoteRemoval =/,/; true"$/p' "$repo/Sources/RelaybarCore/PoolTeardown.swift" |
    sed -e '1s/^.*remoteRemoval =//' -e 's/^[[:space:]]*+*[[:space:]]*"//' -e 's/"$//' -e 's/\\"/"/g' | tr -d '\n' > "$work/teardown.sh"
  grep -q 'disable --now' "$work/teardown.sh" || fail "cannot read the removal script from PoolTeardown.swift"
  remote sh -s < "$work/teardown.sh" > "$work/teardown.out" 2>&1 || fail "the removal script failed: $(cat "$work/teardown.out")"
  left="$(remote 'grep -lx cli-proxy-api /proc/[0-9]*/comm 2> /dev/null; true')"
  [ -z "$left" ] || fail "the helper is still running after the removal script ($left)"
  [ "$(remote 'curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8317/v1/models; true')" = 000 ] || fail "port 8317 still answers after the removal script"
  [ "$(remote 'systemctl --user is-active relaybar-helper.service; true')" != active ] || fail "the helper service is still active after the removal script"
  remote "[ ! -e '$rhome/.local/share/relaybar-helper' ] && [ ! -e '$rhome/.config/systemd/user/relaybar-helper.service' ]" || fail "the removal script left the helper files behind"
  echo "  removal script stopped the helper, closed port 8317 and removed its files"
}

swiftStep() {
  local step=$1 name=$2
  (
    cd "$repo" || exit 1
    env RELAYBAR_E2E_STEP="$step" RELAYBAR_E2E_SSH_CONFIG="$work/ssh_config" RELAYBAR_E2E_CLIENT_FILE="$work/client.json" \
      RELAYBAR_E2E_ACCESS_KEY_FILE="$work/access-key" \
      perl -e 'alarm shift; exec @ARGV or exit 127' 900 swift test --skip-build --filter "$name"
  ) > "$work/swift-$step.log" 2>&1 || fail "the $step step failed: $(cat "$work/swift-$step.log")"
  grep -q "Test $name() passed" "$work/swift-$step.log" || fail "the $step test did not run: $(cat "$work/swift-$step.log")"
}

clientConnects() {
  newCase
  umask 077
  local hubIp keysBefore out
  [ -n "${remoteError:-}" ] && fail "$remoteError"
  clientPort="$(freePort)"
  launchBox "$clientName" "$clientPort" || fail "$boxError"
  docker exec "$clientName" loginctl enable-linger homeuser || fail "cannot turn on lingering on the client"
  hubIp="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$containerName")"
  [ -n "$hubIp" ] || fail "cannot read the address of the hub container"
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
  cat > "$work/read-keys.sh" <<'EOF'
sed -n '/api-keys:/{n;s/^ *- *"\(.*\)"$/\1/p;}' "$HOME/.local/share/relaybar-helper/config.yaml"
EOF
  remote sh -s < "$work/read-keys.sh" > "$work/access-key" || fail "cannot read the access key from the hub"
  [ -s "$work/access-key" ] || fail "the hub has no access key"
  cat > "$work/read-secret.sh" <<'EOF'
sed -n 's/^ *secret-key: *"\(.*\)"$/\1/p' "$HOME/.local/share/relaybar-helper/config.yaml"
EOF
  remote sh -s < "$work/read-secret.sh" > "$work/mgmt-secret" || fail "cannot read the management secret from the hub"
  [ -s "$work/mgmt-secret" ] || fail "the hub has no management secret"
  keysBefore="$(remote "cat $homeDir/.ssh/authorized_keys")"
  printf '%s' '{"defaultModelSelection": {"instanceId": "claudeAgent", "model": "m"}, "providerInstances": {}}' > "$work/settings-before.json"
  clientRemote "umask 077; mkdir -p $homeDir/.t3/userdata && cat > $homeDir/.t3/userdata/settings.json" < "$work/settings-before.json" || fail "cannot write the T3 Code fixture on the client"
  (cd "$repo" && perl -e 'alarm shift; exec @ARGV or exit 127' 1800 swift build --build-tests) > "$work/swift-build.log" 2>&1 || fail "swift build failed: $(cat "$work/swift-build.log")"

  swiftStep add e2eAddsTheClient

  cat > "$work/probe-hub.sh" <<EOF
k="\$HOME/.config/relaybar/hub_key"
ssh -i "\$k" -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile="\$HOME/.config/relaybar/known_hosts" -o StrictHostKeyChecking=yes -o ConnectTimeout=5 homeuser@$hubIp id 2> /dev/null < /dev/null
echo "rc=\$?"
ssh -i "\$k" -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile="\$HOME/.config/relaybar/known_hosts" -o StrictHostKeyChecking=yes -o ConnectTimeout=5 -W 127.0.0.1:22 homeuser@$hubIp 2> /dev/null < /dev/null | head -c 20
true
EOF
  out="$(clientRemote sh -s < "$work/probe-hub.sh")" || fail "cannot run the key checks on the client"
  [ "$out" = "rc=1" ] || fail "the client key was not refused a command and another port on the hub (got '$out')"
  cat > "$work/query.sh" <<'EOF'
umask 077
H=$(mktemp)
trap 'rm -f "$H"' EXIT
printf 'Authorization: Bearer %s\n' "$(cat "$HOME/.config/relaybar/access-key")" > "$H"
plain=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8317/v1/models)
keyed=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "@$H" http://127.0.0.1:8317/v1/models)
echo "$plain $keyed"
EOF
  out="$(clientRemote sh -s < "$work/query.sh")" || fail "cannot query the helper from the client"
  [ "$out" = "401 200" ] || fail "through the client tunnel models answered '$out' (without key, with key), expected '401 200'"
  [ "$(remote "grep -c ' relaybar-client:e2e-client\$' $homeDir/.ssh/authorized_keys")" = 1 ] || fail "the hub does not hold exactly one tagged key line"
  remote "grep ' relaybar-client:e2e-client\$' $homeDir/.ssh/authorized_keys" | grep -q '^restrict,port-forwarding,permitopen="127.0.0.1:8317",command="/bin/false" ssh-ed25519 ' || fail "the tagged key line does not carry the helper-port-only options"
  [ "$(remote "cat $homeDir/.ssh/authorized_keys.relaybar-backup")" = "$keysBefore" ] || fail "the authorized_keys backup is not the file as it was"
  clientRemote "cat $homeDir/.t3/userdata/settings.json" > "$work/settings-after.json" || fail "cannot read the T3 Code settings on the client"
  python3 -I -c '
import json, sys
data = json.load(open(sys.argv[1]))
ids = sorted(data.get("providerInstances", {}))
if ids != ["claudeAgent_all_accounts", "codex_all_accounts"]:
    sys.exit("entries: %s" % ids)
if data["defaultModelSelection"]["instanceId"] != "claudeAgent_all_accounts":
    sys.exit("default not switched")
if "usageLimitSources" in data:
    sys.exit("usage source added on the client")
' "$work/settings-after.json" || fail "the client T3 Code settings are wrong"
  out="$(clientRemote "stat -c %a $homeDir/.t3/userdata/secrets; for f in $homeDir/.t3/userdata/secrets/*.bin; do stat -c %a \"\$f\"; done")"
  [ "$out" = "$(printf '700\n600')" ] || fail "the T3 Code secret folder or file has the wrong mode ($out)"
  [ -z "$(clientRemote "grep -rlF -f /dev/stdin $homeDir 2> /dev/null; true" < "$work/mgmt-secret")" ] || fail "the management secret is on the client"
  [ "$(clientRemote "stat -c %a $homeDir/.config/relaybar/hub_key")" = 600 ] || fail "the client key is not mode 0600"

  swiftStep remove e2eRemovesTheClient

  out="$(clientRemote "find $homeDir -iname '*relaybar*' -not -name '*.relaybar-backup' 2> /dev/null; ls -A $homeDir/.claude-hub $homeDir/.codex-hub $homeDir/.local/bin/claude-all $homeDir/.local/bin/codex-all $homeDir/.t3/userdata/secrets 2> /dev/null; systemctl --user is-active relaybar-tunnel.service; true")"
  [ "$out" = "inactive" ] || [ "$out" = "unknown" ] || fail "the client still has Relaybar files or an active tunnel: $out"
  clientRemote "cat $homeDir/.t3/userdata/settings.json" > "$work/settings-restored.json"
  python3 -I -c '
import json, sys
sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)
' "$work/settings-restored.json" "$work/settings-before.json" || fail "the client T3 Code settings were not put back"
  [ "$(clientRemote 'curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8317/v1/models; true')" = 000 ] || fail "port 8317 still answers on the client"
  [ "$(remote "cat $homeDir/.ssh/authorized_keys")" = "$keysBefore" ] || fail "the hub authorized_keys is not as it was before the computer was added"
  echo "  the client key was refused a command and another port, the client tunnel answered 401 then 200, T3 Code got both entries and no usage source, and removal left no trace"
}

tunnelLoop() {
  while :; do
    ssh -N -L "127.0.0.1:$1:127.0.0.1:8317" -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$sshKey" -p "$sshPort" homeuser@127.0.0.1
    sleep 1
  done
}

tunnelComesBack() {
  newCase
  [ -n "${remoteError:-}" ] && fail "$remoteError"
  local url first second i
  lport="$(freePort)"
  url="http://127.0.0.1:$lport/v1/models"
  trap 'stopTracked "$work"; pkill -f "127.0.0.1:$lport:127.0.0.1:8317" 2> /dev/null' EXIT
  tunnelLoop "$lport" > /dev/null 2>&1 < /dev/null &
  trackPid $!
  waitFor401 "$url" 20 || fail "no answer through the tunnel within 20 s"
  first="$(pgrep -f "^ssh -N -L 127.0.0.1:$lport:" | head -n 1)"
  [ -n "$first" ] || fail "cannot find the tunnel process"
  kill "$first"
  for ((i = 0; i < 20; i++)); do
    second="$(pgrep -f "^ssh -N -L 127.0.0.1:$lport:" | head -n 1)"
    if [ -n "$second" ] && [ "$second" != "$first" ] && [ "$(httpCode "$url")" = 401 ]; then
      echo "  tunnel back after $i s"
      return 0
    fi
    sleep 1
  done
  fail "the tunnel did not come back within 20 s after it was killed"
}

if [ $wantLocal = 1 ]; then
  runCase modelsNeedTheKey
  runCase picksUpANewLogin
  runCase prioritySticks
  runCase sandboxBlocksHomeFiles
fi
if [ $wantUpdate = 1 ]; then
  runCase updateRules
fi
if [ $wantRemote = 1 ]; then
  remoteError=""
  if ! docker version > /dev/null 2>&1; then
    remoteError="docker is not available"
  else
    remoteSetup || true
  fi
  runCase remoteInstall
  runCase tunnelComesBack
  runCase clientConnects
  runCase remoteStop
fi

if [ $failures -ne 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
