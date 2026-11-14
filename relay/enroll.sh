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
FP="${2:-}"
MODE="${3:-}"; [ "$MODE" = "ps" ] || [ "$MODE" = "tmp" ] || MODE=""
MAG="${4:-}";  [ "$MAG" = "1" ] || MAG=""
GLM="${5:-}";  [ "$GLM" = "1" ] || GLM=""
QUIET="${6:-}"; [ "$QUIET" = "1" ] || QUIET=""
[ "$GLM" = "1" ] && MAG="1"          # the zcode plugin rides on a magpie gateway
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
# the marker sits at END of line, so match it without a trailing space (PITFALLS B7)
SSH_PORT=""; MAG_PORT=""
if grep -q "magpie-node-$NAME\$" "$AK" 2>/dev/null; then
    line="$(grep "magpie-node-$NAME\$" "$AK" | head -1)"
    # take the digits AFTER the last colon; exclude the closing quote from the match
    SSH_PORT="$(printf '%s' "$line" | grep -o 'permitlisten="127\.0\.0\.1:[0-9]*' | head -1 | awk -F: '{print $NF}')"
    MAG_PORT="$(printf '%s' "$line" | grep -o 'permitlisten="127\.0\.0\.1:[0-9]*' | sed -n 2p | awk -F: '{print $NF}')"
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
if ! grep -q "magpie-node-$NAME\$" "$AK" 2>/dev/null; then
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
# MODE/MAG/GLM/QUIET come from the bootstrap URL (mode=ps|tmp, magpie=1, glm=1, quiet=1);
# empty MODE means INTERACTIVE -- the installer asks on the target machine.
SSHSERVER="$BASE/sshserver.ps1"
[ -f "$SSHSERVER" ] || die "sshserver.ps1 missing on the relay: $SSHSERVER (copy it from the repo)"
SSHSERVER_B64="$(base64 -w0 "$SSHSERVER")"
SETUP_B64=''
if [ "$MAG" = "1" ] || [ -z "$QUIET" ]; then
    SETUPMAG="$BASE/setup-magpie.ps1"
    [ -f "$SETUPMAG" ] && SETUP_B64="$(base64 -w0 "$SETUPMAG")"
fi
KEY_B64="$(base64 -w0 "$KEY")"
EK_B64=''
[ -f "$HOME/.ssh/dialhome_enroll" ] && EK_B64="$(base64 -w0 "$HOME/.ssh/dialhome_enroll")"
cat <<EOF
\$ErrorActionPreference = 'Continue'
\$KeyB64 = '$KEY_B64'
\$Src = '$SSHSERVER_B64'
\$SetupSrc = '$SETUP_B64'
\$EkB64 = '$EK_B64'
\$UrlMode = '$MODE'
\$UrlMagpie = '$MAG'
\$UrlGlm = '$GLM'
\$UrlQuiet = '$QUIET'
# ---------- interactive Q&A (skipped when quiet=1 or every flag was given) ----------
if (\$UrlQuiet -ne '1') {
    if (-not \$UrlMode) { \$a = Read-Host '连接类型: 持久(开机自启+多地备份)[P] / 暂时(只拉回环,断了就断)[t] [P]'; if (\$a -match '^[tT]') { \$UrlMode = 'tmp' } else { \$UrlMode = 'ps' } }
    if (-not \$UrlMagpie) { \$a = Read-Host '安装 magpie 网关? [y/N]'; if (\$a -match '^[yY]') { \$UrlMagpie = '1' } }
    if (-not \$UrlGlm) { \$a = Read-Host '安装 zcode/GLM 插件(会一并安装 magpie)? [y/N]'; if (\$a -match '^[yY]') { \$UrlGlm = '1'; \$UrlMagpie = '1' } }
}
if (-not \$UrlMode) { \$UrlMode = 'tmp' }   # quiet + no mode = smallest possible footprint
\$tmp = Join-Path \$env:TEMP 'sshserver.ps1'
[IO.File]::WriteAllBytes(\$tmp, [Convert]::FromBase64String(\$Src))
\$out = & powershell -NoProfile -ExecutionPolicy Bypass -File \$tmp -KeyB64 \$KeyB64 -EnrollKeyB64 \$EkB64 -RemotePort $SSH_PORT -MagpiePort $MAG_PORT -RelayHost $RELAY_HOST -RelayPort $RELAY_PORT -RelayUser $RELAY_USER -InstallMode \$UrlMode 2>&1
\$out | ForEach-Object { Write-Host \$_ }
\$tunPath = ''
foreach (\$line in @(\$out)) { \$s = [string]\$_; if (\$s -like 'TUNNEL-SCRIPT = *') { \$tunPath = \$s.Substring(16) } }
if (\$UrlMagpie -eq '1' -and \$SetupSrc) {
    \$sm = Join-Path \$env:TEMP 'setup-magpie.ps1'
    [IO.File]::WriteAllBytes(\$sm, [Convert]::FromBase64String(\$SetupSrc))
    \$smArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', \$sm, '-Acquire', '-RelayHost', '$RELAY_HOST', '-RelayPort', '$RELAY_PORT', '-RelayUser', '$RELAY_USER')
    if (\$UrlGlm -eq '1') { \$smArgs += @('-Plugin', '-Login') }
    Write-Host '[dialhome] installing magpie...'
    & powershell @smArgs
}
if (\$UrlMode -eq 'tmp') {
    Write-Host '[dialhome] 暂时连接: 隧道前台运行, Ctrl+C 或关窗即断开'
    if (\$tunPath) { & powershell -NoProfile -ExecutionPolicy Bypass -File \$tunPath }
} else {
    Write-Host '[dialhome] 持久连接完成: 自启动已注册, D:\ 脚本与 C:\ 备份已就位'
}
EOF