#!/bin/bash
# Builds build/Pluck.app. Usage: scripts/bundle.sh [--install] (copies to /Applications).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app=build/Pluck.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/Pluck "$app/Contents/MacOS/Pluck"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.chuyeow.pluck</string>
  <key>CFBundleName</key><string>Pluck</string>
  <key>CFBundleExecutable</key><string>Pluck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# A real identity keeps the Screen Recording grant across rebuilds; ad-hoc signing resets it every build.
identity="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${identity:--}" "$app"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Pluck.app
  cp -R "$app" /Applications/
  echo "Installed /Applications/Pluck.app"
fi
echo "Built $app"
