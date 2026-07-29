#!/bin/bash
#
# 打包脚本的共用函数。

# 挑选代码签名身份。
#
# 优先级：
#   1. 环境变量 TARTPRO_SIGN_IDENTITY 指定的身份（手动覆盖）
#   2. Developer ID Application —— 唯一适合独立分发的证书。
#      配合公证后，别人下载也不会被 Gatekeeper 拦。
#   3. 临时签名（ad-hoc）—— 本机自用完全够用。
#
# **刻意跳过 Apple Development 和 Apple Distribution 证书。** 它们签出来的应用
# 需要配套的描述文件（embedded.provisionprofile）才能启动，直接用会导致
# launchd 拒绝加载，报 "Launch failed / Launchd job spawn failed"（错误 163）。
# 那两张证书是给 Xcode 走完整签名流程用的，不适合这种脚本化打包。
#
# 用证书指纹而不是名称来签名：同一个开发者账号常有多张同名证书
# （比如换机器时重新申请过），codesign 遇到重名会报 ambiguous 直接失败。
#
# 结果写入全局变量 SIGN_IDENTITY（指纹）和 SIGN_DESCRIPTION（供显示）。
detect_signing_identity() {
  if [ -n "${TARTPRO_SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$TARTPRO_SIGN_IDENTITY"
    SIGN_DESCRIPTION="手动指定：$SIGN_IDENTITY"
    return
  fi

  local identities
  # grep 找不到匹配会返回非零；调用方开了 set -e 和 pipefail，
  # 不加 || true 的话「没有这类证书」会直接让脚本中断。
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

  _pick_identity "Developer ID Application" "Developer ID（可分发给他人，建议再做公证）" "$identities" && return

  SIGN_IDENTITY="-"
  SIGN_DESCRIPTION="临时签名（本机可用；要分发给他人需申请 Developer ID 证书）"
}

# 从 security 的输出里挑出指定类型的第一张证书。
#
# 输出行形如：  1) <40位指纹> "Apple Development: 姓名 (TEAMID)"
_pick_identity() {
  local pattern="$1"
  local description="$2"
  local identities="$3"

  local line
  line="$(echo "$identities" | grep "$pattern" | head -1 || true)"
  [ -n "$line" ] || return 1

  local fingerprint
  fingerprint="$(echo "$line" | awk '{print $2}')"
  [ -n "$fingerprint" ] || return 1

  local name
  name="$(echo "$line" | sed 's/.*"\(.*\)"/\1/')"

  SIGN_IDENTITY="$fingerprint"
  SIGN_DESCRIPTION="$description — $name"
  return 0
}
