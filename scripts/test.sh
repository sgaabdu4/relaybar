#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
minimum="${RELAYBAR_COVERAGE_MIN:-85}"
mkdir -p coverage
swift test --enable-code-coverage --xunit-output coverage/junit.xml
report="$(swift test --show-codecov-path)"
percent="$(jq '[.data[0].files[] | select(.filename | contains("/Sources/RelaybarCore/")) | .summary.lines]
  | ((map(.covered) | add) * 100 / (map(.count) | add) | floor)' "$report")"
echo "RelaybarCore line coverage: ${percent}% (minimum ${minimum}%)"
if [ "$percent" -lt "$minimum" ]; then
  echo "Coverage is below the minimum."
  exit 1
fi
