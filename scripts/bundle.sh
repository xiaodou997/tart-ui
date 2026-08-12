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
APP_NAME="TartUI"
BUNDLE_ID="com.tartui.app"
VERSION="${TARTUI_VERSION:-0.1.0}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Keep compiler module caches inside the project so builds also work when the
# user's global Swift cache directory is unavailable (for example in a sandbox).
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/clang-module-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$ROOT/.build/swift-module-cache}"

# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

export TARTUI_PROJECT_ROOT="$ROOT"
export TARTUI_SIGNING_CONFIGURATION="$CONFIG"

# 变量一律用 ${} 包起来：紧跟中文全角标点时，bash 会把标点也当成变量名的一部分。
echo "==> 构建（${CONFIG}）"
swift build -c "$CONFIG" --product "$APP_NAME"

BIN_PATH="$(swift build -c "$CONFIG" --product "$APP_NAME" --show-bin-path)"
APP_DIR="$BIN_PATH/$APP_NAME.app"

echo "==> 组装 $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Helpers"

cp "$BIN_PATH/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

# Swift Package Manager 编译的本地化资源会生成独立的 resource bundle。
# 把它放入 .app 的 Resources 目录，Bundle.module 才能在 Finder 启动时找到。
for resource_bundle in "$BIN_PATH"/TartUI_*.bundle; do
  [ -d "$resource_bundle" ] && cp -R "$resource_bundle" "$APP_DIR/Contents/Resources/"
done

# 内置的 tart 只是个命令行工具，负责 OCI 操作（pull / clone / list / prune）。
# 虚拟机跑在 TartUI 进程内，所以这里不再需要嵌套 .app、LSUIElement、
# provisioning profile 或任何 entitlement——普通二进制即可。
TART_HELPER_BINARY="$APP_DIR/Contents/Helpers/tart"
if [ "${TARTUI_SKIP_TART_HELPER:-0}" = "1" ]; then
  echo "警告：已跳过内置 Tart helper（TARTUI_SKIP_TART_HELPER=1），OCI 操作将依赖系统 Tart"
else
  # 以前这里失败只在 debug 下打一行警告，然后 App 悄悄退回去用系统 tart。
  # 结果「跑的到底是哪一份 tart」从现象上分辨不出来，排查时极具误导性。
  # 现在一律硬失败：要跳过就显式设 TARTUI_SKIP_TART_HELPER=1。
  if ! "$ROOT/scripts/build-tart-helper.sh" "$CONFIG" "$TART_HELPER_BINARY"; then
    echo "错误：内置 Tart helper 构建失败" >&2
    echo "      如需临时跳过，请显式设置 TARTUI_SKIP_TART_HELPER=1" >&2
    exit 1
  fi
fi

if [ -f "$ROOT/LICENSE" ]; then
  mkdir -p "$APP_DIR/Contents/Resources/Legal"
  cp "$ROOT/LICENSE" "$APP_DIR/Contents/Resources/Legal/TartUI-LICENSE.txt"
fi
if [ -f "$ROOT/THIRD_PARTY_NOTICES.md" ]; then
  mkdir -p "$APP_DIR/Contents/Resources/Legal"
  cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/Legal/THIRD_PARTY_NOTICES.md"
fi
for tart_license in "$ROOT/Vendor/tart/LICENSE" "$ROOT/../tart/LICENSE"; do
  if [ -f "$tart_license" ]; then
    mkdir -p "$APP_DIR/Contents/Resources/Legal"
    cp "$tart_license" "$APP_DIR/Contents/Resources/Legal/Tart-LICENSE.txt"
    break
  fi
done

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
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>TartUI uses the local network for VM networking and OCI registry access.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
$ICON_ENTRY
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <!-- TartUI 自身不虚拟化任何东西，只调用 tart 命令行；
       虚拟化 entitlement 属于 tart 二进制，不需要在这里声明。 -->
</dict>
</plist>
PLIST

# 校验 plist 格式。缺个结束标签这类问题不会让应用起不来（CFBundle 有容错），
# 但图标之类的声明会被静默忽略，排查起来很费劲。
if ! plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1; then
  echo "错误：生成的 Info.plist 格式不合法" >&2
  plutil -lint "$APP_DIR/Contents/Info.plist" >&2
  exit 1
fi

detect_signing_identity

# 虚拟化 entitlement 现在属于 TartUI 本体：虚拟机在 TartUI 进程内创建，
# 权限必须挂在这个进程上。内置的 tart 只做 OCI 操作，不需要任何 entitlement。
#
# 先签内层 helper（普通签名即可），再签外层 App 并附上 entitlement。
# 不要用 --deep，它会用外层的 entitlement 覆盖内层签名。
if [ -x "$TART_HELPER_BINARY" ]; then
  echo "==> 签名 Tart helper（无 entitlement）"
  codesign --force --sign "$SIGN_IDENTITY" "$TART_HELPER_BINARY"
fi

# debug 用 Apple Development 证书就能满足的最小权限集；release 额外声明
# com.apple.vm.networking（桥接网络），那是受限权限，需要 Apple 单独授权
# 和匹配的 provisioning profile。
TARTUI_ENTITLEMENTS="${TARTUI_ENTITLEMENTS:-}"
if [ -z "$TARTUI_ENTITLEMENTS" ]; then
  if [ "$CONFIG" = "debug" ]; then
    TARTUI_ENTITLEMENTS="$ROOT/Resources/TartUI-dev.entitlements"
  else
    TARTUI_ENTITLEMENTS="$ROOT/Resources/TartUI-prod.entitlements"
  fi
fi

if [ ! -f "$TARTUI_ENTITLEMENTS" ]; then
  echo "错误：找不到 entitlement 文件：$TARTUI_ENTITLEMENTS" >&2
  echo "      没有 com.apple.security.virtualization，TartUI 无法创建虚拟机。" >&2
  exit 1
fi

# release 声明了受限的 com.apple.vm.networking，必须有匹配的 provisioning
# profile，否则 AMFI 会在启动时终止进程——而且现象是「App 一闪就没了」，
# 很难反查。这里提前拦住。
if [ "$CONFIG" != "debug" ] && grep -q "com.apple.vm.networking" "$TARTUI_ENTITLEMENTS"; then
  TARTUI_PROVISION_PROFILE="${TARTUI_PROVISION_PROFILE:-}"
  if [ -z "$TARTUI_PROVISION_PROFILE" ]; then
    echo "错误：$TARTUI_ENTITLEMENTS 声明了受限权限 com.apple.vm.networking，" >&2
    echo "      必须通过 TARTUI_PROVISION_PROFILE 提供匹配 $BUNDLE_ID 的 provisioning profile。" >&2
    echo "      若尚未获得 Apple 授权，请注释掉该权限（NAT 网络不受影响）。" >&2
    exit 1
  fi
  echo "==> 嵌入 provisioning profile：$TARTUI_PROVISION_PROFILE"
  cp "$TARTUI_PROVISION_PROFILE" "$APP_DIR/Contents/embedded.provisionprofile"
fi

echo "==> 签名（${SIGN_DESCRIPTION}）：$(basename "$TARTUI_ENTITLEMENTS")"
# 签名失败以前会回退到临时签名再回退到「什么都不做」，于是构建「成功」但
# App 起不来或没有虚拟化权限。签名是硬要求，失败就停。
if ! codesign --force --sign "$SIGN_IDENTITY" --entitlements "$TARTUI_ENTITLEMENTS" "$APP_DIR"; then
  echo "错误：签名失败。没有有效签名和虚拟化 entitlement，TartUI 无法创建虚拟机。" >&2
  exit 1
fi

# 签完立刻核对 entitlement 真的进去了。codesign 在某些证书/权限组合下会
# 静默丢弃条目，等到运行时才炸。
if ! codesign -d --entitlements - --xml "$APP_DIR" 2>/dev/null | grep -q "com.apple.security.virtualization"; then
  echo "错误：签名后的 App 缺少 com.apple.security.virtualization" >&2
  exit 1
fi
echo "    已确认虚拟化 entitlement 生效"

echo "==> 完成：$APP_DIR"
echo "    运行：open \"$APP_DIR\""
