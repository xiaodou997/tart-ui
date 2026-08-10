#!/bin/bash
#
# 打包脚本的共用函数。

# 挑选代码签名身份。
#
# 优先级：
#   1. 环境变量 TARTUI_SIGN_IDENTITY 指定的身份（手动覆盖）
#   2. Developer ID Application —— 唯一适合独立分发的证书。
#      配合公证后，别人下载也不会被 Gatekeeper 拦。
#   3. debug 构建如果检测到匹配 Profile，自动选择 Apple Development。
#   4. 临时签名（ad-hoc）—— 本机自用完全够用。
#
# 自动选择时刻意跳过 Apple Development 和 Apple Distribution 证书。它们签出来的
# 应用需要配套的描述文件（embedded.provisionprofile）；如果要在脚本中使用，
# 请通过 TARTUI_SIGN_IDENTITY 显式指定，并同时提供匹配的 Profile。
#
# 用证书指纹而不是名称来签名：同一个开发者账号常有多张同名证书
# （比如换机器时重新申请过），codesign 遇到重名会报 ambiguous 直接失败。
#
# 结果写入全局变量 SIGN_IDENTITY（指纹）和 SIGN_DESCRIPTION（供显示）。
detect_signing_identity() {
  if [ -n "${TARTUI_SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$TARTUI_SIGN_IDENTITY"
    SIGN_DESCRIPTION="手动指定：$SIGN_IDENTITY"
    return
  fi

  local identities
  # grep 找不到匹配会返回非零；调用方开了 set -e 和 pipefail，
  # 不加 || true 的话「没有这类证书」会直接让脚本中断。
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

  _pick_identity "Developer ID Application" "Developer ID（可分发给他人，建议再做公证）" "$identities" && return

  if [ "${TARTUI_SIGNING_CONFIGURATION:-}" = "debug" ] \
    && [ -n "${TARTUI_PROJECT_ROOT:-}" ] \
    && find_tart_provisioning_profile "$TARTUI_PROJECT_ROOT" >/dev/null 2>&1; then
    _pick_identity "Apple Development" "Apple Development（本机调试，使用匹配的 provisioning profile）" "$identities" && return
  fi

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

# 找到与 TartUI helper App ID 匹配的 provisioning profile。
#
# 优先使用 TARTUI_TART_PROVISION_PROFILE；没有显式指定时，扫描 Xcode 和系统的
# 本地 profile 缓存。这样 profile 更新后不需要把 UUID 写死在脚本里。
find_tart_provisioning_profile() {
  local project_root="$1"
  local explicit_profile="${TARTUI_TART_PROVISION_PROFILE:-}"

  if [ -n "$explicit_profile" ]; then
    case "$explicit_profile" in
      ~/*) explicit_profile="${HOME:-}/${explicit_profile#~/}" ;;
    esac
    [ -f "$explicit_profile" ] || return 1
    printf '%s\n' "$explicit_profile"
    return 0
  fi

  local user_home="${HOME:-}"
  local profile_roots=("$project_root/Resources")
  if [ -n "$user_home" ]; then
    profile_roots+=(
      "$user_home/Library/MobileDevice/Provisioning Profiles"
      "$user_home/Library/Developer/Xcode/UserData/Provisioning Profiles"
    )
  fi

  local root candidate decoded_profile application_identifier
  for root in "${profile_roots[@]}"; do
    [ -d "$root" ] || continue
    while IFS= read -r -d '' candidate; do
      decoded_profile="$(mktemp "${TMPDIR:-/tmp}/tartui-profile.XXXXXX")"
      if security cms -D -i "$candidate" -o "$decoded_profile" >/dev/null 2>&1; then
        application_identifier="$(
          /usr/libexec/PlistBuddy \
            -c 'Print :Entitlements:com.apple.application-identifier' \
            "$decoded_profile" 2>/dev/null || true
        )"
        rm -f "$decoded_profile"
        if [[ "$application_identifier" == *.com.tartui.tart-helper ]]; then
          printf '%s\n' "$candidate"
          return 0
        fi
      else
        rm -f "$decoded_profile"
      fi
    done < <(
      find "$root" -maxdepth 1 -type f \
        \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) \
        -print0 2>/dev/null
    )
  done

  return 1
}
