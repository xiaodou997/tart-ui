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

# Tart 是内置 runtime，放在隐藏的嵌套 .app 中。这样可以把 Apple provisioning
# profile 放在 helper 的 Contents/embedded.provisionprofile，同时让 TartUI 成为
# 唯一用户级应用。helper 的 LSUIElement 不是临时藏图标，而是 runtime Agent 的
# 明确产品边界：Tart 负责虚拟机窗口，TartUI 负责应用入口和生命周期。
# 开发时默认使用旁边的 ../tart，发布时使用 Vendor/tart。
TART_HELPER_APP="$APP_DIR/Contents/Helpers/tart.app"
TART_HELPER_BINARY="$TART_HELPER_APP/Contents/MacOS/tart"
if [ "${TARTUI_SKIP_TART_HELPER:-0}" = "1" ]; then
  echo "警告：已跳过内置 Tart helper（TARTUI_SKIP_TART_HELPER=1）"
else
  if ! "$ROOT/scripts/build-tart-helper.sh" "$CONFIG" "$TART_HELPER_BINARY"; then
    if [ "$CONFIG" = "release" ]; then
      echo "错误：release 版本必须包含内置 Tart helper" >&2
      exit 1
    fi
    echo "警告：debug 版本没有内置 Tart helper，可通过 TARTUI_TART_BINARY 或系统 Tart 运行"
  else
    TART_HELPER_BUNDLE_ID="${TARTUI_TART_HELPER_BUNDLE_ID:-com.tartui.tart-helper}"
    TART_HELPER_VERSION="${TARTUI_TART_HELPER_VERSION:-$VERSION}"
    cat > "$TART_HELPER_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>tart</string>
  <key>CFBundleIdentifier</key>
  <string>$TART_HELPER_BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Tart</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSUIElement</key>
  <true/>
  <key>CFBundleShortVersionString</key>
  <string>$TART_HELPER_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$TART_HELPER_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
</dict>
</plist>
PLIST
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

# Tart 的 Virtualization entitlement 属于 helper，不属于 UI 进程。先签完整的内层
# helper App（而不是只签它的 Mach-O 文件），再签外层 App；不要用 codesign --deep
# 给外层重新覆盖 helper 的 entitlement。
TART_HELPER="$TART_HELPER_BINARY"
if [ -x "$TART_HELPER" ]; then
  TART_SOURCE_FOR_SIGNING="${TARTUI_TART_SOURCE_DIR:-}"
  if [ -z "$TART_SOURCE_FOR_SIGNING" ] && [ -f "$ROOT/Vendor/tart/Resources/tart-prod.entitlements" ]; then
    TART_SOURCE_FOR_SIGNING="$ROOT/Vendor/tart"
  elif [ -z "$TART_SOURCE_FOR_SIGNING" ] && [ -f "$ROOT/../tart/Resources/tart-prod.entitlements" ]; then
    TART_SOURCE_FOR_SIGNING="$ROOT/../tart"
  fi

  TART_ENTITLEMENTS="${TARTUI_TART_ENTITLEMENTS:-}"
  if [ -z "$TART_ENTITLEMENTS" ] && [ -f "$ROOT/Resources/tart-prod.entitlements" ]; then
    TART_ENTITLEMENTS="$ROOT/Resources/tart-prod.entitlements"
  fi
  if [ -z "$TART_ENTITLEMENTS" ] && [ -n "$TART_SOURCE_FOR_SIGNING" ]; then
    TART_ENTITLEMENTS="$TART_SOURCE_FOR_SIGNING/Resources/tart-prod.entitlements"
  fi

  # Tart 上游的本地运行脚本使用 dev entitlement；生产 entitlement 中的网络权限
  # 需要正式签名身份。ad-hoc 场景继续支持本机开发，但不能把 prod entitlement
  # 硬塞给一个没有 Team ID 的签名对象，否则 macOS 会在启动时直接 kill helper。
  if [ "$SIGN_IDENTITY" = "-" ]; then
    TART_DEV_ENTITLEMENTS="${TARTUI_TART_DEV_ENTITLEMENTS:-}"
    if [ -z "$TART_DEV_ENTITLEMENTS" ] && [ -f "$ROOT/Resources/tart-dev.entitlements" ]; then
      TART_DEV_ENTITLEMENTS="$ROOT/Resources/tart-dev.entitlements"
    fi
    if [ -z "$TART_DEV_ENTITLEMENTS" ] && [ -n "$TART_SOURCE_FOR_SIGNING" ]; then
      TART_DEV_ENTITLEMENTS="$TART_SOURCE_FOR_SIGNING/Resources/tart-dev.entitlements"
    fi
    if [ -f "$TART_DEV_ENTITLEMENTS" ]; then
      TART_ENTITLEMENTS="$TART_DEV_ENTITLEMENTS"
    fi
  fi

  if [ "$SIGN_IDENTITY" != "-" ]; then
    TART_PROVISION_PROFILE="$(find_tart_provisioning_profile "$ROOT" || true)"
    if [ -z "$TART_PROVISION_PROFILE" ]; then
      echo "错误：正式签名 Tart helper 需要 TARTUI_TART_PROVISION_PROFILE，且必须匹配 $TART_HELPER_BUNDLE_ID" >&2
      exit 1
    fi
    echo "==> 嵌入 Tart provisioning profile：$TART_PROVISION_PROFILE"
    cp "$TART_PROVISION_PROFILE" "$TART_HELPER_APP/Contents/embedded.provisionprofile"
  fi

  echo "==> 签名 Tart helper app"
  if [ -f "$TART_ENTITLEMENTS" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --entitlements "$TART_ENTITLEMENTS" "$TART_HELPER_APP"
  else
    echo "警告：没有找到 Tart entitlement 文件，使用普通签名"
    codesign --force --sign "$SIGN_IDENTITY" "$TART_HELPER_APP"
  fi
fi

echo "==> 签名（${SIGN_DESCRIPTION}）"
if ! codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR" 2>/dev/null; then
  echo "警告：使用 ${SIGN_IDENTITY} 签名失败，回退到临时签名"
  codesign --force --sign - "$APP_DIR" 2>/dev/null \
    || echo "警告：签名失败，App 可能无法启动"
fi

echo "==> 完成：$APP_DIR"
echo "    运行：open \"$APP_DIR\""
