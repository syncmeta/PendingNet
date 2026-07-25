#!/usr/bin/env bash
# Regenerate + install the sbtally master config, preserving the local rule-set
# setup (remote rule-sets dead-lock at startup — see SETUP.md).
#
# Usage:
#   deploy/update-config.sh --vps name=/path/to/config.json [--vps name2=...]
#
# Order matters: the FIRST --vps (and the first outbound inside it) is the
# default selection on a fresh cache. Your runtime selections in the GUI are
# stored in cache.db and survive config updates.
set -euo pipefail

SECRET_FILE="$HOME/.sbtally-clash-secret"
[[ -f "$SECRET_FILE" ]] || { echo "missing $SECRET_FILE" >&2; exit 1; }
ETC=/usr/local/etc/sbtally
TMP=$(mktemp /tmp/sbtally-master.XXXXXX.json)

echo "==> Generating"
sbtally config generate "$@" --clash-secret "$(cat "$SECRET_FILE")" --out "$TMP"

echo "==> Switching rule-sets to local files in $ETC"
python3 - "$TMP" <<'EOF'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
paths = {'geosite-cn': 'geosite-cn.srs', 'geoip-cn': 'geoip-cn.srs',
         'geosite-noncn': 'geosite-geolocation-noncn.srs',
         'geosite-ads': 'geosite-category-ads-all.srs'}
c['route']['rule_set'] = [{'tag': t, 'type': 'local', 'format': 'binary',
                           'path': f'/usr/local/etc/sbtally/{f}'}
                          for t, f in paths.items()]
json.dump(c, open(p, 'w'), indent=2, ensure_ascii=False)
EOF

echo "==> Validating"
sing-box check -c "$TMP"

echo "==> Installing (sudo) + restarting sing-box"
sudo install -m 0644 "$TMP" "$ETC/master.json"
sudo launchctl kickstart -k system/io.sbtally.singbox
rm -f "$TMP"

sleep 3
if pgrep -x sing-box >/dev/null; then
    echo "==> OK: sing-box restarted with the new config."
else
    echo "==> WARNING: sing-box not running — check /var/log/sbtally-singbox.log" >&2
    exit 1
fi
