#!/usr/bin/env bash
# verify the campus-node reverse tunnel end-to-end on 102.
# Usage: verify-tunnel.sh [PORT]   (default 13425)
set -u
PORT="${1:-13425}"
bind="127.0.0.1:${PORT}"
echo "### 1. reverse listener on 102 (must be 127.0.0.1, not 0.0.0.0)"
ss -ltn 2>/dev/null | awk -v p=":${PORT}\$" '$4 ~ p {print "  "$4}'
echo "    (expect exactly: 127.0.0.1:${PORT})"
echo
echo "### 2. forced-command probe (the connector's online test)"
/home/user/.local/bin/magpie-tunnel-check "$PORT"
echo
echo "### 3. curl the Windows magpie gateway THROUGH the tunnel"
curl -s -m 6 --noproxy '*' "http://${bind}/api/hello" && echo
echo
echo "### 4. 102 gateway: how many models does the 'win' provider expose?"
curl -s -m 10 --noproxy '*' http://127.0.0.1:3425/v1/models | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); ids=[m.get("id","?") for m in d.get("data",[])]
    wins=[i for i in ids if i.startswith("win/")]
    print("  total", len(ids), "| win*:", wins)
except Exception as e:
    print("  parse-fail", e)'
echo
echo "### 5. loopback listeners that should NOT exist (0.0.0.0 / [::])"
ss -ltn 2>/dev/null | awk -v p=":${PORT}\$" '$4 ~ p {print "  "$4}' | grep -E '0\.0\.0\.0|\[::\]' || echo "  none -- good"
