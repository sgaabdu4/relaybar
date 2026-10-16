#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
budget="${RELAYBAR_MEMORY_BUDGET_MB:-30}"
idle_cpu="${RELAYBAR_IDLE_CPU_SECONDS:-0.1}"
binary=build/Relaybar.app/Contents/MacOS/Relaybar
[ -x "$binary" ] || { echo "Build the app first: ./build.sh"; exit 1; }
home="$(mktemp -d)"
trap 'kill "$pid" 2> /dev/null || true; rm -rf "$home"' EXIT
mkdir -p "$home/.claude-demo" "$home/.codex-demo"
echo '{"oauthAccount": {"emailAddress": "demo@example.com", "organizationName": "Demo Studio"}}' > "$home/.claude-demo/.claude.json"
echo '{"tokens": {}}' > "$home/.codex-demo/auth.json"
CFFIXED_USER_HOME="$home" "$binary" &
pid=$!
sleep 8
if ! kill -0 "$pid" 2> /dev/null; then
  echo "Relaybar quit during start-up."
  exit 1
fi
megabytes="$(footprint -p "$pid" | sed -n 's/.*Footprint: \([0-9.]*\) MB.*/\1/p' | head -n 1)"
echo "Relaybar footprint: ${megabytes} MB (budget ${budget} MB)"
if [ -z "$megabytes" ] || [ "$(echo "$megabytes > $budget" | bc)" -eq 1 ]; then
  echo "Memory is over budget or could not be read."
  exit 1
fi
cpu_seconds() { ps -o time= -p "$pid" | awk -F: '{ print $1 * 60 + $2 }'; }
before="$(cpu_seconds)"
sleep 10
used="$(echo "$(cpu_seconds) - $before" | bc)"
echo "Idle CPU over 10 s: ${used} s (budget ${idle_cpu} s)"
if [ "$(echo "$used > $idle_cpu" | bc)" -eq 1 ]; then
  echo "Relaybar uses too much CPU while idle."
  exit 1
fi
