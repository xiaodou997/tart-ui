#!/bin/bash
#
# Build, notarize and package a distributable TartUI release.
#
# Prerequisites:
#   - Developer ID Application certificate installed in the active keychain;
#   - a notarytool keychain profile created with:
#       xcrun notarytool store-credentials <profile> ...
#   - TARTUI_NOTARY_PROFILE set to that profile name.
#
# Usage:
#   TARTUI_VERSION=0.1.0 TARTUI_NOTARY_PROFILE=tartui ./scripts/release.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${TARTUI_VERSION:-0.1.0}"
BUILD_NUMBER="${TARTUI_BUILD_NUMBER:-$VERSION}"
NOTARY_PROFILE="${TARTUI_NOTARY_PROFILE:-}"

if [ -z "$NOTARY_PROFILE" ]; then
  echo "Error: TARTUI_NOTARY_PROFILE is required." >&2
  exit 1
fi

if [ -z "${TARTUI_SIGN_IDENTITY:-}" ]; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if ! echo "$IDENTITIES" | grep -q "Developer ID Application"; then
    echo "Error: no Developer ID Application certificate was found." >&2
    exit 1
  fi
fi

DIST="$ROOT/dist"
FINAL_ZIP="$DIST/TartUI-$VERSION.zip"
NOTARY_ZIP="$DIST/.TartUI-$VERSION-notary.zip"
DMG="$DIST/TartUI-$VERSION.dmg"
CHECKSUMS="$DIST/SHA256SUMS"
STAGING="$DIST/dmg-root"

rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Build signed release app"
TARTUI_VERSION="$VERSION" \
TARTUI_BUILD_NUMBER="$BUILD_NUMBER" \
  "$ROOT/scripts/bundle.sh" release

BIN_PATH="$(swift build -c release --product TartUI --arch arm64 --show-bin-path)"
APP="$BIN_PATH/TartUI.app"

if [ ! -d "$APP" ]; then
  echo "Error: release app was not found at $APP" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Notarize app"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$NOTARY_ZIP"

echo "==> Create final ZIP"
ditto -c -k --keepParent "$APP" "$FINAL_ZIP"

echo "==> Create DMG"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/TartUI.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "TartUI $VERSION" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG"

rm -rf "$STAGING"

echo "==> Notarize DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Verify release artifacts"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"

(
  cd "$DIST"
  shasum -a 256 "TartUI-$VERSION.zip" "TartUI-$VERSION.dmg" > "SHA256SUMS"
)

echo ""
echo "Release artifacts:"
echo "  $FINAL_ZIP"
echo "  $DMG"
echo "  $CHECKSUMS"
