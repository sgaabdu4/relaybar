#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app=build/Relaybar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/"
cp Resources/*.svg Resources/LOGOS-LICENSE.txt Resources/relaybar-helper.sh "$app/Contents/Resources/"
iconset=build/AppIcon.iconset
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" > /dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
swift build -c release --product Relaybar --arch arm64 --arch x86_64 -Xswiftc -Osize
products="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
cp "$products/Relaybar" "$app/Contents/MacOS/Relaybar"
mkdir -p "$app/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$app/Contents/Frameworks/Sparkle.framework"
if [ -n "${RELAYBAR_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELAYBAR_VERSION" "$app/Contents/Info.plist"
fi
if [ -n "${RELAYBAR_BUILD:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RELAYBAR_BUILD" "$app/Contents/Info.plist"
fi
codesign --force --sign - "$app/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$app"
if [ "${1:-}" = "--install" ]; then
  pkill -x Relaybar || true
  while pgrep -x Relaybar > /dev/null; do sleep 0.2; done
  rm -rf /Applications/Relaybar.app
  ditto "$app" /Applications/Relaybar.app
  for _ in 1 2 3 4 5; do
    open /Applications/Relaybar.app && break
    sleep 1
  done
fi
