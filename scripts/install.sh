#!/bin/bash
#
# 构建 release 版本并安装到「应用程序」文件夹。
#
# 装完后就是一个普通的 macOS 应用：可以从启动台、聚焦搜索（Cmd+空格）打开，
# 也可以拖到程序坞常驻。
#
# 用法：./scripts/install.sh

set -euo pipefail

APP_NAME="TartUI"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 优先装到 /Applications；没有写权限就退回用户自己的 ~/Applications，
# 避免为了装一个自用工具还要输密码。
if [ -w "/Applications" ]; then
  DEST_DIR="/Applications"
else
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
fi

DEST="$DEST_DIR/$APP_NAME.app"

echo "==> 构建 release 版本"
"$ROOT/scripts/bundle.sh" release

BIN_PATH="$(swift build -c release --product "$APP_NAME" --arch arm64 --show-bin-path)"
BUILT_APP="$BIN_PATH/$APP_NAME.app"

if [ ! -d "$BUILT_APP" ]; then
  echo "错误：没有找到构建产物 $BUILT_APP" >&2
  exit 1
fi

# 应用正在运行的话先退出，否则替换会失败或留下半新半旧的文件。
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "==> 关闭正在运行的 $APP_NAME"
  osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || pkill -x "$APP_NAME" || true
  sleep 2
fi

echo "==> 安装到 $DEST"
rm -rf "$DEST"
cp -R "$BUILT_APP" "$DEST"

# 把 .build 里的构建产物从启动服务数据库中注销。
# 否则系统里存在多个同名应用，`open -a TartUI` 和聚焦搜索可能命中构建目录里
# 那个临时版本，而不是这里刚装好的。
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  for stale in "$ROOT/.build"/*/debug/"$APP_NAME.app" "$ROOT/.build"/*/release/"$APP_NAME.app"; do
    [ -d "$stale" ] && "$LSREGISTER" -u "$stale" 2>/dev/null || true
  done
  # 注册新装的这个，让启动台和聚焦搜索立刻能找到。
  "$LSREGISTER" -f "$DEST" 2>/dev/null || true
fi

# 不要在这里重新签名。签名信息就存在文件内容里，cp -R 会原样带过来；
# 再签一次只会把 bundle.sh 用正式证书做的签名覆盖掉。
echo "==> 校验签名"
if codesign --verify --deep --strict "$DEST" 2>/dev/null; then
  AUTHORITY="$(codesign -dv --verbose=2 "$DEST" 2>&1 | grep "^Authority=" | head -1 | cut -d= -f2-)"
  echo "    通过：${AUTHORITY:-临时签名}"
else
  echo "    警告：签名校验未通过，应用可能无法启动"
fi

echo ""
echo "安装完成：$DEST"
echo ""
echo "启动方式："
echo "  · 启动台里找 $APP_NAME"
echo "  · 聚焦搜索：Cmd+空格，输入 $APP_NAME"
echo "  · 命令行：open -a $APP_NAME"
echo ""
echo "想常驻程序坞：启动后右键程序坞图标 → 选项 → 在程序坞中保留。"
