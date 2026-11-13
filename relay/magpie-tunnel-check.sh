#!/usr/bin/env bash
# magpie-tunnel-check <port>
# Forced command for a restricted connector key:
#   restrict,command=".../magpie-tunnel-check <port>",port-forwarding,permitlisten="127.0.0.1:<port>"
# Runs only when the client opens a session (no -N); prints ONE line of JSON.
# It reports (a) whether the reverse tunnel listener exists and is loopback-bound,
# (b) whether this host can actually speak magpie through it.
#
# `register` (SSH_ORIGINAL_COMMAND): the node reports its hardware identity
#   (Win32_ComputerSystemProduct.UUID, MAC addresses, Windows account) right after
#   install, so the relay can tell machines apart by hardware instead of IP/DHCP.
#   The node can only write uuid/macs/user into ITS OWN record (found by the port
#   baked into its authorized_keys line) -- nothing else.
set -u

orig="${SSH_ORIGINAL_COMMAND:-}"

case "$orig" in
  GET:win-sshd) base64 -w0 "$HOME/.magpie-connector/win-sshd.ps1"; echo; exit 0 ;;
  GET:migrate)  base64 -w0 "$HOME/.magpie-connector/migrate-to-D.ps1"; echo; exit 0 ;;
esac

if printf '%s' "$orig" | grep -q '^register '; then
  port="${1:-}"
  payload="$(printf '%s' "$orig" | sed 's/^register //')"
  # PowerShell->ssh may hand us backslash-escaped quotes; undo them
  payload="${payload//\\\"/\"}"
  printf '%s' "$payload" | grep -qE '^\{.*\}$' || { printf '{"ok":false,"reason":"bad-payload"}\n'; exit 0; }
  [ ${#payload} -le 2000 ] || { printf '{"ok":false,"reason":"payload-too-large"}\n'; exit 0; }
  # which node is calling? the port is baked into its own authorized_keys line
  name="$(grep "check ${port}" "$HOME/.ssh/authorized_keys" 2>/dev/null | grep -oE '(magpie-node-[a-z0-9-]+|magpie-tunnel-node-[0-9]+)' | head -1)"
  [ -n "$name" ] || { printf '{"ok":false,"reason":"unknown-caller"}\n'; exit 0; }
  # machines.json is keyed by the BARE node name (same space as bootstrap fp lookup)
  name="${name#magpie-node-}"; name="${name#magpie-tunnel-node-}"
  MF="$HOME/.magpie-connector/machines.json"
  MK="$HOME/.magpie-connector/machines.json.lock"
  flock "$MK" python3 - "$name" "$payload" <<'PY'
import json, sys, os, time
name, payload = sys.argv[1], json.loads(sys.argv[2])
f = os.path.expanduser('~/.magpie-connector/machines.json')
m = json.load(open(f, encoding='utf-8')) if os.path.exists(f) else {}
r = m.setdefault(name, {})
for k in ('uuid', 'macs', 'user'):
    if k in payload:
        r[k] = str(payload[k])[:200]
r['reported_at'] = time.strftime('%Y-%m-%dT%H:%M:%S')
json.dump(m, open(f, 'w', encoding='utf-8'), indent=1)
print('{"ok":true}')
PY
  exit 0
fi

port="${1:-}"
if ! printf '%s' "$port" | grep -qE '^[0-9]{2,5}$'; then
  printf '{"ok":false,"reason":"bad-port-argument"}\n'
  exit 0
fi

bind="127.0.0.1:${port}"

# every listener on that port, as "addr:port" strings
listeners="$(ss -ltn 2>/dev/null | awk '{print $4}' | grep -E ":${port}$" | sort -u | tr '\n' ' ')"
if [ -z "${listeners// /}" ]; then
  printf '{"ok":false,"reason":"no-listener","port":%s}\n' "$port"
  exit 0
fi
if [ "$(printf '%s' "$listeners" | tr -d ' ')" != "$bind" ]; then
  printf '{"ok":false,"reason":"wrong-bind","port":%s,"listeners":"%s"}\n' "$port" "$(printf '%s' "$listeners" | sed 's/ $//')"
  exit 0
fi

body="$(curl -s -m 5 --noproxy '*' "http://${bind}/api/hello" 2>/dev/null)"
ver="$(printf '%s' "$body" | tr -d '\n' | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
if printf '%s' "$body" | grep -q '"name"[[:space:]]*:[[:space:]]*"magpie"'; then
  printf '{"ok":true,"listen":"%s","magpie":true,"version":"%s"}\n' "$bind" "${ver:-unknown}"
  exit 0
fi

snippet="$(printf '%s' "$body" | tr -d '\n' | cut -c1-160 | sed 's/\\/\\\\/g; s/"/\\"/g')"
printf '{"ok":false,"reason":"not-magpie","listen":"%s","body":"%s"}\n' "$bind" "$snippet"
exit 0
