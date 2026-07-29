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
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <!-- TartPro 自身不虚拟化任何东西，只调用 tart 命令行；
       虚拟化 entitlement 属于 tart 二进制，不需要在这里声明。 -->
</dict>
PLIST

# 本地开发用临时签名即可；正式分发要换成 Developer ID 并做公证。
codesign --force --sign - "$APP_DIR" 2>/dev/null || echo "警告：临时签名失败，App 可能无法启动"

echo "==> 完成：$APP_DIR"
echo "    运行：open \"$APP_DIR\""
