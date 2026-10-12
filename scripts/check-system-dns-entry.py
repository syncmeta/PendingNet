#!/usr/bin/env python3
"""Exercise the generated DNS entry with sing-box, loopback-only, no TUN or system changes."""
import argparse
import ipaddress
import json
import socket
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path


def exact(sock, size):
    data = b''
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise RuntimeError('short DNS stream')
        data += chunk
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('binary')
    parser.add_argument('generated_tun_config')
    args = parser.parse_args()
    config = json.loads(Path(args.generated_tun_config).read_text())
    tag = 'pendingnet-system-dns'
    entry = next(x for x in config['inbounds'] if x.get('tag') == tag)
    assert entry['listen'] == '127.0.0.1' and entry['listen_port'] == 53
    assert entry['type'] == 'direct' and 'network' not in entry
    rule = config['route']['rules'][0]
    assert rule == {'inbound': [tag], 'action': 'hijack-dns'}
    # Only the tested entry and its real first route rule survive. Upstream is a
    # synthetic loopback responder. No physical interfaces, VPS, DoH or rulesets.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as upstream:
        upstream.bind(('127.0.0.1', 0))
        upstream.settimeout(0.2)
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            entry_port = reservation.getsockname()[1]
        entry = dict(entry, listen_port=entry_port)
        isolated = {
            'log': {'level': 'warn'}, 'inbounds': [entry],
            'dns': {'servers': [{'type': 'udp', 'tag': 'test-upstream',
                                'server': '127.0.0.1', 'server_port': upstream.getsockname()[1]}],
                    'final': 'test-upstream'},
            'route': {'rules': [rule], 'final': 'direct'},
            'outbounds': [{'type': 'direct', 'tag': 'direct'}],
        }
        stop = threading.Event()
        queries = []

        def respond():
            while not stop.is_set():
                try:
                    request, peer = upstream.recvfrom(4096)
                except socket.timeout:
                    continue
                offset = 12
                while request[offset]:
                    offset += request[offset] + 1
                end = offset + 5
                qtype = struct.unpack('!H', request[offset + 1:offset + 3])[0]
                address = ipaddress.ip_address('198.51.100.7' if qtype == 1 else '2001:db8::7').packed
                queries.append(qtype)
                response = request[:2] + struct.pack('!HHHHH', 0x8180, 1, 1, 0, 0)
                response += request[12:end]
                response += b'\xc0\x0c' + struct.pack('!HHIH', qtype, 1, 30, len(address)) + address
                upstream.sendto(response, peer)

        thread = threading.Thread(target=respond)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix='pendingnet-dns-entry-') as directory:
                path = Path(directory) / 'config.json'
                path.write_text(json.dumps(isolated))
                subprocess.run([args.binary, 'check', '-c', str(path)], check=True, timeout=5)
                with (Path(directory) / 'engine.log').open('w+') as log:
                    engine = subprocess.Popen([args.binary, 'run', '-c', str(path)], stdout=log, stderr=log)
                    try:
                        deadline = time.monotonic() + 5
                        while True:
                            try:
                                with socket.create_connection(('127.0.0.1', entry_port), timeout=0.2):
                                    break
                            except OSError:
                                if engine.poll() is not None or time.monotonic() >= deadline:
                                    log.seek(0)
                                    raise RuntimeError('DNS entry startup failed: ' + log.read())
                                time.sleep(0.05)
                        for transport in ('udp', 'tcp'):
                            for qtype in (1, 28):
                                query = struct.pack('!HHHHHH', 0x1234, 0x0100, 1, 0, 0, 0)
                                query += b'\x04test\x07example\x07invalid\x00' + struct.pack('!HH', qtype, 1)
                                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM if transport == 'udp' else socket.SOCK_STREAM) as client:
                                    client.settimeout(2)
                                    client.connect(('127.0.0.1', entry_port))
                                    if transport == 'udp':
                                        client.send(query); answer = client.recv(4096)
                                    else:
                                        client.sendall(struct.pack('!H', len(query)) + query)
                                        answer = exact(client, struct.unpack('!H', exact(client, 2))[0])
                                address = ipaddress.ip_address('198.51.100.7' if qtype == 1 else '2001:db8::7').packed
                                assert answer[:2] == query[:2] and answer[3] & 15 == 0
                                assert answer.endswith(address), (transport, qtype, answer.hex())
                                print(f'PASS {transport.upper()} {"A" if qtype == 1 else "AAAA"}')
                        assert {1, 28}.issubset(queries)
                    finally:
                        engine.terminate()
                        try:
                            engine.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            engine.kill(); engine.wait(timeout=3)
        finally:
            stop.set(); thread.join(timeout=1)


if __name__ == '__main__':
    main()
