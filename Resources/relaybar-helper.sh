#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: relaybar-helper.sh install|update <helper dir>

Installs or updates the CLIProxyAPI helper in <helper dir> (an absolute path).
Prints one status line: installed <v>, unchanged <v> or rolled-back <v>.
On failure prints "failed: <reason>" to stderr and exits non-zero.

Environment (all optional):
  RELAYBAR_MAJOR           supported major version (default 8)
  RELAYBAR_MIN_AGE_DAYS    minimum release age in days (default 3)
  RELAYBAR_RELEASES_URL    releases list (JSON)
  RELAYBAR_DOWNLOAD_URL    base URL of the release downloads
  RELAYBAR_BLOCKLIST_URL   block list (one version per line, # comments)
Test hooks:
  RELAYBAR_RESTART_CMD     run with sh -c instead of the platform restart
  RELAYBAR_HEALTH_URL      health check URL (default http://127.0.0.1:8317/v1/models)
  RELAYBAR_HEALTH_SECONDS  health check time limit (default 20)
  RELAYBAR_NOW             override "now" as YYYY-MM-DDTHH:MM:SSZ for the age rule
  RELAYBAR_SYSTEM          override uname -s when choosing the download (Darwin or Linux)
  RELAYBAR_MACHINE         override uname -m when choosing the download
EOF
}

fail() {
  printf 'failed: %s\n' "$1" >&2
  exit 1
}

mode="${1:-}"
dir="${2:-}"
case "$mode" in
  install | update) ;;
  *)
    usage >&2
    exit 2
    ;;
esac
case "$dir" in
  /*) ;;
  *) fail "helper dir must be an absolute path" ;;
esac

major="${RELAYBAR_MAJOR:-8}"
min_age="${RELAYBAR_MIN_AGE_DAYS:-3}"
releases_url="${RELAYBAR_RELEASES_URL:-https://api.github.com/repos/router-for-me/CLIProxyAPI/releases?per_page=30}"
download_url="${RELAYBAR_DOWNLOAD_URL:-https://github.com/router-for-me/CLIProxyAPI/releases/download}"
blocklist_url="${RELAYBAR_BLOCKLIST_URL:-https://raw.githubusercontent.com/sgaabdu4/relaybar/main/pool/blocked-versions.txt}"
health_url="${RELAYBAR_HEALTH_URL:-http://127.0.0.1:8317/v1/models}"
health_seconds="${RELAYBAR_HEALTH_SECONDS:-20}"

case "$major$min_age$health_seconds" in
  *[!0-9]* | "") fail "RELAYBAR_MAJOR, RELAYBAR_MIN_AGE_DAYS and RELAYBAR_HEALTH_SECONDS must be whole numbers" ;;
esac

umask 077
mkdir -p "$dir" "$dir/versions" || fail "cannot create $dir"

lock="$dir/.lock"
tmp=""
have_lock=0

trap 'if [ -n "$tmp" ]; then rm -rf "$tmp"; fi; if [ "$have_lock" = 1 ]; then rm -rf "$lock"; fi' EXIT
trap 'exit 1' HUP INT TERM

if ! mkdir "$lock" 2> /dev/null; then
  holder="$(cat "$lock/pid" 2> /dev/null || true)"
  if [ -n "$holder" ] && ! kill -0 "$holder" 2> /dev/null; then
    rm -rf "$lock"
    mkdir "$lock" 2> /dev/null || fail "another run is in progress"
  else
    fail "another run is in progress"
  fi
fi
have_lock=1
echo "$$" > "$lock/pid"

tmp="$(mktemp -d "$dir/.tmp.XXXXXX")" || fail "cannot create a temporary folder"

version_pattern='^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$'

valid_version() {
  printf '%s\n' "$1" | grep -Eq "$version_pattern"
}

fetch() {
  curl -fsSL --proto-redir '=https' --max-time "$3" -H 'Accept: application/vnd.github+json' -o "$2" "$1"
}

sort_versions() {
  sort -t. -k1,1n -k2,2n -k3,3n
}

newer_than() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort_versions | sed -n '$p')" = "$1" ]
}

is_blocked() {
  grep -qxF -- "$1" "$tmp/blocked.txt"
}

cutoff_time() {
  fmt='+%Y-%m-%dT%H:%M:%SZ'
  if date -u -v-1d +%s > /dev/null 2>&1; then
    if [ -n "${RELAYBAR_NOW:-}" ]; then
      date -u -j -v-"${min_age}"d -f '%Y-%m-%dT%H:%M:%SZ' "$RELAYBAR_NOW" "$fmt"
    else
      date -u -v-"${min_age}"d "$fmt"
    fi
  else
    date -u -d "${RELAYBAR_NOW:-now} - ${min_age} days" "$fmt"
  fi
}

installed_version() {
  link="$(readlink "$dir/current" 2> /dev/null || true)"
  found="${link#versions/}"
  if valid_version "$found" && [ -x "$dir/versions/$found/cli-proxy-api" ]; then
    printf '%s\n' "$found"
  fi
}

kept_versions() {
  for entry in "$dir"/versions/*; do
    [ -d "$entry" ] || continue
    name="${entry##*/}"
    if valid_version "$name" && [ -x "$entry/cli-proxy-api" ]; then
      printf '%s\n' "$name"
    fi
  done
}

swap_current() {
  ln -s "versions/$1" "$dir/.current.new" || return 1
  if [ "$(uname -s)" = Darwin ]; then
    mv -h -f "$dir/.current.new" "$dir/current"
  else
    mv -T -f "$dir/.current.new" "$dir/current"
  fi
}

restart_helper() {
  if [ -n "${RELAYBAR_RESTART_CMD:-}" ]; then
    sh -c "$RELAYBAR_RESTART_CMD"
    return
  fi
  case "$(uname -s)" in
    Darwin)
      domain="gui/$(id -u)"
      if ! launchctl print "$domain/com.relaybar.helper" > /dev/null 2>&1; then
        launchctl bootstrap "$domain" "$HOME/Library/LaunchAgents/com.relaybar.helper.plist"
      fi
      launchctl kickstart -k "$domain/com.relaybar.helper"
      ;;
    Linux)
      if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
        XDG_RUNTIME_DIR="/run/user/$(id -u)"
        export XDG_RUNTIME_DIR
      fi
      systemctl --user daemon-reload
      systemctl --user enable relaybar-helper.service
      systemctl --user restart relaybar-helper.service
      ;;
    *) return 1 ;;
  esac
}

access_key() {
  awk '
    /^[[:space:]]*api-keys:/ { found = 1; next }
    found && /^[[:space:]]*-/ {
      sub(/^[[:space:]]*-[[:space:]]*/, "")
      gsub(/["'\'']/, "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
    found && /^[^[:space:]-]/ { exit }
  ' "$dir/config.yaml" 2> /dev/null
}

healthy() {
  key="$(access_key)"
  [ -n "$key" ] || return 1
  start="$(date +%s)"
  while :; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$health_url" 2> /dev/null || true)"
    if [ "$code" = 401 ]; then
      code="$(printf 'Authorization: Bearer %s\n' "$key" | curl -s -o /dev/null -w '%{http_code}' --max-time 2 -H @- "$health_url" 2> /dev/null || true)"
      if [ "$code" = 200 ]; then
        return 0
      fi
    fi
    if [ "$(($(date +%s) - start))" -ge "$health_seconds" ]; then
      return 1
    fi
    sleep 1
  done
}

prune() {
  for name in $(kept_versions); do
    if [ "$name" != "$1" ] && [ "$name" != "$2" ]; then
      rm -rf "${dir:?}/versions/$name"
    fi
  done
}

system="${RELAYBAR_SYSTEM:-$(uname -s)}"
machine="${RELAYBAR_MACHINE:-$(uname -m)}"
case "$system" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) fail "unsupported system $system" ;;
esac
case "$machine" in
  arm64 | aarch64) chip=aarch64 ;;
  x86_64 | amd64) chip=amd64 ;;
  *) fail "unsupported chip $machine" ;;
esac

fetch "$blocklist_url" "$tmp/blocklist.raw" 30 || fail "cannot read the block list"
sed -e 's/#.*//' -e 's/[[:space:]]//g' -e 's/^v//' "$tmp/blocklist.raw" | grep -v '^$' > "$tmp/blocked.txt" || true

fetch "$releases_url" "$tmp/releases.json" 60 || fail "cannot read the release list"

cutoff="$(cutoff_time)" || fail "cannot work out the age cutoff"

tr ',' '\n' < "$tmp/releases.json" \
  | sed -n \
    -e 's/^[][{[:space:]]*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/T \1/p' \
    -e 's/^[][{[:space:]]*"draft"[[:space:]]*:[[:space:]]*\([a-z]*\).*/D \1/p' \
    -e 's/^[][{[:space:]]*"prerelease"[[:space:]]*:[[:space:]]*\([a-z]*\).*/P \1/p' \
    -e 's/^[][{[:space:]]*"published_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/A \1/p' \
  | awk -v cutoff="$cutoff" '
      function flush() {
        if (tag != "" && draft == "false" && pre == "false" && at != "" && !((at "") > (cutoff ""))) print tag
      }
      $1 == "T" { flush(); tag = $2; draft = ""; pre = ""; at = "" }
      $1 == "D" { draft = $2 }
      $1 == "P" { pre = $2 }
      $1 == "A" { at = $2 }
      END { flush() }
    ' > "$tmp/published.txt"

: > "$tmp/allowed.txt"
while read -r tag; do
  found="${tag#v}"
  valid_version "$found" || continue
  [ "${found%%.*}" = "$major" ] || continue
  is_blocked "$found" && continue
  printf '%s\n' "$found" >> "$tmp/allowed.txt"
done < "$tmp/published.txt"
best="$(sort_versions < "$tmp/allowed.txt" | sed -n '$p')"

current="$(installed_version)"
target=""
previous=""
outcome="installed"

if [ -n "$current" ] && is_blocked "$current"; then
  for name in $(kept_versions | sort_versions); do
    if [ "$name" != "$current" ] && ! is_blocked "$name"; then
      target="$name"
    fi
  done
  outcome="rolled-back"
  if [ -z "$target" ]; then
    target="$best"
    outcome="installed"
  fi
  [ -n "$target" ] || fail "the installed version $current is blocked and no allowed version is available"
elif [ -n "$current" ]; then
  if [ -n "$best" ] && newer_than "$best" "$current"; then
    target="$best"
    previous="$current"
  else
    echo "unchanged $current"
    exit 0
  fi
else
  target="$best"
  [ -n "$target" ] || fail "no release in major $major is old enough and not blocked"
fi

if [ ! -x "$dir/versions/$target/cli-proxy-api" ]; then
  if [ "$os" = linux ]; then
    asset="CLIProxyAPI_${target}_linux_${chip}_no-plugin.tar.gz"
  else
    asset="CLIProxyAPI_${target}_darwin_${chip}.tar.gz"
  fi
  fetch "$download_url/v$target/checksums.txt" "$tmp/checksums.txt" 30 || fail "cannot read the checksums for $target"
  fetch "$download_url/v$target/$asset" "$tmp/$asset" 600 || fail "cannot download $asset"
  expected="$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1 }' "$tmp/checksums.txt")"
  [ -n "$expected" ] || fail "no checksum listed for $asset"
  if command -v sha256sum > /dev/null 2>&1; then
    actual="$(sha256sum "$tmp/$asset" | awk '{ print $1 }')"
  else
    actual="$(shasum -a 256 "$tmp/$asset" | awk '{ print $1 }')"
  fi
  [ "$actual" = "$expected" ] || fail "checksum mismatch for $asset"
  mkdir "$tmp/x"
  tar -xzf "$tmp/$asset" -C "$tmp/x" cli-proxy-api || fail "cannot unpack $asset"
  [ -f "$tmp/x/cli-proxy-api" ] || fail "$asset has no cli-proxy-api"
  chmod 700 "$tmp/x/cli-proxy-api"
  rm -rf "${dir:?}/versions/$target"
  mkdir -m 700 "$dir/versions/$target"
  mv "$tmp/x/cli-proxy-api" "$dir/versions/$target/cli-proxy-api"
fi

swap_current "$target" || fail "cannot switch to $target"
if restart_helper && healthy; then
  prune "$target" "$previous"
  echo "$outcome $target"
  exit 0
fi

if [ "$outcome" = rolled-back ]; then
  fail "the helper did not answer after going back to $target"
fi

rm -rf "${dir:?}/versions/$target"
if [ -n "$previous" ]; then
  swap_current "$previous"
  restart_helper && healthy || true
  echo "rolled-back $previous"
  fail "version $target did not pass the health check"
fi
rm -f "$dir/current"
fail "version $target did not pass the health check"
