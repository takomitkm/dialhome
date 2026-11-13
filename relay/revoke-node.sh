#!/usr/bin/env bash
# revoke-node.sh <node-name> [remote-port]
# Remove one node from the relay: its authorized_keys line and its key/payload directory.
# Idempotent. Matches both enrollment schemes:
#   enroll.sh  -> marker "magpie-node-<name>"
#   pack-node  -> marker "magpie-tunnel-node-<port>"
set -eu
node="${1:?node name}"
port="${2:-}"
AK="$HOME/.ssh/authorized_keys"
BASE="$HOME/.magpie-connector"
MF2="$BASE/machines.json"
stamp="$(date +%Y%m%d-%H%M%S)"

echo "=== authorized_keys ==="
removed=0
if [ -f "$AK" ]; then
    tmp="$(mktemp)"
    # the marker sits at end-of-line, so match "marker$" as well as "marker "
    if [ -n "$port" ]; then
        grep -v -e "magpie-node-${node}\$" -e "magpie-node-${node} " -e "magpie-tunnel-node-${port}" "$AK" > "$tmp" || true
    else
        grep -v -e "magpie-node-${node}\$" -e "magpie-node-${node} " "$AK" > "$tmp" || true
    fi
    if ! cmp -s "$AK" "$tmp"; then
        cp -a "$AK" "$AK.bak-revoke-$stamp"
        install -m 0600 "$tmp" "$AK"; removed=1
        echo "  removed node '$node'${port:+ (port $port)}  backup: $AK.bak-revoke-$stamp"
    else
        echo "  nothing matched for '$node'"
    fi
    rm -f "$tmp"
fi
echo "  managed lines left: $(grep -c -e 'magpie-node-' -e 'magpie-tunnel-node-' "$AK" 2>/dev/null || echo 0)"

echo "=== node directory ==="
if [ -d "$BASE/nodes/$node" ]; then
    find "$BASE/nodes/$node" -type f -exec shred -u {} \; 2>/dev/null || true
    rm -rf "$BASE/nodes/$node"
    echo "  removed $BASE/nodes/$node (key shredded)"
else
    echo "  $BASE/nodes/$node absent"
fi

echo "=== machines.json entry ==="
python3 - "$node" "$MF2" <<'PY'
import json, os, sys
name, f = sys.argv[1], sys.argv[2]
if not os.path.exists(f):
    print('  no machines.json'); raise SystemExit
m = json.load(open(f, encoding='utf-8'))
if name in m:
    del m[name]
    json.dump(m, open(f, 'w', encoding='utf-8'), indent=1)
    print('  removed', name)
else:
    print('  absent:', name)
PY

echo "=== listeners ==="
if [ -n "$port" ]; then ss -ltn | grep ":${port} " || echo "  none on $port"
else ss -ltn | grep -E ':(134[0-9][0-9]) ' || echo "  no node listeners"; fi

echo "=== forced commands still configured ==="
grep -o 'command="[^"]*"' "$AK" 2>/dev/null | sed 's/^/  /' || echo "  (none)"