#!/usr/bin/env bash
# CLI 冒烟：init → export → import → config validate → working / fact
set -euo pipefail
BIN="${1:?用法: $0 /path/to/cuteclaw}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CUTECLAW_STORE="$TMP/store.json"
export CUTECLAW_CONFIG="$TMP/config.json"
"$BIN" init
"$BIN" status
"$BIN" config init
"$BIN" config validate
"$BIN" export >"$TMP/e.json"
"$BIN" import <"$TMP/e.json"
"$BIN" working set goal "smoke_goal"
"$BIN" working show
"$BIN" fact add smoke_key "smoke value"
printf '%s\n' '{"skill_name":"smoke_skill","patch_summary":"patch summary here","new_body":"12345678"}' >"$TMP/good_prop.json"
"$BIN" validate --file "$TMP/good_prop.json"
# 过短的 proposal 应失败（退出码 1）
printf '%s\n' '{"skill_name":"x","patch_summary":"yyyy","new_body":"short"}' >"$TMP/bad.json"
if "$BIN" validate --file "$TMP/bad.json" 2>/dev/null; then exit 1; fi
exit 0
