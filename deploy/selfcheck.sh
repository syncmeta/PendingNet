#!/usr/bin/env bash
# Offline cutover self-check. Run AFTER: quit SFM + bootstrap io.sbtally.singbox.
# Needs no Claude / no foreign connectivity to diagnose. Writes ~/cutover-report.txt
# (paste it back to Claude over SFM if things fail).
set -u
R="$HOME/cutover-report.txt"
: > "$R"
say() { echo "$*" | tee -a "$R"; }
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); say "  [OK]   $*"; }
bad()  { FAIL=$((FAIL+1)); say "  [FAIL] $*"; }

say "== sbtally cutover self-check $(date) =="

say "-- 1. sing-box daemon"
if sudo launchctl print system/io.sbtally.singbox 2>/dev/null | grep -q 'state = running'; then
    ok "launchd: running"
else
    bad "launchd: NOT running"
fi
if pgrep -x sing-box >/dev/null; then ok "sing-box process alive"; else bad "no sing-box process"; fi

say "-- 2. recent fatals (last 30s of log)"
F=$(tail -50 /var/log/sbtally-singbox.log 2>/dev/null | grep -c FATAL || true)
if [[ "${F:-0}" -eq 0 ]]; then ok "no FATAL in recent log"; else
    bad "$F FATAL lines — tail below"
    tail -5 /var/log/sbtally-singbox.log | tee -a "$R"
fi

say "-- 3. clash API"
SECRET=$(cat "$HOME/.sbtally-clash-secret" 2>/dev/null || true)
if curl -sm 3 -H "Authorization: Bearer $SECRET" 127.0.0.1:9090/version >>"$R" 2>&1; then
    ok "clash API answers on 9090"; echo >>"$R"
else
    bad "clash API not answering"
fi

say "-- 4. connectivity"
if curl -sm 6 -o /dev/null http://connect.rom.miui.com/generate_204; then ok "CN direct reachable"; else bad "CN direct unreachable"; fi
if curl -sm 10 -o /dev/null -w '%{http_code}' https://www.google.com/generate_204 | grep -q 204; then
    ok "google reachable through TUN (proxy path works)"
else
    bad "google NOT reachable — proxy path broken"
fi

say "-- 5. per-app stats (the whole point)"
sleep 2
if sbtally apps --since 5m 2>>"$R" | tee -a "$R" | grep -qiE 'safari|chrome|curl|telegram|wechat|[a-z]'; then
    ok "per-app rows present"
else
    bad "no per-app stats yet (may need a minute of traffic)"
fi

say ""
say "== RESULT: $PASS ok, $FAIL fail =="
if [[ $FAIL -gt 0 ]]; then
    say "ROLLBACK: sudo launchctl bootout system/io.sbtally.singbox ; then reopen SFM."
    say "Then paste $R to Claude."
else
    say "Cutover healthy. Report saved to $R"
fi
