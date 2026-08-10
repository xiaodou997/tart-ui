#!/bin/bash
#
# 编译或选取 Tart helper，供 bundle.sh 放入隐藏的
# TartUI.app/Contents/Helpers/tart.app。
#
# Tart 保持独立的 Swift Package，不作为 TartUI 的依赖 target；这样上游更新时
# 只需要更新固定的 Tart commit，不需要修改 Tart 源码或把它重构成 library。
#
# 用法：./scripts/build-tart-helper.sh [debug|release] <output-path>
# output-path 通常是 TartUI.app/Contents/Helpers/tart.app/Contents/MacOS/tart。

set -euo pipefail

CONFIG="${1:-debug}"
OUTPUT="${2:?missing output path}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

resolve_binary() {
  local candidate="$1"
  if [ -d "$candidate" ]; then
    if [ -x "$candidate/Contents/MacOS/tart" ]; then
      echo "$candidate/Contents/MacOS/tart"
      return 0
    fi
    if [ -x "$candidate/tart" ]; then
      echo "$candidate/tart"
      return 0
    fi
  elif [ -x "$candidate" ]; then
    echo "$candidate"
    return 0
  fi
  return 1
}

TART_SOURCE_DIR="${TARTUI_TART_SOURCE_DIR:-}"
if [ -z "$TART_SOURCE_DIR" ]; then
  if [ -f "$ROOT/Vendor/tart/Package.swift" ]; then
    TART_SOURCE_DIR="$ROOT/Vendor/tart"
  elif [ -f "$ROOT/../tart/Package.swift" ]; then
    TART_SOURCE_DIR="$ROOT/../tart"
  fi
fi

TART_BINARY="${TARTUI_TART_BINARY:-}"
if [ -n "$TART_BINARY" ]; then
  if ! TART_BINARY="$(resolve_binary "$TART_BINARY")"; then
    echo "错误：TARTUI_TART_BINARY 不是可执行的 Tart：$TARTUI_TART_BINARY" >&2
    exit 1
  fi
elif [ -n "$TART_SOURCE_DIR" ]; then
  TART_SOURCE_DIR="$(cd "$TART_SOURCE_DIR" && pwd)"
  echo "==> 构建 Tart helper（${CONFIG}）：$TART_SOURCE_DIR"

  # Tart 原生窗口模式会主动设置 .regular，单靠 LSUIElement 无法隐藏 helper
  # 的 Dock 图标。这里只对构建过程临时应用一个最小集成补丁，并在退出时恢复
  # 上游源码；Vendor/tart 本身不会留下修改。上游更新导致补丁无法套用时，
  # 构建直接失败，避免静默退回双 Dock 图标。
  AGENT_PATCH="$ROOT/Resources/tart-agent.patch"
  AGENT_SOURCE="$TART_SOURCE_DIR/Sources/tart/Commands/Run.swift"
  AGENT_PATCH_APPLIED=0
  restore_agent_patch() {
    if [ "$AGENT_PATCH_APPLIED" = "1" ]; then
      git -C "$TART_SOURCE_DIR" apply --reverse "$AGENT_PATCH" >/dev/null 2>&1 || {
        echo "错误：无法恢复 Tart Agent 集成补丁，请检查 $AGENT_SOURCE" >&2
        exit 1
      }
      AGENT_PATCH_APPLIED=0
    fi
  }
  trap restore_agent_patch EXIT INT TERM

  if git -C "$TART_SOURCE_DIR" apply --check "$AGENT_PATCH" >/dev/null 2>&1; then
    git -C "$TART_SOURCE_DIR" apply "$AGENT_PATCH"
    AGENT_PATCH_APPLIED=1
    echo "==> 临时应用 TartUI Agent 集成补丁"
  elif git -C "$TART_SOURCE_DIR" apply --reverse --check "$AGENT_PATCH" >/dev/null 2>&1; then
    echo "==> Tart 源码已包含 Agent 集成补丁"
  else
    echo "错误：当前 Tart 版本无法应用 TartUI Agent 集成补丁：$AGENT_PATCH" >&2
    echo "      请检查上游 Run.swift 的 AppDelegate 生命周期，再更新补丁。" >&2
    exit 1
  fi

  export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$TART_SOURCE_DIR/.build/clang-module-cache}"
  export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$TART_SOURCE_DIR/.build/swift-module-cache}"

  swift build \
    --package-path "$TART_SOURCE_DIR" \
    -c "$CONFIG" \
    --product tart

  TART_BIN_PATH="$(swift build --package-path "$TART_SOURCE_DIR" -c "$CONFIG" --product tart --show-bin-path)"
  TART_BINARY="$TART_BIN_PATH/tart"
  restore_agent_patch
  trap - EXIT INT TERM
else
  echo "错误：没有找到 Tart 源码。请初始化 Vendor/tart，或设置 TARTUI_TART_BINARY。" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
cp "$TART_BINARY" "$OUTPUT"
chmod u+x "$OUTPUT"
echo "Tart helper：$OUTPUT"
