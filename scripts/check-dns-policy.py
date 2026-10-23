#!/usr/bin/env python3
"""Test generated DNS/resolve rules with local TLS DoH and HTTP servers only.

No TUN, system settings, real nodes or external DNS are used. The production
rules are retained; rule-set contents and upstream endpoints are test fixtures.
"""
import argparse
import copy
import http.client
import http.server
import json
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path


def port():
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        return reservation.getsockname()[1]


def question(data):
    offset, labels = 12, []
    while data[offset]:
        length = data[offset]
        labels.append(data[offset + 1:offset + 1 + length].decode())
        offset += length + 1
    return ".".join(labels), struct.unpack("!H", data[offset + 1:offset + 3])[0], offset + 5


def dns_query(entry, name):
    wire = b"".join(bytes([len(label)]) + label.encode() for label in name.split(".")) + b"\0"
    request = struct.pack("!HHHHHH", 1234, 0x100, 1, 0, 0, 0) + wire + struct.pack("!HH", 1, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.settimeout(5)
        client.sendto(request, ("127.0.0.1", entry))
        return client.recv(4096)


class DoH(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        request = self.rfile.read(int(self.headers["Content-Length"]))
        name, kind, end = question(request)
        self.server.queries.append(name)
        answer = request[:2] + struct.pack("!HHHHH", 0x8180, 1, int(kind == 1), 0, 0) + request[12:end]
        if kind == 1:
            answer += b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 30, 4) + socket.inet_aton("127.0.0.1")
        self.send_response(200)
        self.send_header("Content-Type", "application/dns-message")
        self.send_header("Content-Length", str(len(answer)))
        self.end_headers()
        self.wfile.write(answer)


class Target(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")


class TLSServer(http.server.ThreadingHTTPServer):
    handshake_errors = 0

    def get_request(self):
        try:
            return super().get_request()
        except ssl.SSLError:
            self.handshake_errors += 1
            raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("configs", nargs="+")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="pendingnet-dns-policy-") as temp:
        directory = Path(temp)
        cert, key = directory / "cert.pem", directory / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=dns.test", "-addext", "subjectAltName=DNS:dns.test",
                        "-keyout", str(key), "-out", str(cert)], check=True, capture_output=True)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        upstreams = {}
        target = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Target)
        servers = [target]
        for tag in ("dns-direct", "dns-proxy"):
            server = TLSServer(("127.0.0.1", 0), DoH)
            server.socket = context.wrap_socket(server.socket, server_side=True)
            server.queries = []
            upstreams[tag] = server
            servers.append(server)
        threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in servers]
        for thread in threads:
            thread.start()
        try:
            for input_path in args.configs:
                config = json.loads(Path(input_path).read_text())
                entry, mixed, control = port(), port(), port()
                config["inbounds"] = [
                    {"type": "direct", "tag": "pendingnet-system-dns", "listen": "127.0.0.1", "listen_port": entry},
                    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": mixed},
                ]
                rules = config["route"]["rules"]
                if rules[0].get("inbound") != ["pendingnet-system-dns"]:
                    rules.insert(0, {"inbound": ["pendingnet-system-dns"], "action": "hijack-dns"})
                config["outbounds"] = [{"type": "direct", "tag": tag} for tag in ("direct", "proxy")]
                config["experimental"] = {"clash_api": {"external_controller": f"127.0.0.1:{control}", "default_mode": "Global"}}
                config["route"].pop("find_process", None)
                config["log"] = {"level": "warn"}
                for rule_set in config["route"].get("rule_set", []):
                    tag = rule_set["tag"]
                    suffix = {"geosite-cn": "cn.test", "geosite-gfw": "gfw.test"}.get(tag, "unused.test")
                    source = directory / (tag + ".json")
                    output = directory / (tag + ".srs")
                    source.write_text(json.dumps({"version": 3, "rules": [{"domain_suffix": [suffix]}]}))
                    subprocess.run([args.binary, "rule-set", "compile", str(source), "-o", str(output)], check=True, capture_output=True)
                    rule_set.clear()
                    rule_set.update(type="local", tag=tag, format="binary", path=str(output))
                for upstream in config["dns"]["servers"]:
                    assert upstream["type"] == "https", "production resolver is not encrypted"
                    server = upstreams[upstream["tag"]]
                    upstream.update(server="127.0.0.1", server_port=server.server_port,
                                    tls={"enabled": True, "server_name": "dns.test", "certificate_path": str(cert)})
                    upstream.pop("detour", None)
                for invalid_certificate in (False, True):
                    isolated = copy.deepcopy(config)
                    if invalid_certificate:
                        for upstream in isolated["dns"]["servers"]:
                            if upstream["tag"] == "dns-proxy":
                                upstream["tls"]["server_name"] = "wrong.test"
                    path = directory / "config.json"
                    path.write_text(json.dumps(isolated))
                    subprocess.run([args.binary, "check", "-c", str(path)], check=True, capture_output=True)
                    with (directory / "engine.log").open("w+") as log:
                        engine = subprocess.Popen([args.binary, "run", "-c", str(path)], stdout=log, stderr=log)
                        try:
                            deadline = time.monotonic() + 5
                            while True:
                                try:
                                    with socket.create_connection(("127.0.0.1", control), timeout=0.1):
                                        break
                                except OSError:
                                    if engine.poll() is not None or time.monotonic() > deadline:
                                        log.seek(0)
                                        raise RuntimeError(log.read())
                                    time.sleep(0.02)
                            if invalid_certificate:
                                name = "certificate.other.test"
                                for upstream in upstreams.values():
                                    upstream.queries.clear()
                                    upstream.handshake_errors = 0
                                try:
                                    answer = dns_query(entry, name)
                                    assert answer[3] & 15 != 0, "invalid TLS certificate was accepted"
                                except socket.timeout:
                                    # sing-box may drop the failed exchange. The
                                    # local TLS server must observe the rejection.
                                    assert upstreams["dns-proxy"].handshake_errors > 0, "no TLS rejection observed"
                                assert not upstreams["dns-direct"].queries, "TLS failure fell back to direct DNS"
                                continue
                            for mode in ("Global", "Whitelist", "Blacklist"):
                                connection = http.client.HTTPConnection("127.0.0.1", control, timeout=5)
                                connection.request("PATCH", "/configs", json.dumps({"mode": mode}), {"Content-Type": "application/json"})
                                response = connection.getresponse()
                                assert response.status == 204
                                response.read()
                                connection.close()
                                for suffix in ("cn.test", "gfw.test", "other.test"):
                                    expected = "dns-direct" if (mode == "Whitelist" and suffix == "cn.test") or (mode == "Blacklist" and suffix != "gfw.test") else "dns-proxy"
                                    for kind in ("dns", "http"):
                                        name = f"{kind}-{mode.lower()}.{suffix}"
                                        for upstream in upstreams.values():
                                            upstream.queries.clear()
                                        if kind == "dns":
                                            answer = dns_query(entry, name)
                                            assert answer[3] & 15 == 0
                                        else:
                                            connection = http.client.HTTPConnection("127.0.0.1", mixed, timeout=5)
                                            connection.request("GET", f"http://{name}:{target.server_port}/")
                                            response = connection.getresponse()
                                            assert response.status == 200 and response.read() == b"ok"
                                            connection.close()
                                        observed = {tag for tag, upstream in upstreams.items() if name in upstream.queries}
                                        assert observed == {expected}, (Path(input_path).name, mode, suffix, kind, expected, observed)
                            print(f"PASS {Path(input_path).name}: 18 DNS/HTTP paths over verified local DoH", flush=True)
                        finally:
                            engine.terminate()
                            try:
                                engine.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                engine.kill()
                                engine.wait()
                print(f"PASS {Path(input_path).name}: TLS mismatch rejects without direct fallback", flush=True)
        finally:
            for server in servers:
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    main()
