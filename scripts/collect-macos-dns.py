#!/usr/bin/env python3
"""Local manual-switch diagnosis; never changes network settings or clears DNS."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

ETC = Path('/usr/local/etc/sbtally')
DOMAIN = 'www.google.com'
FILTER = '(udp port 53 or tcp port 53) and (host 223.5.5.5 or host 119.29.29.29 or host 127.0.0.1)'


def mode():
    try:
        return (ETC / 'mode').read_text().strip()
    except OSError:
        return 'unknown'


def now():
    return datetime.datetime.now().astimezone().isoformat()


def packet_allowed(line):
    # Never save other domains, raw payload, API secrets or full config.
    return bool(re.search(r'(?<![\w.-])www\.google\.com\.?(?![\w.-])', line, re.I))


class Window:
    def __init__(self):
        self.started = None
        self.warned = set()
        self.ended = False

    def observe(self, current, monotonic):
        if self.ended:
            return None
        if current == 'tun' and self.started is None:
            self.started = monotonic
            return 'started'
        if self.started is None:
            return None
        if current != 'tun':
            self.ended = True
            return 'restored' if current == 'sysproxy' else 'unexpected-mode'
        elapsed = monotonic - self.started
        for threshold in (30, 25, 20):
            if elapsed >= threshold and threshold not in self.warned:
                self.warned.add(threshold)
                return 'deadline' if threshold == 30 else 'warning'
        return None


class Collector:
    def __init__(self, output):
        self.output = output
        self.lock = threading.Lock()
        self.cancel = threading.Event()
        self.shutdown = threading.Event()
        self.tun_seen = threading.Event()
        self.window = Window()
        self.capture = None
        self.bytes_written = 0
        self.capture_lines = 0
        self.run_started = time.monotonic()
        self.file = (output / 'events.jsonl').open('x', buffering=1)

    def emit(self, kind, **data):
        with self.lock:
            # Bounded local output, even if tcpdump receives unrelated traffic.
            if self.bytes_written > 2_000_000:
                self.cancel.set()
                return
            line = json.dumps(dict(time=now(), monotonic=time.monotonic(),
                                   kind=kind, **data), ensure_ascii=False) + '\n'
            self.file.write(line)
            self.bytes_written += len(line.encode())

    def command(self, name, args, timeout=2):
        if self.cancel.is_set():
            return
        started = time.monotonic()
        self.emit('probe_start', name=name, mode=mode(), args=args)
        process = subprocess.Popen(args, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True,
                                   env=dict(os.environ, LC_ALL='C'))
        end = started + timeout
        try:
            while True:
                if self.cancel.is_set() or time.monotonic() >= end:
                    process.kill()
                    out, err = process.communicate()
                    self.emit('probe_end', name=name, exit=process.returncode,
                              cancelled=self.cancel.is_set(), timeout=True,
                              stdout=out[-12000:], stderr=err[-2000:], mode=mode())
                    return
                try:
                    out, err = process.communicate(timeout=0.1)
                    self.emit('probe_end', name=name, exit=process.returncode,
                              stdout=out[-12000:], stderr=err[-2000:], mode=mode())
                    return dict(exit=process.returncode, stdout=out)
                except subprocess.TimeoutExpired:
                    pass
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def selectors(self):
        """GET only, loopback only. Secret remains in memory, never in argv/output."""
        config = json.loads((ETC / 'master.json').read_text())
        api = config['experimental']['clash_api']
        address = api['external_controller']
        if not re.fullmatch(r'127\.0\.0\.1:\d+', address):
            raise RuntimeError('控制口不是 127.0.0.1，停止')
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        tag = 'proxy'
        chain = []
        for _ in range(6):
            req = urllib.request.Request('http://' + address + '/proxies/' + tag,
                                         headers={'Authorization': 'Bearer ' + api.get('secret', '')})
            with opener.open(req, timeout=0.6) as response:
                obj = json.load(response)
            chain.append({'tag': tag, 'type': obj.get('type'), 'now': obj.get('now')})
            selected = obj.get('now')
            if not selected:
                break
            if selected in [x['tag'] for x in chain]:
                raise RuntimeError('selector 回环')
            tag = selected
        outbound = next((x for x in config['outbounds'] if x.get('tag') == tag), {})
        result = dict(chain=chain, server=outbound.get('server'), protocol=outbound.get('type'))
        self.emit('selector', **result)
        return result

    def dns_round(self, label, brief=False):
        self.emit('round', label=label, mode=mode())
        self.command(label + '/dscacheutil', ['/usr/bin/dscacheutil', '-q', 'host', '-a', 'name', DOMAIN], timeout=0.8 if brief else 2)
        for family in ('AF_INET', 'AF_INET6'):
            code = ('import socket,json; print(json.dumps(sorted(set(x[4][0] for x in '
                    f'socket.getaddrinfo({DOMAIN!r},443,socket.{family},socket.SOCK_STREAM)))))')
            self.command(label + '/getaddrinfo/' + family, [sys.executable, '-c', code], timeout=0.8 if brief else 2)
        for resolver in (('223.5.5.5',) if brief else ('223.5.5.5', '119.29.29.29')):
            for qtype in (('A',) if brief else ('A', 'AAAA')):
                self.command(label + '/dig/' + resolver + '/' + qtype,
                             ['/usr/bin/dig', '+time=1', '+tries=1', '@' + resolver,
                              DOMAIN, qtype, '+noall', '+answer'], timeout=1.5)

    def state(self, label):
        self.emit('state', label=label, mode=mode())
        for name, args in (
            ('dns', ['/usr/sbin/scutil', '--dns']),
            ('proxy', ['/usr/sbin/scutil', '--proxy']),
            ('interfaces', ['/sbin/ifconfig', '-l']),
        ):
            self.command(label + '/' + name, args, timeout=0.8)
        for resolver in ('223.5.5.5', '119.29.29.29'):
            self.command(label + '/route/' + resolver,
                         ['/sbin/route', '-n', 'get', resolver], timeout=0.8)
            for iface in ('en11', 'en0'):
                self.command(label + '/scoped-route/' + iface + '/' + resolver,
                             ['/sbin/route', '-n', 'get', '-ifscope', iface, resolver], timeout=0.8)

    def monitor(self):
        previous = None
        helper = Path('/var/log/pendingnet-helper.log')
        offset = helper.stat().st_size if helper.exists() else 0
        while not self.shutdown.wait(0.1):
            current = mode()
            if current != previous:
                self.emit('mode', value=current)
                previous = current
            action = self.window.observe(current, time.monotonic())
            if action == 'started':
                self.emit('tun_window_started')
                self.tun_seen.set()
                print('检测到 TUN，开始计时。最迟30秒必须手动切回154系统代理。', flush=True)
            elif action in ('warning', 'deadline'):
                print('\a请现在切回154「系统代理」！脚本不会替您恢复网络。', flush=True)
                self.emit('recovery_prompt', action=action)
                if action == 'deadline':
                    self.cancel.set()
                    self.stop_capture()
            elif action in ('restored', 'unexpected-mode'):
                self.emit('tun_window_end', action=action)
                self.cancel.set()
            if time.monotonic() - self.run_started >= 180:
                self.cancel.set()
                self.stop_capture()
            try:
                size = helper.stat().st_size
                if size < offset:
                    offset = 0
                with helper.open() as file:
                    file.seek(offset)
                    chunk = file.read(16000)
                    for line in chunk.splitlines():
                        # Only selected diagnostics, no arbitrary historical log tail.
                        if 'DNS 缓存' in line or '绑不到网卡' in line:
                            self.emit('helper_new', line=line.strip()[:1000])
                    offset = file.tell()
            except OSError:
                pass

    def start_capture(self):
        ready = threading.Event()
        self.capture = subprocess.Popen(
            ['/usr/sbin/tcpdump', '-i', 'pktap,all', '-n', '-l', '-tttt', '-vv', '--apple-oneline',
             '-s', '512', '-k', 'INPD', FILTER],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def read(stream, errors=False):
            for line in stream:
                if errors:
                    self.emit('capture_status', line=line.strip()[:1000])
                    if 'listening on' in line:
                        ready.set()
                elif packet_allowed(line) and self.capture_lines < 3000:
                    self.capture_lines += 1
                    self.emit('dns_packet', line=line.strip()[:2000])
        for stream, errors in ((self.capture.stdout, False), (self.capture.stderr, True)):
            thread = threading.Thread(target=read, args=(stream, errors), daemon=True)
            thread.start()
            self.capture_threads.append(thread)
        if not ready.wait(3) or self.capture.poll() is not None:
            raise RuntimeError('抓包启动失败；不要切换模式，查看 events.jsonl')
        self.emit('capture_started', scope='all interfaces; configured and loopback DNS only; Google text only')

    def stop_capture(self):
        with self.lock:
            capture = self.capture
            if capture is not None and capture.poll() is None:
                capture.terminate()

    def run(self):
        self.capture_threads = []
        watcher = threading.Thread(target=self.monitor, daemon=True)
        watcher.start()
        try:
            if mode() != 'sysproxy':
                raise RuntimeError('请先保持154/Hysteria2系统代理，然后重新运行')
            selection = self.selectors()
            if selection['server'] != '154.36.143.228' or selection['protocol'] != 'hysteria2':
                raise RuntimeError('实际 selector 不是154/Hysteria2；停止，不要切换')
            self.start_capture()
            self.state('before')
            self.dns_round('before')
            if self.cancel.is_set():
                return
            if mode() != 'sysproxy':
                raise RuntimeError('基线采集期间模式已变化；请先恢复系统代理，不继续本次测试')
            print('基线采集完成。现在请手动点击 TUN；90秒未切换会停止。', flush=True)
            wait_end = time.monotonic() + 90
            while not self.tun_seen.wait(0.1):
                if self.cancel.is_set() or time.monotonic() >= wait_end:
                    self.emit('tun_not_observed')
                    return
            for offset in (0, 2, 5, 10):
                while time.monotonic() < self.window.started + offset and not self.cancel.wait(0.05):
                    pass
                if self.cancel.is_set():
                    break
                self.dns_round('tun-target-' + str(offset), brief=True)
            if not self.cancel.is_set():
                self.state('tun')
                try:
                    self.selectors()
                except Exception:
                    self.emit('selector_unavailable')
                # Candidate entry probes only when the active config contains it.
                try:
                    config = json.loads((ETC / 'master.json').read_text())
                    managed = any(x.get('tag') == 'pendingnet-system-dns' for x in config.get('inbounds', []))
                except (OSError, ValueError):
                    managed = False
                if managed:
                    for qtype in ('A', 'AAAA'):
                        self.command('tun/dig-loopback/' + qtype,
                                     ['/usr/bin/dig', '+time=1', '+tries=1', '@127.0.0.1', DOMAIN,
                                      qtype, '+noall', '+answer'], timeout=1.5)
                curl = ['/usr/bin/curl', '--max-time', '3', '--connect-timeout', '2',
                        '-sS', '-o', '/dev/null', '-w', 'http=%{http_code} remote=%{remote_ip} seconds=%{time_total}']
                for name, extra in (
                    ('ordinary', ['--noproxy', '*']),
                    ('proxy', ['--proxy', 'http://127.0.0.1:2080']),
                    ('correct-ip', ['--noproxy', '*', '--resolve', DOMAIN + ':443:142.251.155.119']),
                ):
                    self.command('tun/curl/' + name, curl + extra + ['https://' + DOMAIN], timeout=3.2)
            print('\a采集窗口结束，请立即手动切回154「系统代理」。', flush=True)
            self.stop_capture()
            # Monitor remains alive while user restores; never reset TUN deadline.
            recovery_end = time.monotonic() + 45
            while mode() != 'sysproxy' and time.monotonic() < recovery_end:
                time.sleep(0.1)
            if mode() == 'sysproxy':
                self.emit('restored_mode_observed')
                self.shutdown.set()
                watcher.join(timeout=2)
                self.cancel.clear()
                deadline = time.monotonic() + 10
                restored = False
                attempt = 0
                while mode() == 'sysproxy' and time.monotonic() < deadline:
                    attempt += 1
                    budget = min(2.2, deadline - time.monotonic())
                    result = self.command('restored/proxy-curl/' + str(attempt),
                        ['/usr/bin/curl', '--proxy', 'http://127.0.0.1:2080', '--max-time', str(budget),
                         '-sS', '-o', '/dev/null', '-w', 'http=%{http_code}', 'https://' + DOMAIN], timeout=budget)
                    if result and result['exit'] == 0 and result['stdout'] == 'http=200':
                        restored = True
                        break
                    time.sleep(min(0.25, max(0, deadline - time.monotonic())))
                self.emit('recovery_probe_result', passed=restored, attempts=attempt)
                if mode() == 'sysproxy':
                    self.state('restored')
                print(('代理访问已恢复；仍请确认浏览器联网。' if restored else
                       '\a仅观察到系统代理模式，联网探针仍未通过；请先手动确认恢复，不要重复测试。'), flush=True)
            else:
                self.emit('recovery_not_confirmed')
                print('\a尚未确认恢复！请手动恢复154系统代理；不要继续测试。', flush=True)
        finally:
            self.shutdown.set()
            self.stop_capture()
            if self.capture is not None:
                try:
                    self.capture.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.capture.kill()
                    self.capture.wait()
            watcher.join(timeout=2)
            for thread in self.capture_threads:
                thread.join(timeout=2)
            self.emit('finished', mode=mode())
            if self.capture is not None:
                self.emit('capture_stopped', exit=self.capture.returncode, saved_lines=self.capture_lines)
            self.file.close()
            print('结果已保存：' + str(self.output), flush=True)


def self_check():
    # No commands, sockets, network, capture or system state changes.
    w = Window()
    assert w.observe('sysproxy', 100) is None
    assert w.observe('tun', 101) == 'started'
    assert w.observe('tun', 121) == 'warning'
    assert w.observe('tun', 126) == 'warning'
    assert w.observe('tun', 131) == 'deadline'
    assert w.observe('sysproxy', 132) == 'restored'
    assert w.observe('sysproxy', 133) is None
    assert Window().observe('sysproxy', 0) is None
    assert packet_allowed('en11 1234+ A? www.google.com. (32)')
    assert packet_allowed('utun9 1234 2/0/0 A www.google.com. 31.13.92.37')
    assert not packet_allowed('en0 A? private.example.com.')
    assert not packet_allowed('en0 A? other.www.google.com.')
    # Exercise real subprocess timeout/cancellation; the child only sleeps.
    with tempfile.TemporaryDirectory(prefix='pendingnet-dns-self-check-') as directory:
        collector = Collector(Path(directory))
        collector.command('timeout', [sys.executable, '-c', 'import time; time.sleep(5)'], timeout=0.15)
        started = time.monotonic()
        child = threading.Thread(target=collector.command,
                                 args=('cancel', [sys.executable, '-c', 'import time; time.sleep(5)'], 5))
        child.start()
        time.sleep(0.1)
        collector.cancel.set()
        child.join(timeout=1)
        assert not child.is_alive() and time.monotonic() - started < 1
        collector.file.close()
        events = [json.loads(line) for line in (Path(directory) / 'events.jsonl').read_text().splitlines()]
        ends = [x for x in events if x['kind'] == 'probe_end']
        assert len(ends) == 2 and ends[0]['timeout'] and ends[1]['cancelled']
        collector.capture = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(5)'])
        collector.stop_capture()
        collector.capture.wait(timeout=1)
        assert collector.capture.returncode != 0
    print('离线检查通过：TUN计时/恢复、域名筛选、子进程超时与取消；未运行网络探针或抓包。')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-check', action='store_true')
    parser.add_argument('--output', type=Path, default=Path('/private/tmp') /
                        ('pendingnet-dns-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S')))
    args = parser.parse_args()
    if args.self_check:
        self_check()
        return
    if sys.platform != 'darwin' or os.geteuid() != 0:
        parser.error('实测仅支持macOS，请由人使用 sudo python3 启动（需要受限抓包权限）')
    os.umask(0o077)
    args.output.mkdir(mode=0o700, parents=False, exist_ok=False)
    try:
        Collector(args.output).run()
    except KeyboardInterrupt:
        print('\n已停止；若仍在TUN，请立即手动切回154系统代理。', flush=True)
    except Exception as error:
        # Don't expose API/config exception objects containing secrets.
        print('采集停止：' + (str(error) if isinstance(error, RuntimeError) else type(error).__name__), flush=True)
        print('若已切TUN，请立即手动切回154系统代理。', flush=True)
        return 1
    finally:
        if os.environ.get('SUDO_UID') and os.environ.get('SUDO_GID'):
            uid, gid = int(os.environ['SUDO_UID']), int(os.environ['SUDO_GID'])
            for path in args.output.iterdir():
                os.chown(path, uid, gid)
            os.chown(args.output, uid, gid)


if __name__ == '__main__':
    sys.exit(main())
