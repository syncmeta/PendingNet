#!/usr/bin/env python3
"""Private Xray socket accounting, authentication correlation and TLS metadata."""
import argparse
import collections
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import queue
import re
import signal
import sqlite3
import subprocess
import threading
import time

ROOT = Path(os.environ.get("PENDINGNET_CONNECTION_DIR", "/var/lib/pendingnet-connections"))
PORT = int(os.environ.get("PENDINGNET_REALITY_PORT", "443"))
INTERFACE = os.environ.get("PENDINGNET_CAPTURE_INTERFACE", "eth0")
EVENTS = queue.Queue(maxsize=10000)
CHILDREN = []
PACKETS = {}
PACKET_LOCK = threading.Lock()


def normalize(address):
    value = ipaddress.ip_address(address.strip("[]").split("%")[0])
    return str(getattr(value, "ipv4_mapped", None) or value)


def endpoint(value):
    host, port = value.rsplit(":", 1)
    return normalize(host), int(port)


def dbopen():
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    db = sqlite3.connect(ROOT / "connections.sqlite3", timeout=20)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript("""
      CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY,v TEXT);
      CREATE TABLE IF NOT EXISTS flows(
        id TEXT PRIMARY KEY, peer TEXT, peer_port INTEGER, local TEXT, local_port INTEGER,
        direction TEXT, first REAL, last REAL, closed INTEGER DEFAULT 0,
        initial_rx INTEGER, initial_tx INTEGER, rx INTEGER, tx INTEGER,
        observed_rx INTEGER DEFAULT 0, observed_tx INTEGER DEFAULT 0, retrans INTEGER DEFAULT 0);
      CREATE INDEX IF NOT EXISTS flow_peer ON flows(peer,peer_port,last);
      CREATE TABLE IF NOT EXISTS tls(
        time REAL, peer TEXT, port INTEGER, sni TEXT, alpn TEXT,
        PRIMARY KEY(time,peer,port));
      CREATE INDEX IF NOT EXISTS tls_peer ON tls(peer,port,time);
      CREATE TABLE IF NOT EXISTS auth(
        time REAL, peer TEXT, port INTEGER, kind TEXT, user TEXT,
        PRIMARY KEY(time,peer,port,kind));
      CREATE INDEX IF NOT EXISTS auth_peer ON auth(peer,port,time);
      CREATE TABLE IF NOT EXISTS minutes(
        time INTEGER,peer TEXT,rx INTEGER,tx INTEGER,new_connections INTEGER,
        PRIMARY KEY(time,peer));
      CREATE TABLE IF NOT EXISTS packets(
        peer TEXT PRIMARY KEY,first REAL,last REAL,rx INTEGER,tx INTEGER,segments INTEGER);
    """)
    db.execute("INSERT OR IGNORE INTO meta VALUES('started',?)", (str(time.time()),))
    db.commit()
    return db


def emit(event):
    try:
        EVENTS.put_nowait(event)
    except queue.Full:
        # Leave a visible health failure instead of blocking packet dissection.
        print("metadata queue full: records dropped", flush=True)


def tls_reader():
    fields = ["frame.time_epoch", "ip.src", "ipv6.src", "tcp.srcport",
              "tls.handshake.extensions_server_name", "tls.handshake.extensions_alpn_str"]
    # Stream packets through pipes so the dissector never creates an unbounded
    # temporary capture file. Only the selected handshake fields reach SQLite.
    capture = subprocess.Popen(["tcpdump", "-i", INTERFACE, "-nn", "-s", "0", "-U", "-w", "-",
                                f"tcp dst port {PORT}"], stdout=subprocess.PIPE)
    CHILDREN.append(capture)
    args = ["tshark", "-l", "-n", "-r", "-",
            "-Y", "tls.handshake.type == 1", "-T", "fields", "-E", "occurrence=f"]
    for field in fields:
        args.extend(["-e", field])
    child = subprocess.Popen(args, stdin=capture.stdout, stdout=subprocess.PIPE, text=True)
    capture.stdout.close()
    CHILDREN.append(child)
    emit(("health", "tls_pid", str(child.pid)))
    for line in child.stdout:
        values = line.rstrip("\n").split("\t")
        if len(values) != 6:
            continue
        stamp, v4, v6, port, sni, alpn = values
        try:
            emit(("tls", float(stamp), normalize(v4 or v6), int(port), sni[:255], alpn[:128]))
        except (ValueError, IndexError):
            continue
    emit(("health", "tls_status", "exited:" + str(child.wait())))


def journal_reader():
    args = ["journalctl", "-u", "pendingnet-xray", "--since", "24 hours ago", "-f", "-o", "json"]
    child = subprocess.Popen(args, stdout=subprocess.PIPE, text=True)
    CHILDREN.append(child)
    emit(("health", "journal_pid", str(child.pid)))
    for line in child.stdout:
        try:
            obj = json.loads(line)
            message = obj.get("MESSAGE", "")
            match = re.search(r"\bfrom\s+(?:tcp:|udp:)?(\[?[0-9a-fA-F:.]+\]?):(\d+)\s+(accepted|rejected)\b", message)
            if not match:
                continue
            peer, port, kind = match.groups()
            user = re.search(r"\bemail:\s*(\S+)", message)
            emit(("auth", int(obj["__REALTIME_TIMESTAMP"]) / 1e6, normalize(peer), int(port), kind,
                  user.group(1)[:100] if user else ""))
        except (ValueError, TypeError, KeyError):
            continue
    emit(("health", "journal_status", "exited:" + str(child.wait())))


def packet_reader():
    addresses = json.loads(subprocess.check_output(["ip", "-j", "address", "show", "dev", INTERFACE], text=True))
    local = {normalize(a["local"]) for obj in addresses for a in obj.get("addr_info", [])}
    child = subprocess.Popen(["tcpdump", "-nn", "-tt", "-l", "-q", "-i", INTERFACE,
                              f"tcp port {PORT}"], stdout=subprocess.PIPE, text=True)
    CHILDREN.append(child)
    emit(("health", "packet_pid", str(child.pid)))
    emit(("health", "packet_started", str(time.time())))
    for line in child.stdout:
        # tcpdump emits packet headers and lengths only: no -A, -X or file.
        match = re.match(r"([0-9.]+) IP6? (\S+) > (\S+): tcp (\d+)", line)
        if not match:
            continue
        stamp, source, destination, length = match.groups()
        try:
            sh, sp = source.rsplit(".", 1)
            dh, dp = destination.rsplit(".", 1)
            sh, dh = normalize(sh), normalize(dh)
            if dh in local and int(dp) == PORT:
                peer, direction = sh, "rx"
            elif sh in local and int(sp) == PORT:
                peer, direction = dh, "tx"
            else:
                continue  # Exclude the separate outbound connection to target.
            stamp, length = float(stamp), int(length)
        except ValueError:
            continue
        with PACKET_LOCK:
            entry = PACKETS.setdefault(peer, {"first": stamp, "last": stamp, "rx": 0, "tx": 0, "segments": 0})
            entry[direction] += length
            entry["segments"] += 1
            entry["last"] = stamp
    emit(("health", "packet_status", "exited:" + str(child.wait())))


def sockets(pid, epoch):
    result = {}
    output = subprocess.check_output(["ss", "-HntieOp"], text=True, timeout=10)
    for line in output.splitlines():
        if f"pid={pid}," not in line:
            continue
        fields = line.split()
        try:
            local, lp = endpoint(fields[3])
            peer, pp = endpoint(fields[4])
        except (IndexError, ValueError):
            continue
        cookie = re.search(r"\bsk:(\S+)", line)
        if not cookie:
            continue
        values = dict(re.findall(r"\b(bytes_sent|bytes_received|bytes_retrans):(\d+)", line))
        key = epoch + "/" + cookie.group(1)
        result[key] = dict(peer=peer, peer_port=pp, local=local, local_port=lp,
                           direction="inbound" if lp == PORT else "outbound",
                           rx=int(values.get("bytes_received", 0)),
                           tx=int(values.get("bytes_sent", 0)),
                           retrans=int(values.get("bytes_retrans", 0)))
    return result


def drain(db):
    with PACKET_LOCK:
        counts = dict(PACKETS)
        PACKETS.clear()
    for peer, entry in counts.items():
        db.execute("""INSERT INTO packets VALUES(?,?,?,?,?,?) ON CONFLICT(peer)
                   DO UPDATE SET last=excluded.last,rx=rx+excluded.rx,
                   tx=tx+excluded.tx,segments=segments+excluded.segments""",
                   (peer, entry["first"], entry["last"], entry["rx"], entry["tx"], entry["segments"]))
    for _ in range(10000):
        try:
            event = EVENTS.get_nowait()
        except queue.Empty:
            break
        if event[0] == "health":
            db.execute("INSERT OR REPLACE INTO meta VALUES(?,?)", event[1:])
        elif event[0] == "tls":
            db.execute("INSERT OR IGNORE INTO tls VALUES(?,?,?,?,?)", event[1:])
        elif event[0] == "auth":
            db.execute("INSERT OR IGNORE INTO auth VALUES(?,?,?,?,?)", event[1:])


def sample(db, current, now):
    # Missing sockets are closed only after two missed polls; absent counters are
    # never treated as zero and lifetime bytes are separate from observed deltas.
    db.execute("UPDATE flows SET closed=1 WHERE closed=0 AND last<?", (now - 5,))
    for key, value in current.items():
        old = db.execute("SELECT * FROM flows WHERE id=?", (key,)).fetchone()
        new = int(old is None)
        rx = max(0, value["rx"] - old["rx"]) if old else 0
        tx = max(0, value["tx"] - old["tx"]) if old else 0
        if old:
            db.execute("""UPDATE flows SET last=?,closed=0,rx=?,tx=?,retrans=?,
                       observed_rx=observed_rx+?,observed_tx=observed_tx+? WHERE id=?""",
                       (now, value["rx"], value["tx"], value["retrans"], rx, tx, key))
        else:
            db.execute("""INSERT INTO flows(id,peer,peer_port,local,local_port,direction,
                       first,last,initial_rx,initial_tx,rx,tx,retrans) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                       (key, value["peer"], value["peer_port"], value["local"], value["local_port"],
                        value["direction"], now, now, value["rx"], value["tx"],
                        value["rx"], value["tx"], value["retrans"]))
        if value["direction"] == "inbound":
            db.execute("""INSERT INTO minutes VALUES(?,?,?,?,?) ON CONFLICT(time,peer)
                       DO UPDATE SET rx=rx+excluded.rx,tx=tx+excluded.tx,
                       new_connections=new_connections+excluded.new_connections""",
                       (int(now // 60) * 60, value["peer"], rx, tx, new))
    db.execute("INSERT OR REPLACE INTO meta VALUES('heartbeat',?)", (str(now),))


def run():
    db = dbopen()
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    for reader in (tls_reader, journal_reader, packet_reader):
        threading.Thread(target=reader, daemon=True).start()
    def stop(*unused):
        for child in CHILDREN:
            child.terminate()
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    last_cleanup = 0
    while True:
        now = time.time()
        status = subprocess.check_output(["systemctl", "show", "pendingnet-xray", "-p", "MainPID", "--value"],
                                         text=True, timeout=10).strip()
        current = sockets(status, boot + "/" + status) if status != "0" else {}
        with db:
            drain(db)
            sample(db, current, now)
            for child in CHILDREN:
                if child.poll() is not None:
                    raise RuntimeError("metadata subprocess exited; restarting monitor")
            if now - last_cleanup > 600:
                cutoff = now - 7 * 86400
                for table, column in (("flows", "last"), ("tls", "time"), ("auth", "time"), ("minutes", "time"), ("packets", "last")):
                    db.execute(f"DELETE FROM {table} WHERE {column}<?", (cutoff,))
                    db.execute(f"DELETE FROM {table} WHERE rowid IN (SELECT rowid FROM {table} ORDER BY {column} DESC LIMIT -1 OFFSET 100000)")
                last_cleanup = now
        time.sleep(2)


def report(raw=False):
    db = dbopen()
    ranges = ROOT / "cloudflare-ranges.json"
    networks = [ipaddress.ip_network(n) for n in json.loads(ranges.read_text())["networks"]] if ranges.exists() else []
    result = {"meta": dict(db.execute("SELECT k,v FROM meta")), "sources": []}
    for row in db.execute("""SELECT peer,count(*) connections,sum(rx) lifetime_rx,sum(tx) lifetime_tx,
                          sum(observed_rx) observed_rx,sum(observed_tx) observed_tx,
                          sum(retrans) retrans,max(last-first) duration,
                          sum(CASE WHEN closed=0 THEN 1 ELSE 0 END) active
                          FROM flows WHERE direction='inbound' GROUP BY peer
                          ORDER BY observed_tx+observed_rx DESC"""):
        item = dict(row)
        peer = item.pop("peer")
        item["source"] = peer if raw else "source-" + hashlib.sha256(peer.encode()).hexdigest()[:8]
        address = ipaddress.ip_address(peer)
        item["cloudflare_network"] = any(address in n for n in networks if n.version == address.version) if networks else None
        item["tls_names"] = [dict(r) for r in db.execute("SELECT sni,count(*) hellos FROM tls WHERE peer=? GROUP BY sni", (peer,))]
        item["auth_events"] = [dict(r) for r in db.execute("SELECT kind,count(*) count FROM auth WHERE peer=? GROUP BY kind", (peer,))]
        item["recent_minutes"] = [dict(r) for r in db.execute("SELECT * FROM minutes WHERE peer=? ORDER BY time DESC LIMIT 5", (peer,))]
        for minute in item["recent_minutes"]:
            minute.pop("peer")
        packet = db.execute("SELECT * FROM packets WHERE peer=?", (peer,)).fetchone()
        if packet:
            item["packet_payload"] = {k: packet[k] for k in packet.keys() if k != "peer"}
        result["sources"].append(item)
    existing = {r[0] for r in db.execute("SELECT DISTINCT peer FROM flows WHERE direction='inbound'")}
    for packet in db.execute("SELECT * FROM packets"):
        if packet["peer"] in existing:
            continue
        peer = packet["peer"]
        result["sources"].append({
            "source": peer if raw else "source-" + hashlib.sha256(peer.encode()).hexdigest()[:8],
            "socket_not_observed": True,
            "packet_payload": {k: packet[k] for k in packet.keys() if k != "peer"},
            "tls_names": [dict(r) for r in db.execute("SELECT sni,count(*) hellos FROM tls WHERE peer=? GROUP BY sni", (peer,))]})
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("run", "report"), default="report", nargs="?")
    parser.add_argument("--raw-addresses", action="store_true", help="root-private view of source addresses")
    args = parser.parse_args()
    run() if args.action == "run" else report(args.raw_addresses)
