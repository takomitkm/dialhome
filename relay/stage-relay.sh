#!/usr/bin/env bash
# stage-relay.sh -- put everything a new node needs onto the relay, once.
#
# Node-side installers prefer to scp these from the relay instead of downloading from GitHub/npm:
# on a campus network those downloads stall, and a stalled download is what killed the first attempt.
#
#   bash stage-relay.sh                 # verify what is already there, fetch what is missing
#   FORCE=1 bash stage-relay.sh         # re-download everything
set -eu
BASE="$HOME/.magpie-connector"
mkdir -p "$BASE"
chmod 700 "$BASE"
say() { printf '%s\n' "$*"; }

# ---------- 1) portable OpenSSH (pinned by sha256) ----------
ZIP_URL='https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64.zip'
ZIP_SHA='23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5'
ZIP="$BASE/OpenSSH-Win64.zip"
need=1
if [ -f "$ZIP" ] && [ "${FORCE:-0}" != "1" ]; then
    got="$(sha256sum "$ZIP" | awk '{print $1}')"
    [ "$got" = "$ZIP_SHA" ] && { say "openssh: present, sha OK"; need=0; } || say "openssh: sha mismatch, refetching"
fi
if [ "$need" = "1" ]; then
    if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 -o "$ZIP.part" "$ZIP_URL"
    else wget -qO "$ZIP.part" "$ZIP_URL"; fi
    got="$(sha256sum "$ZIP.part" | awk '{print $1}')"
    [ "$got" = "$ZIP_SHA" ] || { rm -f "$ZIP.part"; say "openssh: sha MISMATCH ($got) - not using it"; exit 3; }
    mv "$ZIP.part" "$ZIP"; say "openssh: fetched, sha OK"
fi
chmod 644 "$ZIP"

# ---------- 2) portable magpie for Windows (for nodes that have none) ----------
MAG="$BASE/magpie-windows-amd64.exe"
if [ ! -s "$MAG" ]; then
    for u in \
      'https://github.com/magpie-ai/magpie/releases/latest/download/magpie-windows-amd64.exe' \
      'https://download.magpie.ai/magpie-windows-amd64.exe'
    do
        say "magpie: trying $u"
        if command -v curl >/dev/null 2>&1; then
            curl -fL --retry 2 -o "$MAG.part" "$u" && [ -s "$MAG.part" ] && { mv "$MAG.part" "$MAG"; break; }
        else
            wget -qO "$MAG.part" "$u" && [ -s "$MAG.part" ] && { mv "$MAG.part" "$MAG"; break; }
        fi
        rm -f "$MAG.part"
    done
    [ -s "$MAG" ] && say "magpie: staged ($(du -h "$MAG" | cut -f1))" || say "magpie: NOT staged (node will use its own copy if it has one)"
else
    say "magpie: present ($(du -h "$MAG" | cut -f1))"
fi
chmod 644 "$MAG" 2>/dev/null || true

# ---------- 3) what nodes pull ----------
say ''
say 'ready for nodes:'
for f in "$BASE/sshserver.ps1" "$BASE/enroll.sh" "$BASE/setup-magpie.ps1" "$ZIP" "$MAG"; do
    [ -e "$f" ] && say "  $(du -h "$f" | cut -f1)  $(basename "$f")" || say "  MISSING  $(basename "$f")  <- copy it here from the repo"
done
say ''
say 'node one-liner (identical on every machine):'
say '  ssh -p 18322 user@10.101.54.192 "bash ~/.magpie-connector/enroll.sh $env:COMPUTERNAME" > "$env:TEMP\enroll.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\enroll.ps1"'