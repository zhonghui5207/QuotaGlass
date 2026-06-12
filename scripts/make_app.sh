#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/QuotaGlass.app"
MACOS="$APP/Contents/MacOS"

cd "$ROOT"
swift build -c release

rm -rf "$APP"
mkdir -p "$MACOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/QuotaGlass" "$MACOS/QuotaGlass"
# Bundle.module fatalErrors at runtime if the SPM resource bundle is missing.
cp -R "$ROOT/.build/release/QuotaGlass_QuotaGlass.bundle" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>QuotaGlass</string>
  <key>CFBundleIdentifier</key>
  <string>com.ryan.quotaglass</string>
  <key>CFBundleName</key>
  <string>QuotaGlass</string>
  <key>CFBundleDisplayName</key>
  <string>QuotaGlass</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
printf 'Built %s\n' "$APP"
