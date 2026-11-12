#!/usr/bin/env bash
# On 102: prove the remote-magpie provider mechanism against a LIVE chain (13403),
# including whether the running gateway picks providers.json up without a restart.
# Adds a throwaway provider `probe`, verifies, then removes it.
set -u
export PATH="$HOME/.local/bin:$PATH"
CFG="$HOME/.config/magpie"
PJ="$CFG/providers.json"
GW=http://127.0.0.1:3425

echo "### 0. snapshots before"
echo -n "  providers.json: "; [ -f "$PJ" ] && echo "exists ($(md5sum "$PJ" | cut -d' ' -f1))" || echo "absent"
echo -n "  settings.json md5: "; md5sum "$CFG/settings.json" | cut -d' ' -f1
echo -n "  magpie pid: "; pgrep -f 'magpie serve' | head -1
echo -n "  models via gateway before: "; curl -s -m 10 --noproxy '*' "$GW/v1/models" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(len(d.get("data",[])),"models:",", ".join(m.get("id","?") for m in d.get("data",[])[:12]))
except Exception as e: print("parse-fail",e)'
echo
echo "### 1. is the 13403 stand-in chain alive?"
curl -s -m 6 --noproxy '*' -o /dev/null -w "  13403/api/hello http=%{http_code}\n" http://127.0.0.1:13403/api/hello
curl -s -m 6 --noproxy '*' -o /dev/null -w "  13403/v1/models http=%{http_code}\n" http://127.0.0.1:13403/v1/models

echo
echo "### 2. add throwaway provider probe -> http://127.0.0.1:13403"
magpie provider add remote-magpie dummy-not-a-real-key url=http://127.0.0.1:13403 id=probe 2>&1 | sed 's/^/  /'
echo "  --- providers.json now ---"
python3 - <<'PY'
import json,os
p=os.path.expanduser('~/.config/magpie/providers.json')
d=json.load(open(p)) if os.path.exists(p) else {}
ps=d.get('providers',[]) if isinstance(d,dict) else d
for it in ps:
    print('  ', {k:(('[REDACTED]' if k=='key' else v)) for k,v in it.items()})
PY

echo
echo "### 3. provider refresh (free: list only)"
magpie provider refresh probe 2>&1 | sed 's/^/  /'

echo
echo "### 4. cli model list"
magpie models 2>&1 | grep -iE 'probe|zcode|zen-free' | sed 's/^/  /' | head -20

echo
echo "### 5. LIVE gateway: does 127.0.0.1:3425 already expose the new provider?"
curl -s -m 10 --noproxy '*' "$GW/v1/models" | python3 -c 'import json,sys
d=json.load(sys.stdin); ids=[m.get("id","?") for m in d.get("data",[])]
print("  total:",len(ids)); print("  probe*:",[i for i in ids if "probe" in i])'

echo
echo "### 6. remove throwaway provider"
magpie provider rm probe 2>&1 | sed 's/^/  /'
echo "  --- providers.json after rm ---"
if [ -f "$PJ" ]; then python3 -c 'import json;d=json.load(open("'"$PJ"'"));ps=d.get("providers",d) if isinstance(d,dict) else d;print("  entries:",len(ps), [p.get("id") for p in ps])'; else echo "  (absent)"; fi
curl -s -m 10 --noproxy '*' "$GW/v1/models" | python3 -c 'import json,sys
d=json.load(sys.stdin); ids=[m.get("id","?") for m in d.get("data",[])]
print("  gateway after rm: total",len(ids),"| probe*:",[i for i in ids if "probe" in i])'

echo
echo "### 7. snapshots after"
echo -n "  settings.json md5: "; md5sum "$CFG/settings.json" | cut -d' ' -f1
echo -n "  magpie pid (must be unchanged): "; pgrep -f 'magpie serve' | head -1
