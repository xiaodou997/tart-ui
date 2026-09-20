#!/bin/bash
#
# Shared signing helpers for TartUI packaging.

detect_signing_identity() {
  if [ -n "${TARTUI_SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$TARTUI_SIGN_IDENTITY"
    SIGN_DESCRIPTION="manual: $SIGN_IDENTITY"
    return
  fi

  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

  _pick_identity "Developer ID Application" "Developer ID" "$identities" && return

  if [ "${TARTUI_SIGNING_CONFIGURATION:-}" = "debug" ]; then
    _pick_identity "Apple Development" "Apple Development" "$identities" && return
  fi

  SIGN_IDENTITY="-"
  SIGN_DESCRIPTION="ad-hoc"
}

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
