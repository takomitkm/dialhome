#!/bin/bash
# Add (or update) the campus-Windows remote provider on 102's magpie.
# Idempotent-ish: if 'win' already exists, remove first to avoid duplicates.
# Key value is arbitrary; magpie treats loopback peers as permissive.
set -u
export PATH="$HOME/.local/bin:$PATH"
GW_URL="http://127.0.0.1:13425"
ID="win"
KEY="magpie-102-to-win"

magpie provider rm "$ID" >/dev/null 2>&1 || true
echo "### add remote provider id=$ID -> $GW_URL"
magpie provider add remote-magpie "$KEY" url="$GW_URL" id="$ID" 2>&1 | sed 's/^/  /'
echo "### refresh (free: lists models only, no real request)"
magpie provider refresh "$ID" 2>&1 | sed 's/^/  /'
echo "### verify the gateway now exposes win/*"
curl -s -m 10 --noproxy '*' http://127.0.0.1:3425/v1/models | python3 -c 'import json,sys
d=json.load(sys.stdin); ids=[m.get("id","?") for m in d.get("data",[])]
wins=[i for i in ids if i.startswith("win/")]
print("  win* models:", wins)'
