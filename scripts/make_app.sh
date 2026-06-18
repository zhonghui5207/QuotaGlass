#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/QuotaGlass.app"
ZIP="$ROOT/build/QuotaGlass.app.zip"
MACOS="$APP/Contents/MacOS"
ICONSET="$ROOT/build/QuotaGlass.iconset"
ICON="$APP/Contents/Resources/QuotaGlass.icns"
VERSION="${VERSION:-0.2.2}"
BUNDLE_VERSION="${BUNDLE_VERSION:-3}"

cd "$ROOT"
swift build -c release

rm -rf "$APP"
mkdir -p "$MACOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/QuotaGlass" "$MACOS/QuotaGlass"
# Bundle.module fatalErrors at runtime if the SPM resource bundle is missing.
cp -R "$ROOT/.build/release/QuotaGlass_QuotaGlass.bundle" "$APP/Contents/Resources/"

swift "$ROOT/scripts/make_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ICON"

for logo in codex claude; do
  logo_path="$APP/Contents/Resources/QuotaGlass_QuotaGlass.bundle/$logo.svg"
  if [[ ! -s "$logo_path" ]]; then
    printf 'Missing bundled logo: %s\n' "$logo_path" >&2
    exit 1
  fi
done
if [[ ! -s "$ICON" ]]; then
  printf 'Missing bundled app icon: %s\n' "$ICON" >&2
  exit 1
fi

cat > "$APP/Contents/Info.plist" <<PLIST
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
  <key>CFBundleIconFile</key>
  <string>QuotaGlass</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUNDLE_VERSION</string>
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
rm -f "$ZIP"
(
  cd "$ROOT/build"
  zip -qry "$ZIP" QuotaGlass.app \
    -x '*.DS_Store' \
    -x '__MACOSX/*' \
    -x '*/._*'
)
printf 'Built %s\n' "$APP"
printf 'Packaged %s\n' "$ZIP"
