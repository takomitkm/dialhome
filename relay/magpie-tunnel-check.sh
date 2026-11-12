#!/usr/bin/env bash
# magpie-tunnel-check <port>
# Forced command for a restricted connector key:
#   restrict,command="/home/user/.local/bin/magpie-tunnel-check 13425",port-forwarding,permitlisten="127.0.0.1:13425"
# Runs only when the client opens a session (no -N); prints ONE line of JSON.
# It reports (a) whether the reverse tunnel listener exists and is loopback-bound,
# (b) whether this host can actually speak magpie through it.
#
# Onboarding helper: a whitelisted file can be fetched as base64 by asking for
#   GET:win-sshd   -> win-sshd.ps1
#   GET:migrate    -> migrate-to-D.ps1
# (sshd exports $SSH_ORIGINAL_COMMAND for forced commands; a normal probe has none.)
set -u

case "${SSH_ORIGINAL_COMMAND:-}" in
  GET:win-sshd) base64 -w0 "$HOME/.magpie-connector/win-sshd.ps1"; echo; exit 0 ;;
  GET:migrate)  base64 -w0 "$HOME/.magpie-connector/migrate-to-D.ps1"; echo; exit 0 ;;
esac

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
