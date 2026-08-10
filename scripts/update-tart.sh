#!/bin/bash
#
# 将 Vendor/tart 更新到上游最新稳定 tag。
#
# 这个脚本只移动 submodule 指针，不改 Tart 源码。构建时的 Agent 集成补丁由
# build-tart-helper.sh 临时应用并自动恢复。通常由 GitHub Actions 定期调用，
# 生成一个可审查的 PR；也可以在本地手动指定版本：
#   ./scripts/update-tart.sh 2.35.0

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBMODULE="$ROOT/Vendor/tart"

if [ ! -f "$SUBMODULE/Package.swift" ]; then
  git -C "$ROOT" submodule update --init Vendor/tart
fi

if ! git -C "$SUBMODULE" diff --quiet || ! git -C "$SUBMODULE" diff --cached --quiet; then
  echo "错误：Vendor/tart 有未提交改动，请先清理后再更新。" >&2
  exit 1
fi

git -C "$SUBMODULE" fetch --tags --prune origin

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  TARGET="$(git -C "$SUBMODULE" tag --list '[0-9]*' --sort=-version:refname | head -1)"
fi

if [ -z "$TARGET" ]; then
  echo "错误：没有找到 Tart 稳定版本 tag。" >&2
  exit 1
fi

git -C "$SUBMODULE" show-ref --verify --quiet "refs/tags/$TARGET" || {
  echo "错误：Tart tag 不存在：$TARGET" >&2
  exit 1
}

CURRENT="$(git -C "$SUBMODULE" rev-parse HEAD)"
git -C "$SUBMODULE" checkout --detach "$TARGET"
UPDATED="$(git -C "$SUBMODULE" rev-parse HEAD)"

if [ "$CURRENT" = "$UPDATED" ]; then
  echo "Tart 已经是 $TARGET（$UPDATED）"
else
  echo "Tart 已更新：$CURRENT -> $TARGET（$UPDATED）"
fi

echo "请审查并提交 submodule 指针：git add Vendor/tart"
