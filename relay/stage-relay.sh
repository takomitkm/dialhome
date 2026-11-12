#!/usr/bin/env bash
# Runs ON 102 (as user 'user'). Installs the forced-command checker and the
# restricted connector keys. Idempotent: previous magpie-tunnel entries are
# replaced, never appended twice.
#
# Inputs (already uploaded by the caller):
#   /tmp/mt-check.sh        the checker script
#   /tmp/mt-keys/*.pub      one "ssh-ed25519 AAAA... comment" per node
#   /tmp/mt-keys/*.port     matching port number for each node (same basename)
set -eu

check_src=/tmp/mt-check.sh
keydir=/tmp/mt-keys
bin="$HOME/.local/bin"
checker="$bin/magpie-tunnel-check"
ak="$HOME/.ssh/authorized_keys"
marker='magpie-tunnel-node'

mkdir -p "$bin" "$HOME/.ssh"
install -m 0755 "$check_src" "$checker"

touch "$ak"
chmod 600 "$ak"
cp -a "$ak" "$ak.bak-magpietunnel.$(date +%Y%m%d%H%M%S)"

tmp="$(mktemp)"
# keep everything that is not one of our managed entries
grep -v -- "$marker" "$ak" > "$tmp" || true

shopt -s nullglob
count=0
for pub in "$keydir"/*.pub; do
  port_file="${pub%.pub}.port"
  [ -f "$port_file" ] || { echo "SKIP $pub (no .port)"; continue; }
  port="$(tr -dc '0-9' < "$port_file")"
  key="$(tr -d '\r\n' < "$pub")"
  printf 'restrict,command="%s %s",port-forwarding,permitlisten="127.0.0.1:%s" %s %s\n' \
    "$checker" "$port" "$port" "$key" "$marker-$port" >> "$tmp"
  count=$((count + 1))
done
chown "$(id -u):$(id -g)" "$tmp"
install -m 0600 "$tmp" "$ak"
rm -f "$tmp"

echo "installed checker: $checker"
echo "managed keys now: $count"
echo "--- authorized_keys (managed lines, key body elided) ---"
awk -v m="$marker" '$0 ~ m { n=split($0,a," "); printf "%s ... %s (key=%s)\n", substr($0,1,index($0,"ssh-")-1), a[n], substr(a[n-1],1,24) }' "$ak"
echo "--- checker self-run ---"
"$checker" 13425 || true
