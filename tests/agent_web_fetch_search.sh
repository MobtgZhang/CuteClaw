#!/usr/bin/env bash
# 网络 + TLS 冒烟：通过 agent-tool 的 web_fetch 访问公开搜索引擎 URL（非 API）。
# 需已 zig build；部分站点可能返回验证页，本脚本只校验 JSON ok 与 body 非空。
set -euo pipefail
BIN="${1:?用法: $0 /path/to/cuteclaw}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/projects/default"

run_fetch() {
  local url="$1"
  local max_b="${2:-16000}"
  local line
  line=$(
    printf '%s\n' "{\"tool\":\"web_fetch\",\"cache_root\":\"$TMP\",\"project\":\"default\",\"args\":{\"url\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$url"),\"max_bytes\":$max_b}}" |
      "$BIN" agent-tool 2>/dev/null | tail -n1
  )
  if ! printf '%s' "$line" | grep -q '"ok":true'; then
    echo "FAIL: $url -> $line" >&2
    return 1
  fi
  if ! printf '%s' "$line" | grep -q '"body"'; then
    echo "FAIL: no body: $url" >&2
    return 1
  fi
  echo "OK: $url"
}

run_fetch "https://www.bing.com/search?q=cuteclaw+zig" 12000
run_fetch "https://www.baidu.com/s?wd=test" 12000
exit 0
