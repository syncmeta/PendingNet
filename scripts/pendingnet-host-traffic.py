#!/usr/bin/env python3
"""Persist systemd IP accounting and NIC counters; never reset kernel counters."""
import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
from zoneinfo import ZoneInfo

STATE = Path(os.environ.get("PENDINGNET_HOST_TRAFFIC_DIR", "/var/lib/pendingnet-host-traffic"))
ZONE = ZoneInfo("Asia/Taipei")
MAX_COUNTER = (1 << 64) - 1


def command(*args):
    return subprocess.check_output(args, text=True, timeout=30)


def counters():
    units = json.loads(command("systemctl", "list-units", "--all", "--type=service,scope,socket", "--output=json"))
    names = [u["unit"] for u in units]
    props = "Id,ActiveState,InvocationID,ActiveEnterTimestampMonotonic,IPAccounting,IPIngressBytes,IPEgressBytes"
    data = command("systemctl", "show", *names, "--property=" + props)
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    result = {}
    unsupported = []
    for block in data.strip().split("\n\n"):
        p = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        if p.get("IPAccounting") != "yes":
            continue
        raw = [p.get("IPIngressBytes", ""), p.get("IPEgressBytes", "")]
        if not all(v.isdigit() and int(v) < MAX_COUNTER for v in raw):
            if p.get("ActiveState") in ("active", "activating"):
                unsupported.append(p.get("Id", "unknown"))
            continue
        epoch = p.get("InvocationID") or p.get("ActiveEnterTimestampMonotonic", "0")
        result[p["Id"]] = {"epoch": boot + "/" + epoch, "rx": int(raw[0]), "tx": int(raw[1])}
    for interface in Path("/sys/class/net").iterdir():
        if interface.name == "lo":
            continue
        stats = interface / "statistics"
        result["interface:" + interface.name] = {
            "epoch": boot + "/" + (interface / "ifindex").read_text().strip(),
            "rx": int((stats / "rx_bytes").read_text()),
            "tx": int((stats / "tx_bytes").read_text()),
        }
    return result, unsupported


def accumulate(state, current, timestamp):
    day = timestamp.astimezone(ZONE).date().isoformat()
    first = not state
    if first:
        state.update(version=1, started_at=timestamp.isoformat(), totals={}, days={}, last={})
    if state["version"] != 1:
        raise ValueError("unsupported ledger version")
    daily = state["days"].setdefault(day, {})
    for name, sample in current.items():
        old = state["last"].get(name)
        delta = {}
        for direction in ("rx", "tx"):
            value = sample[direction]
            if first:
                value = 0  # All existing counters share a fresh baseline.
            elif old and old["epoch"] == sample["epoch"] and value >= old[direction]:
                value -= old[direction]
            delta[direction] = value
        for target in (state["totals"], daily):
            total = target.setdefault(name, {"rx": 0, "tx": 0})
            for direction in ("rx", "tx"):
                total[direction] += delta[direction]
        state["last"][name] = sample
    state["updated_at"] = timestamp.isoformat()
    return state


def save(state):
    fd, name = tempfile.mkstemp(prefix="ledger-", dir=STATE)
    try:
        with os.fdopen(fd, "w") as file:
            json.dump(state, file, ensure_ascii=False)
            file.flush()
            os.fsync(file.fileno())
        os.replace(name, STATE / "traffic.json")
    finally:
        if os.path.exists(name):
            os.unlink(name)


def human(value):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024 or unit == "TiB":
            return f"{value:.2f} {unit}"
        value /= 1024


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("sample", "show"), nargs="?", default="show")
    parser.add_argument("--day", help="Asia/Taipei calendar date, YYYY-MM-DD")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if args.day:
        dt.date.fromisoformat(args.day)
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    with open(STATE / "sample.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = STATE / "traffic.json"
        state = json.loads(path.read_text()) if path.exists() else {}
        sample, unsupported = counters()
        now = dt.datetime.now(dt.timezone.utc)
        state = accumulate(state, sample, now)
        state["unavailable_units"] = unsupported
        save(state)
    if args.action == "sample":
        return
    if args.json:
        print(json.dumps(state, indent=2, ensure_ascii=False))
        return
    day = args.day or now.astimezone(ZONE).date().isoformat()
    print(f"采集起点：{state['started_at']}   最近采样：{state['updated_at']}")
    print(f"日期：{day}（Asia/Taipei）\n")
    print(f"{'程序 / 接口':42} {'当日接收':>14} {'当日发送':>14} {'累计收发':>14}")
    daily = state["days"].get(day, {})
    for name, value in sorted(state["totals"].items(), key=lambda item: sum(daily.get(item[0], {}).values()), reverse=True):
        today = daily.get(name, {"rx": 0, "tx": 0})
        if not sum(value.values()) and not name.startswith("interface:"):
            continue
        print(f"{name:42} {human(today['rx']):>14} {human(today['tx']):>14} {human(sum(value.values())):>14}")
    print("\n程序计数含回环通信；接口行单独统计，不能与程序行相加。")
    print("30 秒采样；重启前未采集的尾段及短命临时服务可能遗漏；每日边界误差约一个采样周期。")
    if unsupported:
        print("计数不可用的单元：" + ", ".join(unsupported))


if __name__ == "__main__":
    main()
