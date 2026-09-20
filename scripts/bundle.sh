#!/bin/bash
#
# Build the SwiftPM executable and assemble a normal macOS app bundle.
#
# Usage: ./scripts/bundle.sh [debug|release]

set -euo pipefail

CONFIG="${1:-debug}"
APP_NAME="TartUI"
BUNDLE_ID="com.tartui.app"
VERSION="${TARTUI_VERSION:-0.1.0}"
BUILD_NUMBER="${TARTUI_BUILD_NUMBER:-$VERSION}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/clang-module-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$ROOT/.build/swift-module-cache}"

source "$ROOT/scripts/lib.sh"
export TARTUI_SIGNING_CONFIGURATION="$CONFIG"

echo "==> Build ($CONFIG)"
swift build -c "$CONFIG" --product "$APP_NAME"

BIN_PATH="$(swift build -c "$CONFIG" --product "$APP_NAME" --show-bin-path)"
APP_DIR="$BIN_PATH/$APP_NAME.app"

echo "==> Assemble $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

for resource_bundle in "$BIN_PATH"/TartUI_*.bundle; do
  [ -d "$resource_bundle" ] && cp -R "$resource_bundle" "$APP_DIR/Contents/Resources/"
done

if [ -f "$ROOT/LICENSE" ]; then
  mkdir -p "$APP_DIR/Contents/Resources/Legal"
  cp "$ROOT/LICENSE" "$APP_DIR/Contents/Resources/Legal/TartUI-LICENSE.txt"
fi

if [ -f "$ROOT/THIRD_PARTY_NOTICES.md" ]; then
  mkdir -p "$APP_DIR/Contents/Resources/Legal"
  cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/Legal/THIRD_PARTY_NOTICES.md"
fi

ICON_SRC="$ROOT/Resources/icon.png"
if [ -f "$ICON_SRC" ]; then
  echo "==> Generate icon"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"

  for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
    double=$((size * 2))
    sips -z $double $double "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
  done

  iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null \
    && ICON_ENTRY='  <key>CFBundleIconFile</key>
  <string>AppIcon</string>' \
    || { echo "Warning: icon conversion failed"; ICON_ENTRY=""; }

  rm -rf "$(dirname "$ICONSET")"
else
  ICON_ENTRY=""
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
$ICON_ENTRY
</dict>
</plist>
PLIST

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

detect_signing_identity
echo "==> Sign ($SIGN_DESCRIPTION)"

SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_DESCRIPTION" == Developer\ ID* ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi

codesign "${SIGN_ARGS[@]}" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "    Run: open \"$APP_DIR\""
