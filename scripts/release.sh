#!/bin/bash
#
# 构建并公证一个可直接分发的 TartUI DMG。
#
# 前置条件：
#   - 已安装 Developer ID Application 证书；
#   - 已用 xcrun notarytool store-credentials 保存公证 profile；
#   - 设置 TARTUI_NOTARY_PROFILE。
#
# 用法：TARTUI_VERSION=0.1.0 TARTUI_NOTARY_PROFILE=tartui ./scripts/release.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${TARTUI_VERSION:-0.1.0}"
NOTARY_PROFILE="${TARTUI_NOTARY_PROFILE:-}"
if [ -z "$NOTARY_PROFILE" ]; then
  echo "错误：请设置 TARTUI_NOTARY_PROFILE。" >&2
  exit 1
fi

# bundle.sh 会优先选择 Developer ID Application；这里提前阻止误把临时签名
# 上传到公证服务，避免浪费一轮构建等待。
if [ -z "${TARTUI_SIGN_IDENTITY:-}" ]; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if ! echo "$IDENTITIES" | grep -q "Developer ID Application"; then
    echo "错误：没有找到 Developer ID Application 证书。" >&2
    exit 1
  fi
fi

DIST="$ROOT/dist"
ZIP="$DIST/TartUI-$VERSION.zip"
DMG="$DIST/TartUI-$VERSION.dmg"

rm -rf "$DIST"
mkdir -p "$DIST"

TARTUI_VERSION="$VERSION" "$ROOT/scripts/bundle.sh" release

BIN_PATH="$(swift build -c release --product TartUI --show-bin-path)"
APP="$BIN_PATH/TartUI.app"

if [ ! -d "$APP" ]; then
  echo "错误：没有找到 release App：$APP" >&2
  exit 1
fi

echo "==> 公证提交"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> 固化公证票据"
xcrun stapler staple "$APP"

echo "==> 生成 DMG"
hdiutil create \
  -volname "TartUI $VERSION" \
  -srcfolder "$APP" \
  -ov \
  -format UDZO \
  "$DMG"

rm -f "$ZIP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"

echo "完成：$DMG"
