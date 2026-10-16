#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app=build/Relaybar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/"
cp Resources/*.svg Resources/LOGOS-LICENSE.txt "$app/Contents/Resources/"
iconset=build/AppIcon.iconset
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" > /dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
swiftc -Osize -wmo -swift-version 5 -target arm64-apple-macos14.0 Sources/*/*.swift -o "$app/Contents/MacOS/Relaybar"
codesign --force --sign - "$app"
if [ "${1:-}" = "--install" ]; then
  pkill -x Relaybar || true
  while pgrep -x Relaybar > /dev/null; do sleep 0.2; done
  rm -rf "$HOME/Applications/Relaybar.app"
  ditto "$app" "$HOME/Applications/Relaybar.app"
  for attempt in 1 2 3 4 5; do
    open "$HOME/Applications/Relaybar.app" && break
    sleep 1
  done
fi
