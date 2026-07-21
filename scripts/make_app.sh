#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/QuotaGlass.app"
ZIP="$ROOT/build/QuotaGlass.app.zip"
MACOS="$APP/Contents/MacOS"
ICONSET="$ROOT/build/QuotaGlass.iconset"
ICON="$APP/Contents/Resources/QuotaGlass.icns"

if [[ -z "${VERSION:-}" ]]; then
  latest_tag="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
  if [[ "$latest_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    VERSION="${latest_tag#v}"
  else
    VERSION="0.0.0"
  fi
fi
BUNDLE_VERSION="${BUNDLE_VERSION:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || printf '1')}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'VERSION must be x.y.z, got: %s\n' "$VERSION" >&2
  exit 1
fi
if [[ ! "$BUNDLE_VERSION" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
  printf 'BUNDLE_VERSION must contain only numeric components, got: %s\n' "$BUNDLE_VERSION" >&2
  exit 1
fi

BUILD_FLAGS=(--arch arm64 --arch x86_64)
if [[ -n "${SWIFT_BUILD_FLAGS:-}" ]]; then
  read -r -a BUILD_FLAGS <<< "$SWIFT_BUILD_FLAGS"
fi

if [[ "${RELEASE_BUILD:-0}" == "1" ]]; then
  if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]]; then
    printf 'RELEASE_BUILD=1 requires a clean worktree\n' >&2
    exit 1
  fi
  exact_tag="$(git -C "$ROOT" describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null || true)"
  if [[ "$exact_tag" != "v$VERSION" ]]; then
    printf 'Release version/tag mismatch: VERSION=%s, tag=%s\n' "$VERSION" "${exact_tag:-<none>}" >&2
    exit 1
  fi
  if [[ -z "${CODESIGN_IDENTITY:-}" || "${CODESIGN_IDENTITY}" == "-" ]]; then
    printf 'RELEASE_BUILD=1 requires a non-ad-hoc CODESIGN_IDENTITY\n' >&2
    exit 1
  fi
fi

cd "$ROOT"
swift build -c release "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${BUILD_FLAGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$MACOS" "$APP/Contents/Resources"
cp "$BIN_DIR/QuotaGlass" "$MACOS/QuotaGlass"
# Bundle.module fatalErrors at runtime if the SPM resource bundle is missing.
cp -R "$BIN_DIR/QuotaGlass_QuotaGlass.bundle" "$APP/Contents/Resources/"

swift "$ROOT/scripts/make_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ICON"

resource_bundle="$APP/Contents/Resources/QuotaGlass_QuotaGlass.bundle"
for logo in codex claude sakana; do
  flat_logo="$resource_bundle/$logo.svg"
  macos_bundle_logo="$resource_bundle/Contents/Resources/$logo.svg"
  if [[ ! -s "$flat_logo" && ! -s "$macos_bundle_logo" ]]; then
    printf 'Missing bundled logo: %s\n' "$logo" >&2
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
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
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
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -lint "$APP/Contents/Info.plist" >/dev/null
for ((i = 0; i < ${#BUILD_FLAGS[@]}; i++)); do
  if [[ "${BUILD_FLAGS[$i]}" == "--arch" && $((i + 1)) -lt ${#BUILD_FLAGS[@]} ]]; then
    lipo "$MACOS/QuotaGlass" -verify_arch "${BUILD_FLAGS[$((i + 1))]}"
  fi
done

if [[ -n "${CODESIGN_IDENTITY:-}" && "${CODESIGN_IDENTITY}" != "-" ]]; then
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP" >/dev/null
else
  codesign --force --sign - "$APP" >/dev/null
fi
codesign --verify --deep --strict "$APP"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
unzip -tq "$ZIP" >/dev/null
printf 'Built %s\n' "$APP"
printf 'Packaged %s\n' "$ZIP"
