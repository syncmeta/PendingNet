#!/usr/bin/env bash
# Isolated test: run a SECOND sing-box on alternate ports with the "local-port
# only" (notun) variant, so the three rule modes and the generated config can be
# verified end-to-end WITHOUT touching the live TUN, the system proxy, or the
# running engine. Nothing here needs sudo.
#
# Ports used: mixed 2081, clash_api 9091 (live engine keeps 2080 / 9090).
# Usage: deploy/isotest.sh            (from the repo root)
set -uo pipefail

CFG="$HOME/Library/Group Containers/287TTNZF8L.io.nekohasekai.sfavt/configs"
SRS="$HOME/sbtally-srs"
DIR=/tmp/pn-iso
API=127.0.0.1:9091
PROXY=http://127.0.0.1:2081
SECRET=isotest
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [OK]   $*"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
api() { curl -sm 5 -H "Authorization: Bearer $SECRET" "$@"; }

rm -rf "$DIR"; mkdir -p "$DIR"   # fresh dir: no stale cache.db from prior runs

echo "== 1. generate notun variant on alternate ports =="
go run ./cmd/sbtally config generate \
    --vps vps154="$CFG/config_70.json" \
    --vps vps38="$CFG/config_61.json" \
    --vps vps209="$CFG/config_66.json" \
    --ruleset-dir "$SRS" --clash-secret "$SECRET" \
    --clash-addr "$API" --mixed-port 2081 --out-dir "$DIR" || exit 1
sing-box check -c "$DIR/master-notun.json" && ok "sing-box check passed" || { bad "check failed"; exit 1; }

echo "== 2. start it (no TUN, no system proxy, unprivileged) =="
( cd "$DIR" && exec sing-box run -c "$DIR/master-notun.json" >"$DIR/log" 2>&1 ) &   # cwd=$DIR so cache.db stays here
ENGINE=$!
trap 'kill $ENGINE 2>/dev/null; echo "== stopped isolated engine =="' EXIT
for _ in $(seq 20); do api "$API/version" >/dev/null 2>&1 && break; sleep 1; done
api "$API/version" >/dev/null 2>&1 && ok "clash API up on $API" || { bad "engine did not start"; tail -5 "$DIR/log"; exit 1; }

echo "== 3. default mode is Whitelist =="
M=$(api "$API/configs" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("mode",""))')
[[ "$M" == Whitelist ]] && ok "default_mode = $M" || bad "default_mode = $M (want Whitelist)"

echo "== 4. proxy works through the isolated mixed port =="
curl -sm 12 -x "$PROXY" -o /dev/null -w '%{http_code}' https://www.google.com/generate_204 | grep -q 204 \
    && ok "google 204 via $PROXY" || bad "google unreachable via isolated proxy"

echo "== 5. rule modes route as designed =="
# CN site: direct in Whitelist/Blacklist, proxied in Global. Compare the egress
# IP the site sees — CN-direct vs proxy egress must differ.
egress() { curl -sm 12 -x "$PROXY" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}'; }
setmode() { api -X PATCH -d "{\"mode\":\"$1\"}" "$API/configs" >/dev/null; sleep 1; }

setmode Global;    G=$(egress)
setmode Whitelist; W=$(egress)
setmode Blacklist; B=$(egress)
echo "  egress ip — Global=$G Whitelist=$W Blacklist=$B"
[[ -n "$G" ]] && ok "Global egress reachable" || bad "Global egress failed"
# cloudflare.com is non-CN, so Whitelist proxies it too: expect W == G.
[[ "$W" == "$G" && -n "$W" ]] && ok "Whitelist proxies non-CN (== Global egress)" || bad "Whitelist egress $W != Global $G"
# Not on the GFW list ⇒ Blacklist sends it direct ⇒ different (local) egress.
[[ -n "$B" && "$B" != "$G" ]] && ok "Blacklist sends non-listed site direct (egress differs)" || bad "Blacklist egress $B not direct"

CN=$(setmode Whitelist; curl -sm 10 -x "$PROXY" -o /dev/null -w '%{http_code}' http://www.baidu.com)
[[ "$CN" == 200 ]] && ok "CN site OK in Whitelist" || bad "CN site returned $CN"

echo
echo "== RESULT: $PASS ok, $FAIL fail =="
[[ $FAIL -eq 0 ]] || exit 1
