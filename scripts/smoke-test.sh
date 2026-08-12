#!/bin/bash
#
# 冒烟测试：确认虚拟机能起来、能稳定运行、能正常关机。
#
# 存在的理由很具体：进程内运行时曾经因为宿主版本号是未替换的占位符，导致
# 客户机每隔十几秒重启一次。那个缺陷不影响编译、不影响启动、配置也完全正常，
# 唯一的症状是「跑一会儿就重启」——只有真的跑起来看一段时间才能发现。
#
# 判据是 nvram 的写入次数。nvram 只在开关机时写，所以稳定运行的虚拟机在启动
# 之后就不该再动它；持续写入即表示客户机在反复重启。
#
# 用法：./scripts/smoke-test.sh [观察秒数]
#
# 需要 TartVMProbe（swift build -c release --product TartVMProbe）并已签名。

set -euo pipefail

DURATION="${1:-120}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VM_NAME="tartui-smoke-$$"
BASE_IMAGE="${TARTUI_SMOKE_IMAGE:-ghcr.io/cirruslabs/macos-sequoia-base:latest}"
PROBE="$ROOT/.build/arm64-apple-macosx/release/TartVMProbe"

if [ ! -x "$PROBE" ]; then
  echo "错误：找不到 TartVMProbe，请先执行：" >&2
  echo "      swift build -c release --product TartVMProbe" >&2
  exit 1
fi

TART="${TARTUI_TART_BINARY:-$(command -v tart || true)}"
if [ -z "$TART" ]; then
  echo "错误：需要 tart 命令行来准备测试虚拟机" >&2
  exit 1
fi

cleanup() {
  [ -n "${PROBE_PID:-}" ] && kill "$PROBE_PID" 2>/dev/null || true
  sleep 3
  [ -n "${PROBE_PID:-}" ] && kill -9 "$PROBE_PID" 2>/dev/null || true
  "$TART" delete "$VM_NAME" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "==> 克隆测试虚拟机（写时复制，几乎不占空间）"
"$TART" clone "$BASE_IMAGE" "$VM_NAME"

echo "==> 启动（观察 ${DURATION}s）"
"$PROBE" "$VM_NAME" >/dev/null 2>&1 &
PROBE_PID=$!

NVRAM="$HOME/.tart/vms/$VM_NAME/nvram.bin"
sleep 20  # 留出启动时间，此间的 nvram 写入是正常的

PREV=""
CHANGES=0
ELAPSED=0
while [ "$ELAPSED" -lt "$DURATION" ]; do
  if ! kill -0 "$PROBE_PID" 2>/dev/null; then
    echo "失败：虚拟机进程在观察期内退出" >&2
    exit 1
  fi

  CURRENT="$(stat -f '%m' "$NVRAM" 2>/dev/null || echo "")"
  if [ -n "$PREV" ] && [ "$CURRENT" != "$PREV" ]; then
    CHANGES=$((CHANGES + 1))
    echo "    [${ELAPSED}s] nvram 变化（累计 ${CHANGES}）"
  fi
  PREV="$CURRENT"

  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

echo "==> 观察结束：nvram 变化 ${CHANGES} 次"
if [ "$CHANGES" -gt 1 ]; then
  echo "失败：客户机在反复重启。" >&2
  echo "      常见原因是宿主版本号不正确——客户机的 guest agent 会读取" >&2
  echo "      console 设备名里的宿主版本做特性检查。请检查" >&2
  echo "      Sources/TartVMCore/TartVersion.swift 与 Vendor/tart 是否一致。" >&2
  exit 1
fi

echo "==> 通过：虚拟机稳定运行 ${DURATION}s"
