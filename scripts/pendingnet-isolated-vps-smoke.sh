#!/bin/sh
set -eu

XRAY_BIN=${XRAY_BIN:-/usr/local/bin/xray}
HYSTERIA_BIN=${HYSTERIA_BIN:-/usr/local/bin/hysteria}
SING_BOX_BIN=${SING_BOX_BIN:-/usr/local/bin/sing-box}
REALITY_PORT=${REALITY_PORT:-24443}
HYSTERIA_PORT=${HYSTERIA_PORT:-25443}
REALITY_CLIENT_PORT=${REALITY_CLIENT_PORT:-22081}
HYSTERIA_CLIENT_PORT=${HYSTERIA_CLIENT_PORT:-22082}
REALITY_SNI=${REALITY_SNI:-www.cloudflare.com}

for binary in "$XRAY_BIN" "$HYSTERIA_BIN" "$SING_BOX_BIN" /usr/bin/curl python3 openssl setsid; do
    if ! command -v "$binary" >/dev/null 2>&1 && ! test -x "$binary"; then
        echo "missing required executable: $binary" >&2
        exit 1
    fi
done

for port in "$REALITY_PORT" "$HYSTERIA_PORT" "$REALITY_CLIENT_PORT" "$HYSTERIA_CLIENT_PORT"; do
    if ss -lntup | grep -Eq ":${port}([[:space:]]|$)"; then
        echo "test port is already in use: $port" >&2
        exit 1
    fi
done

LAB_DIR=$(mktemp -d /tmp/pendingnet-isolated-smoke.XXXXXX)
PROCESS_GROUPS=""
cleanup() {
    for pgid in $PROCESS_GROUPS; do
        /bin/kill -TERM -- "-$pgid" >/dev/null 2>&1 || true
    done
    sleep 1
    for pgid in $PROCESS_GROUPS; do
        /bin/kill -KILL -- "-$pgid" >/dev/null 2>&1 || true
    done
    case "$LAB_DIR" in
        /tmp/pendingnet-isolated-smoke.*) rm -rf -- "$LAB_DIR" ;;
    esac
}
trap cleanup EXIT INT TERM
chmod 700 "$LAB_DIR"

XRAY_KEYS=$($XRAY_BIN x25519)
REALITY_PRIVATE=$(printf '%s\n' "$XRAY_KEYS" | awk -F': ' '/^PrivateKey:/ {print $2; exit}')
REALITY_PUBLIC=$(printf '%s\n' "$XRAY_KEYS" | awk -F': ' '/PublicKey/ {print $2; exit}')
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)
HY_PASSWORD=$(openssl rand -hex 18)
HY_OBFS_PASSWORD=$(openssl rand -hex 18)
export LAB_DIR REALITY_PRIVATE REALITY_PUBLIC UUID SHORT_ID HY_PASSWORD HY_OBFS_PASSWORD
export REALITY_PORT HYSTERIA_PORT REALITY_CLIENT_PORT HYSTERIA_CLIENT_PORT REALITY_SNI

openssl ecparam -genkey -name prime256v1 -out "$LAB_DIR/hysteria.key"
openssl req -new -x509 -key "$LAB_DIR/hysteria.key" -out "$LAB_DIR/hysteria.crt" \
    -days 1 -subj '/CN=127.0.0.1' -addext 'subjectAltName=IP:127.0.0.1' >/dev/null 2>&1
chmod 600 "$LAB_DIR/hysteria.key" "$LAB_DIR/hysteria.crt"

python3 - <<'PY'
import json, os
from pathlib import Path

d = Path(os.environ["LAB_DIR"])
reality_port = int(os.environ["REALITY_PORT"])
hysteria_port = int(os.environ["HYSTERIA_PORT"])
reality_client_port = int(os.environ["REALITY_CLIENT_PORT"])
hysteria_client_port = int(os.environ["HYSTERIA_CLIENT_PORT"])
sni = os.environ["REALITY_SNI"]

xray = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "listen": "127.0.0.1", "port": reality_port, "protocol": "vless",
        "settings": {"clients": [{"id": os.environ["UUID"], "flow": "xtls-rprx-vision"}], "decryption": "none"},
        "streamSettings": {
            "network": "tcp", "security": "reality",
            "realitySettings": {
                "show": False, "target": f"{sni}:443", "xver": 0,
                "serverNames": [sni], "privateKey": os.environ["REALITY_PRIVATE"],
                "shortIds": [os.environ["SHORT_ID"]],
            },
        },
    }],
    "outbounds": [{"protocol": "freedom", "tag": "direct"}],
}

hysteria = {
    "listen": f"127.0.0.1:{hysteria_port}",
    "tls": {"cert": str(d / "hysteria.crt"), "key": str(d / "hysteria.key"), "sniGuard": "disable"},
    "obfs": {"type": "salamander", "salamander": {"password": os.environ["HY_OBFS_PASSWORD"]}},
    "auth": {"type": "password", "password": os.environ["HY_PASSWORD"]},
    "masquerade": {"type": "proxy", "proxy": {"url": "https://www.cloudflare.com/", "rewriteHost": True}},
}

def client(port, outbound):
    return {
        "log": {"level": "warn"},
        "inbounds": [{"type": "mixed", "tag": "local", "listen": "127.0.0.1", "listen_port": port}],
        "outbounds": [outbound],
        "route": {"final": outbound["tag"], "auto_detect_interface": True},
    }

reality_client = client(reality_client_port, {
    "type": "vless", "tag": "proxy", "server": "127.0.0.1", "server_port": reality_port,
    "uuid": os.environ["UUID"], "flow": "xtls-rprx-vision",
    "tls": {
        "enabled": True, "server_name": sni,
        "reality": {"enabled": True, "public_key": os.environ["REALITY_PUBLIC"], "short_id": os.environ["SHORT_ID"]},
        "utls": {"enabled": True, "fingerprint": "chrome"},
    },
})
hysteria_client = client(hysteria_client_port, {
    "type": "hysteria2", "tag": "proxy", "server": "127.0.0.1", "server_port": hysteria_port,
    "password": os.environ["HY_PASSWORD"],
    "obfs": {"type": "salamander", "password": os.environ["HY_OBFS_PASSWORD"]},
    "tls": {"enabled": True, "server_name": "127.0.0.1", "insecure": True},
})

for name, value in [
    ("xray.json", xray), ("hysteria.json", hysteria),
    ("reality-client.json", reality_client), ("hysteria-client.json", hysteria_client),
]:
    (d / name).write_text(json.dumps(value, indent=2) + "\n")
    (d / name).chmod(0o600)
PY

$XRAY_BIN run -test -config "$LAB_DIR/xray.json" >/dev/null
$SING_BOX_BIN check -c "$LAB_DIR/reality-client.json" >/dev/null
$SING_BOX_BIN check -c "$LAB_DIR/hysteria-client.json" >/dev/null

setsid "$XRAY_BIN" run -config "$LAB_DIR/xray.json" >"$LAB_DIR/xray.log" 2>&1 &
PROCESS_GROUPS="$! $PROCESS_GROUPS"
setsid "$HYSTERIA_BIN" server --config "$LAB_DIR/hysteria.json" >"$LAB_DIR/hysteria.log" 2>&1 &
PROCESS_GROUPS="$! $PROCESS_GROUPS"
sleep 1
for pgid in $PROCESS_GROUPS; do /bin/kill -0 -- "-$pgid"; done

run_client_smoke() {
    name=$1
    config=$2
    port=$3
    setsid "$SING_BOX_BIN" run -c "$config" >"$LAB_DIR/$name-client.log" 2>&1 &
    client_pgid=$!
    PROCESS_GROUPS="$client_pgid $PROCESS_GROUPS"
    sleep 1
    /bin/kill -0 -- "-$client_pgid"
    response=$(/usr/bin/curl -fsS --max-time 20 --proxy "socks5h://127.0.0.1:$port" \
        https://www.cloudflare.com/cdn-cgi/trace)
    printf '%s\n' "$response" | grep -q '^ip='
    echo "$name=ok"
    /bin/kill -TERM -- "-$client_pgid" >/dev/null 2>&1 || true
}

run_client_smoke reality "$LAB_DIR/reality-client.json" "$REALITY_CLIENT_PORT"
run_client_smoke hysteria2 "$LAB_DIR/hysteria-client.json" "$HYSTERIA_CLIENT_PORT"
echo "isolation=temporary-files-and-processes-only"
