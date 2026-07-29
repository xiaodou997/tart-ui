#!/bin/bash
#
# 把任意图片设为应用图标。
#
# 用法：./scripts/set-icon.sh 我的图标.png
#
# 会自动处理成 macOS Big Sur 之后的图标规范：正方形、圆角、四周留白。
# 处理结果写入 Resources/icon.png，之后跑 install.sh 就会用上。
#
# 如果你的图已经是设计好的成品（自带圆角和留白），加 --raw 跳过处理：
#   ./scripts/set-icon.sh --raw 我的图标.png

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Resources/icon.png"

RAW=false
if [ "${1:-}" = "--raw" ]; then
  RAW=true
  shift
fi

SRC="${1:-}"
if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
  echo "用法：$0 [--raw] <图片路径>" >&2
  exit 1
fi

mkdir -p "$ROOT/Resources"

if [ "$RAW" = true ]; then
  echo "==> 直接使用原图（跳过圆角处理）"
  sips -z 1024 1024 "$SRC" --out "$DEST" >/dev/null
  echo "已更新 $DEST"
  echo "运行 ./scripts/install.sh 应用新图标。"
  exit 0
fi

if ! command -v magick >/dev/null 2>&1; then
  echo "未安装 ImageMagick，改为直接缩放（不加圆角）。"
  echo "如需圆角效果：brew install imagemagick"
  sips -z 1024 1024 "$SRC" --out "$DEST" >/dev/null
  echo "已更新 $DEST"
  exit 0
fi

# Big Sur 图标规范：底板占画布 80%，圆角半径约为底板边长的 22.37%。
CANVAS=1024
PLATE=824
RADIUS=184

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 裁成正方形并缩放"
# ^ 表示按最小边填满，再居中裁切，避免非正方形图片被拉变形。
magick "$SRC" -resize "${PLATE}x${PLATE}^" -gravity center -extent "${PLATE}x${PLATE}" \
  "$WORK/plate.png"

echo "==> 应用圆角"
# 遮罩必须是黑底白形：CopyOpacity 按亮度取不透明度，白=保留、黑=透明。
# 用 xc:none 起底会得到全黑遮罩（-draw 默认填充色是黑），成图会整个透明。
magick -size "${PLATE}x${PLATE}" xc:black -fill white \
  -draw "roundrectangle 0,0,$((PLATE - 1)),$((PLATE - 1)),$RADIUS,$RADIUS" \
  "$WORK/mask.png"
magick "$WORK/plate.png" "$WORK/mask.png" -alpha off -compose CopyOpacity -composite \
  "$WORK/rounded.png"

echo "==> 四周留白"
magick "$WORK/rounded.png" -background none -gravity center \
  -extent "${CANVAS}x${CANVAS}" "$DEST"

echo ""
echo "已更新 $DEST"
echo "运行 ./scripts/install.sh 应用新图标。"
