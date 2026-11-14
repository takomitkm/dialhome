#!/usr/bin/env bash
# enroll-gate.sh -- forced command for the DIALHOME ENROLL KEY.
#
# The enroll key exists so a brand-new machine can enroll WITHOUT the 102 password
# (typing that password on an untrusted machine is the real risk -- a keylogger there
# captures the whole account). This gate is the ONLY thing the enroll key can run:
#
#   enroll <name>     mint an identity for <name> (delegates to enroll.sh)
#   get sshserver     dump node/sshserver.ps1           (public script)
#   get openssh       dump OpenSSH-Win64.zip           (public, sha256-pinned)
#   get magpie        dump the portable magpie exe     (public)
#
# Everything else is refused. No shell, no forwarding, no file listing.
# Revoking enrollment = delete the "dialhome-enroll-gate" line from authorized_keys.
set -eu
BASE="$HOME/.magpie-connector"
GATE_LOG="$BASE/enroll-gate.log"

orig="${SSH_ORIGINAL_COMMAND:-}"
log() { printf '[%s] %s\n' "$(date -Is)" "$*" >> "$GATE_LOG" 2>/dev/null || true; }

log "gate hit: orig='${orig:0:80}' from=${SSH_CLIENT%% *}"

case "$orig" in
    enroll\ [a-zA-Z0-9-]*)
        args="$(printf '%s' "$orig" | sed 's/^enroll //')"
        name="$(printf '%s' "$args" | cut -d' ' -f1 | tr -cd 'a-z0-9-')"
        fp="$(printf '%s' "$args" | cut -d' ' -s -f2 | tr -cd 'a-f0-9' | cut -c1-32)"
        mode="$(printf '%s' "$args" | cut -d' ' -s -f3)"; [ "$mode" = "ps" ] || [ "$mode" = "tmp" ] || mode=""
        mag="$(printf '%s' "$args" | cut -d' ' -s -f4)";  [ "$mag" = "1" ] || mag=""
        glm="$(printf '%s' "$args" | cut -d' ' -s -f5)";  [ "$glm" = "1" ] || glm=""
        quiet="$(printf '%s' "$args" | cut -d' ' -s -f6)"; [ "$quiet" = "1" ] || quiet=""
        [ -n "$name" ] || { echo 'DENY: empty name'; exit 1; }
        # The hardware fingerprint decides the slot, not the requested name: the same
        # machine re-appearing from a new IP / with a new hostname re-uses its existing
        # identity, so DHCP changes and randomized MACs never fork a machine.
        # stdout stays reserved for the installer; human messages go to stderr.
        if [ -n "$fp" ]; then
            MF="$BASE/machines.json"
            MK="$BASE/machines.json.lock"
            mkdir -p "$BASE"
            name="$(flock "$MK" python3 - "$name" "$fp" "$MF" <<'PY'
import json, sys, os, time
requested, fp, f = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(f, encoding='utf-8')) if os.path.exists(f) else {}
name = next((n for n, r in m.items() if r.get('fp') == fp), None)
if name:
    print('FP-REUSE ' + name, file=sys.stderr)
else:
    m[requested] = {'fp': fp, 'enrolled_at': time.strftime('%Y-%m-%dT%H:%M:%S')}
    json.dump(m, open(f, 'w', encoding='utf-8'), indent=1)
    name = requested
    print('FP-NEW ' + name, file=sys.stderr)
print(name)
PY
)"
            name="$(printf '%s' "$name" | tail -1)"
        fi
        exec bash "$BASE/enroll.sh" "$name" "$fp" "$mode" "$mag" "$glm" "$quiet"
        ;;
    get\ sshserver)
        [ -f "$BASE/sshserver.ps1" ] && { exec cat "$BASE/sshserver.ps1"; }
        echo 'DENY: sshserver.ps1 not staged'; exit 1
        ;;
    get\ openssh)
        [ -f "$BASE/OpenSSH-Win64.zip" ] && { exec cat "$BASE/OpenSSH-Win64.zip"; }
        echo 'DENY: OpenSSH-Win64.zip not staged (run stage-relay.sh)'; exit 1
        ;;
    get\ magpie)
        [ -f "$BASE/magpie-windows-amd64.exe" ] && { exec cat "$BASE/magpie-windows-amd64.exe"; }
        echo 'DENY: magpie exe not staged'; exit 1
        ;;
    '')
        echo 'DENY: this key only runs: enroll <name> | get sshserver | get openssh | get magpie'
        exit 1
        ;;
    *)
        echo "DENY: '${orig:0:40}'"
        log "DENY: '$orig'"
        exit 1
        ;;
esac