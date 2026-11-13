#!/usr/bin/env bash
# make-enroll-key.sh -- create/refresh the passwordless ENROLLMENT key, then print the
# one-paste installer block for new machines (captured to a file, never needed on screen).
#
#   bash make-enroll-key.sh                 # idempotent: creates key + authorized_keys line
#
# Output (stdout) is a PowerShell block, "the magic paste". It embeds the ENROLL PRIVATE KEY
# (base64) so a brand-new machine needs ZERO 102 passwords:
#   enroll (via the gate) -> mint per-node key/ports -> run the embedded sshserver.ps1.
#
# Scope of the enroll key, if it leaks: it can mint more node entries (spam until you delete the
# "dialhome-enroll-gate" line) and dump three PUBLIC files. No shell, no files of yours, no LAN.
set -eu
BASE="$HOME/.magpie-connector"
AK="$HOME/.ssh/authorized_keys"
KEY="$HOME/.ssh/dialhome_enroll"
GATE="$BASE/enroll-gate.sh"
RELAY_HOST="${RELAY_HOST_FOR_NODE:-10.101.54.192}"
RELAY_PORT="${RELAY_PORT_FOR_NODE:-18322}"
RELAY_USER="${RELAY_USER_FOR_NODE:-user}"

[ -f "$GATE" ] || { echo "ERROR: $GATE missing (copy it from the repo)"; exit 3; }
chmod 755 "$GATE"

# ---------- key pair (idempotent) ----------
if [ ! -f "$KEY" ]; then
    ssh-keygen -q -t ed25519 -N '' -C 'dialhome-enroll-gate' -f "$KEY"
    chmod 600 "$KEY"; chmod 644 "$KEY.pub"
fi
PUB="$(cat "$KEY.pub")"

# ---------- authorized_keys line (idempotent) ----------
if ! grep -q 'dialhome-enroll-gate' "$AK" 2>/dev/null; then
    cp -a "$AK" "$AK.bak-enrollgate-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    printf 'restrict,command="bash %s",no-port-forwarding,no-pty %s\n' "$GATE" "$PUB" >> "$AK"
    chmod 600 "$AK"
    echo "authorized_keys: enroll-gate line installed (revoke = delete that line)" >&2
else
    echo "authorized_keys: enroll-gate line already present" >&2
fi

# ---------- the magic paste ----------
KEY_B64="$(base64 -w0 "$KEY")"
cat <<EOF
# dialhome -- passwordless enroll paste (works on any Windows, PowerShell 5.1)
# leak policy: this block carries a key that can only ENROLL (no shell on the relay).
# if it leaks, delete the 'dialhome-enroll-gate' line in the relay's authorized_keys.
\$ErrorActionPreference = 'Continue'
\$EkB64 = '$KEY_B64'
\$ek = Join-Path \$env:TEMP 'dialhome-enroll.key'
[IO.File]::WriteAllBytes(\$ek, [Convert]::FromBase64String(\$EkB64))
& icacls.exe \$ek /inheritance:r /grant:r ("\$env:USERDOMAIN\\\$env:USERNAME:F") | Out-Null
# hardware fingerprint: UUID first (stable across DHCP/reinstall/random-MAC), MAC set
# second, random per-Windows-install id only when a board reports neither.
\$u = (Get-CimInstance Win32_ComputerSystemProduct -EA 0).UUID
if (-not \$u -or \$u -match '^(none|0{8}(-0{4}){3}-0{12}|0+)\$') { \$u = '' }
\$ms = ((Get-NetAdapter -EA 0 | Where-Object { \$_.MacAddress } | ForEach-Object { \$_.MacAddress }) | Sort-Object) -join ','
if (\$u) { \$f = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes('u|' + \$u))).Replace('-','').Substring(0,16).ToLower() }
elseif (\$ms) { \$f = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes('m|' + \$ms))).Replace('-','').Substring(0,16).ToLower() }
else { \$rk = 'HKCU:\Software\dialhome'; \$f = (Get-ItemProperty \$rk -EA 0).mid; if (-not \$f) { \$f = -join((1..8) | % { '{0:x2}' -f (Get-Random -Max 16) }); New-Item \$rk -Force | Out-Null; Set-ItemProperty \$rk -Name mid -Value \$f } }
\$name = (\$env:COMPUTERNAME.ToLower() -replace '[^a-z0-9-]','')
if (-not \$name) { \$name = 'node' }
\$name = \$name + '-' + \$f
\$inst = Join-Path \$env:TEMP 'dialhome-install.ps1'
ssh -p $RELAY_PORT -i \$ek $RELAY_USER@$RELAY_HOST "enroll \$name \$f" > \$inst
if ((Get-Item \$inst).Length -lt 2000) { Get-Content \$inst; exit 1 }
& powershell -NoProfile -ExecutionPolicy Bypass -File \$inst -EnrollKeyB64 \$EkB64
EOF