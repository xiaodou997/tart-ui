#!/bin/bash
#
# 把 SPM 的构建产物组装成 macOS .app bundle。
#
# SwiftUI 的 WindowGroup 需要一个真实的 bundle（含 Info.plist）才能建出窗口；
# 直接 `swift run` 得到的裸可执行文件会启动后立刻退出。
#
# 用法：./scripts/bundle.sh [debug|release]

set -euo pipefail

CONFIG="${1:-debug}"
APP_NAME="TartPro"
BUNDLE_ID="com.tartpro.app"
VERSION="0.1.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

# 变量一律用 ${} 包起来：紧跟中文全角标点时，bash 会把标点也当成变量名的一部分。
echo "==> 构建（${CONFIG}）"
swift build -c "$CONFIG" --product "$APP_NAME"

BIN_PATH="$(swift build -c "$CONFIG" --product "$APP_NAME" --show-bin-path)"
APP_DIR="$BIN_PATH/$APP_NAME.app"

echo "==> 组装 $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

# 图标：把 Resources/icon.png 转成 .icns。
# 换图标只需替换这个 PNG（建议 1024×1024）再重新打包，不用改任何代码。
ICON_SRC="$ROOT/Resources/icon.png"
if [ -f "$ICON_SRC" ]; then
  echo "==> 生成图标"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"

  # macOS 要求提供各个尺寸，包括 @2x 视网膜版本。
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
    double=$((size * 2))
    sips -z $double $double "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
  done

  iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null \
    && ICON_ENTRY='  <key>CFBundleIconFile</key>
  <string>AppIcon</string>' \
    || { echo "警告：图标转换失败，将使用系统默认图标"; ICON_ENTRY=""; }

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
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
$ICON_ENTRY
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <!-- TartPro 自身不虚拟化任何东西，只调用 tart 命令行；
       虚拟化 entitlement 属于 tart 二进制，不需要在这里声明。 -->
</dict>
PLIST

detect_signing_identity
echo "==> 签名（${SIGN_DESCRIPTION}）"
if ! codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" 2>/dev/null; then
  echo "警告：使用 ${SIGN_IDENTITY} 签名失败，回退到临时签名"
  codesign --force --deep --sign - "$APP_DIR" 2>/dev/null \
    || echo "警告：签名失败，App 可能无法启动"
fi

echo "==> 完成：$APP_DIR"
echo "    运行：open \"$APP_DIR\""
