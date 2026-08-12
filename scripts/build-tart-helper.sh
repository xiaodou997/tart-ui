#!/bin/bash
#
# 编译内置的 tart 命令行 helper，供 bundle.sh 放进
# TartUI.app/Contents/Helpers/tart。
#
# 这个 helper 只负责 OCI 相关的一次性命令：pull / clone / push / list /
# prune / export。虚拟机本身跑在 TartUI 进程内（见 Sources/TartVMCore），
# 所以 helper 既不需要虚拟化 entitlement，也不需要任何窗口或 Dock 处理，
# 更不需要给上游打补丁。
#
# 用法：./scripts/build-tart-helper.sh [debug|release] <output-path>

set -euo pipefail

CONFIG="${1:-debug}"
OUTPUT="${2:?missing output path}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 只认 submodule。以前还会回退到旁边的 ../tart，结果本机同时存在两份不同
# 版本的源码，构建出来的 helper 到底是哪一份完全看不出来——排查问题时这是
# 个纯粹的干扰项，不如直接不允许。
TART_SOURCE_DIR="${TARTUI_TART_SOURCE_DIR:-$ROOT/Vendor/tart}"

if [ ! -f "$TART_SOURCE_DIR/Package.swift" ]; then
  echo "错误：找不到 Tart 源码：$TART_SOURCE_DIR" >&2
  echo "      请先执行 git submodule update --init --recursive" >&2
  exit 1
fi

TART_SOURCE_DIR="$(cd "$TART_SOURCE_DIR" && pwd)"
echo "==> 构建 Tart helper（${CONFIG}）：$TART_SOURCE_DIR"

# 上游用 .ci/set-version.sh 在发布时把 CI.swift 里的 ${VERSION} 占位符替换掉，
# 我们直接编译源码，不走那条发布流程。占位符没被替换时 CI.version 会变成
# 字符串 "SNAPSHOT"，而这个值会通过一个名为 tart-version-<版本> 的 console
# 设备传给客户机的 guest agent 做特性检查——agent 读到无法解析的版本，就会
# 每隔十几秒重启一次客户机（现象：进桌面几秒后回到开机画面）。
#
# 进程内运行时（Sources/TartVMCore/TartVersion.swift）已经绕开了上游的
# CI.swift，这里检查的是 helper 二进制，确保两边版本号一致。
TART_VERSION="$(git -C "$TART_SOURCE_DIR" describe --tags --abbrev=0 2>/dev/null || echo unknown)"
echo "    版本：${TART_VERSION}"

DECLARED_VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' \
  "$ROOT/Sources/TartVMCore/TartVersion.swift" 2>/dev/null)"
if [ -n "$DECLARED_VERSION" ] && [ "$TART_VERSION" != "unknown" ] \
   && [ "$DECLARED_VERSION" != "$TART_VERSION" ]; then
  echo "错误：Sources/TartVMCore/TartVersion.swift 声明的版本（${DECLARED_VERSION}）" >&2
  echo "      与 Vendor/tart 的实际版本（${TART_VERSION}）不一致。" >&2
  echo "      客户机的 guest agent 依赖这个版本号，不一致会导致虚拟机反复重启。" >&2
  exit 1
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$TART_SOURCE_DIR/.build/clang-module-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$TART_SOURCE_DIR/.build/swift-module-cache}"

swift build \
  --package-path "$TART_SOURCE_DIR" \
  -c "$CONFIG" \
  --product tart

TART_BIN_PATH="$(swift build --package-path "$TART_SOURCE_DIR" -c "$CONFIG" --product tart --show-bin-path)"

mkdir -p "$(dirname "$OUTPUT")"
cp "$TART_BIN_PATH/tart" "$OUTPUT"
chmod u+x "$OUTPUT"
echo "Tart helper：$OUTPUT"
