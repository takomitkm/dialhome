#!/usr/bin/env bash
# enroll.sh <node-name>   -- mint an identity for a NEW Windows node, on the relay.
#
# Prints (stdout) a complete PowerShell installer for that node; everything human-readable goes to
# stderr, so the caller can do:
#
#   ssh -p 18322 user@<relay> "bash ~/.magpie-connector/enroll.sh $env:COMPUTERNAME" > "$env:TEMP\enroll.ps1"
#   powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\enroll.ps1"
#
# The same two lines work on every machine; the node name comes from COMPUTERNAME, so each machine
# gets its own key and its own pair of loopback ports on the relay. Idempotent: re-running for an
# existing node reuses its key and ports instead of minting new ones.
#
# The node key is restricted to exactly two things on the relay: reverse-forward 127.0.0.1:<ssh> and
# 127.0.0.1:<magpie>. It cannot get a shell, read files, or proxy into the relay LAN.
set -eu

RAW_NAME="${1:-node}"
NAME="$(printf '%s' "$RAW_NAME" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
[ -n "$NAME" ] || NAME="node"
BASE="$HOME/.magpie-connector"
AK="$HOME/.ssh/authorized_keys"
CHECKER="$HOME/.local/bin/magpie-tunnel-check"
RELAY_HOST="${RELAY_HOST_FOR_NODE:-10.101.54.192}"
RELAY_PORT="${RELAY_PORT_FOR_NODE:-18322}"
RELAY_USER="${RELAY_USER_FOR_NODE:-user}"
PORT_BASE="${PORT_BASE:-13440}"
PORT_TOP="${PORT_TOP:-13600}"

say() { printf '%s\n' "$*" >&2; }
die() { printf 'enroll: %s\n' "$*" >&2; exit 1; }

mkdir -p "$BASE/nodes/$NAME"
chmod 700 "$BASE/nodes" "$BASE/nodes/$NAME" 2>/dev/null || true
[ -x "$CHECKER" ] || die "checker missing: $CHECKER"

used_port() {   # in authorized_keys (permitlisten) or already listening
    grep -q "permitlisten=\"127.0.0.1:$1\"" "$AK" 2>/dev/null && return 0
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "127\.0\.0\.1:$1$" && return 0
    return 1
}

# ---------- reuse an existing enrollment for this name ----------
SSH_PORT=""; MAG_PORT=""
if grep -q "magpie-node-$NAME " "$AK" 2>/dev/null; then
    line="$(grep "magpie-node-$NAME " "$AK" | head -1)"
    SSH_PORT="$(printf '%s' "$line" | grep -o 'permitlisten="127\.0\.0\.1:[0-9]*"' | head -1 | grep -o '[0-9]*')"
    MAG_PORT="$(printf '%s' "$line" | grep -o 'permitlisten="127\.0\.0\.1:[0-9]*"' | sed -n 2p | grep -o '[0-9]*')"
    say "reusing existing node '$NAME': ssh=$SSH_PORT magpie=$MAG_PORT"
fi

# ---------- or allocate a fresh pair: (base, base+1) ----------
if [ -z "$SSH_PORT" ] || [ -z "$MAG_PORT" ]; then
    p="$PORT_BASE"
    while [ "$p" -lt "$PORT_TOP" ]; do
        if ! used_port "$p" && ! used_port $((p+1)); then
            MAG_PORT="$p"; SSH_PORT=$((p+1)); break
        fi
        p=$((p+2))
    done
    [ -n "$SSH_PORT" ] || die "no free port pair below $PORT_TOP"
    say "allocated node '$NAME': magpie=$MAG_PORT ssh=$SSH_PORT"
fi

# ---------- key pair (generated here: Windows ssh-keygen mangles empty passphrases) ----------
KEY="$BASE/nodes/$NAME/node_key"
if [ ! -f "$KEY" ]; then
    rm -f "$KEY" "$KEY.pub"
    ssh-keygen -q -t ed25519 -N '' -C "magpie-node-$NAME" -f "$KEY"
    chmod 600 "$KEY"; chmod 644 "$KEY.pub"
fi
PUB="$(cat "$KEY.pub")"

# ---------- authorized_keys: one restricted line, two allowed listen ports ----------
if ! grep -q "magpie-node-$NAME " "$AK" 2>/dev/null; then
    cp -a "$AK" "$AK.bak-enroll-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    {
        printf 'restrict,command="%s %s",port-forwarding' "$CHECKER" "$SSH_PORT"
        printf ',permitlisten="127.0.0.1:%s",permitlisten="127.0.0.1:%s"' "$SSH_PORT" "$MAG_PORT"
        printf ',permitopen="127.0.0.1:1" %s\n' "$PUB"
    } >> "$AK"
    chmod 600 "$AK"
    say "authorized_keys: node '$NAME' restricted to 127.0.0.1:$SSH_PORT + :$MAG_PORT"
else
    say "authorized_keys: already present for '$NAME'"
fi

# ---------- emit the installer (stdout only) ----------
# Everything is embedded inline: the node key AND the enroll key, so the node never asks for
# the 102 password and can still pull the OpenSSH zip through the enroll gate if GitHub is slow.
SSHSERVER="$BASE/sshserver.ps1"
[ -f "$SSHSERVER" ] || die "sshserver.ps1 missing on the relay: $SSHSERVER (copy it from the repo)"
SSHSERVER_B64="$(base64 -w0 "$SSHSERVER")"
KEY_B64="$(base64 -w0 "$KEY")"
EK_B64=''
[ -f "$HOME/.ssh/dialhome_enroll" ] && EK_B64="$(base64 -w0 "$HOME/.ssh/dialhome_enroll")"
cat <<EOF
\$ErrorActionPreference = 'Continue'
\$KeyB64 = '$KEY_B64'
\$Src = '$SSHSERVER_B64'
\$EkB64 = '$EK_B64'
\$tmp = Join-Path \$env:TEMP 'sshserver.ps1'
[IO.File]::WriteAllBytes(\$tmp, [Convert]::FromBase64String(\$Src))
& powershell -NoProfile -ExecutionPolicy Bypass -File \$tmp -KeyB64 \$KeyB64 -EnrollKeyB64 \$EkB64 -RemotePort $SSH_PORT -MagpiePort $MAG_PORT -RelayHost $RELAY_HOST -RelayPort $RELAY_PORT -RelayUser $RELAY_USER
EOF