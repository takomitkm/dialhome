#!/usr/bin/env bash
# revoke-node.sh <node> <remotePort>
# Removes one provisioned node from the relay: its authorized_keys line and its payload dir.
# Idempotent. Reusable tooling (checker / verify / add-provider / magpie exe) is untouched.
set -eu
node="${1:?node name}"; port="${2:?remote port}"
AK="$HOME/.ssh/authorized_keys"
base="$HOME/.magpie-connector"
stamp="$(date +%Y%m%d-%H%M%S)"

echo "=== authorized_keys ==="
if grep -q "magpie-tunnel-node-${port}" "$AK" 2>/dev/null; then
  cp -a "$AK" "$AK.bak-revoke-$stamp"
  tmp="$(mktemp)"
  grep -v "magpie-tunnel-node-${port}" "$AK" > "$tmp" || true
  install -m 0600 "$tmp" "$AK"; rm -f "$tmp"
  echo "  removed node-${port} (backup: $AK.bak-revoke-$stamp)"
else
  echo "  node-${port} not present"
fi
echo "  managed lines left: $(grep -c 'magpie-tunnel-node-' "$AK" || true)"

echo "=== payload dir ==="
if [ -d "$base/nodes/$node" ]; then
  shred -u "$base/nodes/$node/payload.b64" 2>/dev/null || true
  rm -rf "$base/nodes/$node"
  echo "  removed $base/nodes/$node"
else
  echo "  $base/nodes/$node absent"
fi
echo "=== listeners on $port ==="
ss -ltn | grep ":${port} " || echo "  none"

echo "=== security check: does the relay still offer a shell to anything node-ish? ==="
grep -o 'command="[^"]*"' "$AK" | sed 's/^/  /' || echo "  (no forced commands left)"