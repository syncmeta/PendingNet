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
TMPDIR_GEN=$(mktemp -d)

echo "==> Generating"
sbtally config generate "$@" --clash-secret "$(cat "$SECRET_FILE")" \
    --ruleset-dir /usr/local/etc/sbtally --out-dir "$TMPDIR_GEN"

echo "==> Validating"
sing-box check -c "$TMPDIR_GEN/master-tun.json"
sing-box check -c "$TMPDIR_GEN/master-notun.json"

echo "==> Installing (sudo) + restarting sing-box"
sudo install -m 0644 "$TMPDIR_GEN"/master-*.json "$ETC/"
MODE=$(cat "$ETC/mode" 2>/dev/null || echo tun)
[[ "$MODE" == tun ]] && ACTIVE=master-tun.json || ACTIVE=master-notun.json
sudo install -m 0644 "$ETC/$ACTIVE" "$ETC/master.json"
sudo launchctl kickstart -k system/io.sbtally.singbox
rm -rf "$TMPDIR_GEN"

sleep 3
if pgrep -x sing-box >/dev/null; then
    echo "==> OK: sing-box restarted with the new config."
else
    echo "==> WARNING: sing-box not running — check /var/log/sbtally-singbox.log" >&2
    exit 1
fi
