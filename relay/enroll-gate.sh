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
        name="$(printf '%s' "$orig" | sed 's/^enroll //' | tr -cd 'a-z0-9-')"
        [ -n "$name" ] || { echo 'DENY: empty name'; exit 1; }
        exec bash "$BASE/enroll.sh" "$name"
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