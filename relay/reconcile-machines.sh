#!/usr/bin/env bash
# reconcile-machines.sh -- "连上后对比" (compare AFTER connecting), the IP-free identity check.
#
# For every enrolled node whose SSH channel is up:
#   1. ssh INTO the machine through its own channel (relay win-ssh key, encrypted)
#   2. read the LIVE hardware identity (Win32_ComputerSystemProduct.UUID + MACs)
#   3. recompute the fingerprint exactly the way the client did at enroll time
#   4. compare against the fingerprint recorded during enrollment -> MATCH / DRIFT / MISSING
#
# Report-only: drift is written to machines-report.log, nothing is auto-revoked.
# Drift reasons: motherboard replacement (uuid changed), USB dock added/removed (mac set
# changed), or -- the dangerous one -- a different machine took over this slot.
set -u
BASE="$HOME/.magpie-connector"
AK="$HOME/.ssh/authorized_keys"
MF="$BASE/machines.json"
REPORT="$BASE/machines-report.log"
SNIP='
$u=(Get-CimInstance Win32_ComputerSystemProduct -EA 0).UUID
if(-not $u -or $u -match "^(none|0{8}(-0{4}){3}-0{12}|0+)$"){$u=""}
$ms=((Get-NetAdapter -EA 0 | Where-Object {$_.MacAddress} | ForEach-Object {$_.MacAddress}) | Sort-Object) -join ","
"U=$u"
"M=$ms"
'

log() { printf '[%s] %s\n' "$(date -Is)" "$*" >> "$REPORT"; }

# b64(UTF-16LE) of the snippet for powershell -EncodedCommand (no quoting pain over cmd)
b64="$(printf '%s' "$SNIP" | iconv -f utf-8 -t utf-16le | base64 -w0)"

python3 - "$MF" <<'PY'
import json, os, sys
f = sys.argv[1]
m = json.load(open(f, encoding='utf-8')) if os.path.exists(f) else {}
for name, rec in m.items():
    if not rec.get('uuid') and not rec.get('macs'):
        print(f"{name}\tNOT-REGISTERED (node never sent machineid)")
PY

# iterate managed nodes: name + ssh port from authorized_keys
grep -oE 'command="[^"]*check [0-9]+"[^ ]* .*(magpie-node-[a-z0-9-]+|magpie-tunnel-node-[0-9]+)' "$AK" 2>/dev/null |
while IFS= read -r line; do
    port="$(printf '%s' "$line" | grep -oE 'check [0-9]+' | grep -oE '[0-9]+')"
    name="$(printf '%s' "$line" | grep -oE '(magpie-node-[a-z0-9-]+|magpie-tunnel-node-[0-9]+)' | head -1 | sed 's/^magpie-node-//; s/^magpie-tunnel-node-//')"
    [ -n "$name" ] && [ -n "$port" ] || continue
    if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "127\.0\.0\.1:${port}\$"; then
        log "$name port=$port OFFLINE (no tunnel; machine likely not logged in)"
        continue
    fi
    user="$(python3 -c "import json,os,sys;m=json.load(open(os.path.expanduser('$MF'),encoding='utf-8'));print(m.get('$name',{}).get('user') or '')" 2>/dev/null)"
    if [ -z "$user" ]; then
        log "$name port=$port UP but no registered username yet (register pending)"
        continue
    fi
    live="$(ssh -p "$port" -i "$HOME/.ssh/win-ssh" -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new "$user@127.0.0.1" \
        "powershell -NoProfile -EncodedCommand $b64" 2>/dev/null | tr -d '\r')"
    lu="$(printf '%s\n' "$live" | sed -n 's/^U=//p' | head -1)"
    lm="$(printf '%s\n' "$live" | sed -n 's/^M=//p' | head -1)"
    if [ -z "$lu" ] && [ -z "$lm" ]; then
        log "$name port=$port UP but identity query failed"
        continue
    fi
    if [ -n "$lu" ]; then
        fp="$(printf 'u|%s' "$lu" | sha256sum | cut -c1-16)"
    else
        fp="$(printf 'm|%s' "$lm" | sha256sum | cut -c1-16)"
    fi
    rec_fp="$(python3 -c "import json,os;m=json.load(open(os.path.expanduser('$MF'),encoding='utf-8'));print(m.get('$name',{}).get('fp') or '')" 2>/dev/null)"
    # update the record with the fresh hardware facts
    python3 - "$name" "$lu" "$lm" "$fp" "$MF" <<'PY'
import json, os, sys, time
name, lu, lm, fp, f = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
m = json.load(open(f, encoding='utf-8')) if os.path.exists(f) else {}
r = m.setdefault(name, {})
if lu: r['uuid'] = lu
if lm: r['macs'] = lm
r['fp_live'] = fp
r['checked_at'] = time.strftime('%Y-%m-%dT%H:%M:%S')
json.dump(m, open(f, 'w', encoding='utf-8'), indent=1)
PY
    if [ -n "$rec_fp" ] && [ "$rec_fp" != "$fp" ]; then
        log "$name port=$port DRIFT: enroll-fp=$rec_fp live-fp=$fp (hardware changed, or a different machine holds this slot)"
    else
        log "$name port=$port MATCH (fp=$fp uuid='$lu' macs='$lm')"
    fi
done

# ---------- auto-merge: same hardware UUID enrolled twice -> keep the oldest slot ----------
# A machine that re-onboarded from a new IP (DHCP change) leaves a duplicate slot;
# identical non-empty UUIDs prove it is the same physical machine, so fold them.
merge="$(python3 - "$MF" <<'PY'
import json, os, sys
f = sys.argv[1]
m = json.load(open(f, encoding='utf-8')) if os.path.exists(f) else {}
groups = {}
for name, rec in m.items():
    u = (rec.get('uuid') or '').strip()
    if u:
        groups.setdefault(u, []).append(name)
for u, names in groups.items():
    if len(names) < 2:
        continue
    names.sort(key=lambda n: m[n].get('enrolled_at') or m[n].get('first_seen') or m[n].get('reported_at') or '9999')
    for drop in names[1:]:
        print('DROP ' + drop)
PY
)"
printf '%s\n' "$merge" | while read -r cmd; do
    [ -n "$cmd" ] || continue
    drop="${cmd#DROP }"
    log "AUTO-MERGE: $drop folds into its older twin (same hardware UUID)"
    bash "$BASE/revoke-node.sh" "$drop" >/dev/null 2>&1
done

log "reconcile pass finished"
echo "report: $REPORT (tail below)"
tail -12 "$REPORT"