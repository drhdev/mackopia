"""Disposable TLS adversary for Swift tests. Private key and credentials only live in memory/pipes."""

import base64
import hashlib
import json
from http.server import BaseHTTPRequestHandler
from loopback_http_server import LoopbackHTTPServer
import os
from pathlib import Path
import secrets
import socket
import ssl
import subprocess
import sys
import threading
from urllib.parse import parse_qs, urlsplit

LIMIT = 4 * 1024 * 1024


def context_and_certificate():
    result = subprocess.run([
        "/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
        "-subj", "/CN=127.0.0.1", "-sha256", "-addext", "subjectAltName=IP:127.0.0.1",
        "-addext", "extendedKeyUsage=serverAuth", "-addext", "keyUsage=digitalSignature,keyEncipherment",
        "-addext", "basicConstraints=critical,CA:FALSE",
        "-keyout", "/dev/stdout", "-out", "/dev/stdout",
    ], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True, timeout=15)
    pem = result.stdout
    begin = pem.index(b"-----BEGIN CERTIFICATE-----")
    end = pem.index(b"-----END CERTIFICATE-----") + len(b"-----END CERTIFICATE-----")
    certificate = pem[begin:end] + b"\n"
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    readers = []
    try:
        # load_cert_chain opens each path separately: give it independent anonymous pipe copies.
        for _ in range(2):
            reader, writer = os.pipe()
            readers.append(reader)
            try:
                if os.write(writer, pem) != len(pem):
                    raise RuntimeError("incomplete fixture key delivery")
            finally:
                os.close(writer)
        context.load_cert_chain(f"/dev/fd/{readers[0]}", f"/dev/fd/{readers[1]}")
    finally:
        for reader in readers:
            os.close(reader)
    return context, certificate


def main():
    mode, directory = sys.argv[1], Path(sys.argv[2])
    context, certificate = context_and_certificate()
    password = secrets.token_hex(24)
    control_password = secrets.token_hex(24)
    authorization = "Basic " + base64.b64encode(("mackopia:" + password).encode()).decode()
    control_authorization = "Basic " + base64.b64encode(("server-control:" + control_password).encode()).decode()
    cookie = secrets.token_hex(24)
    csrf = secrets.token_hex(24)

    def mark(name):
        (directory / name).touch(mode=0o600)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_POST(self):
            if self.path.startswith(("/api/v1/sources/upload?", "/api/v1/sources/cancel?")):
                length = int(self.headers.get("Content-Length", "0"))
                payload = self.rfile.read(length) if length <= 1024 else None
                if self.headers.get("Content-Type") != "application/json" or payload != b'{}':
                    mark("invalid-upload-body")
                self.do_GET()
                return
            if self.path.startswith("/api/v1/policy/resolve?"):
                mark("policy-resolve-request")
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length)) if length <= 1024 * 1024 + 64 else None
                self.proposal = payload.get("updates") if isinstance(payload, dict) else None
                valid = (self.headers.get("Content-Type") == "application/json"
                         and (payload == {"numUpcomingSnapshotTimes": 0}
                              or (mode == "policy-write" and isinstance(self.proposal, dict)
                                  and payload == {"numUpcomingSnapshotTimes": 0, "updates": self.proposal})))
                if not valid:
                    mark("invalid-policy-body")
                self.do_GET()
                return
            mark("control-request")
            valid = (self.path == "/api/v1/control/shutdown"
                     and self.headers.get("Authorization") == control_authorization
                     and self.headers.get("Cookie") is None
                     and self.headers.get("X-Kopia-CSRF-Token") is None)
            if not valid:
                mark("invalid-control")
            status = 200 if valid else 403
            if valid and mode == "control-denied":
                status = 401
            if valid and mode == "control-redirect":
                status = 307
            self.send_response(status)
            if status == 307:
                self.send_header("Location", f"https://127.0.0.1:{sink.server_port}/forbidden")
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.close_connection = True

        def do_PUT(self):
            mark("policy-write-request")
            length = int(self.headers.get("Content-Length", "0"))
            self.write_document = json.loads(self.rfile.read(length)) if length <= 1024 * 1024 else None
            if (self.headers.get("Content-Type") != "application/json"
                    or not isinstance(self.write_document, dict)):
                mark("invalid-policy-body")
            self.do_GET()

        def do_GET(self):
            try:
                if self.path == "/forbidden":
                    mark("redirect-followed")
                    self.send_response(200)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if self.headers.get("Authorization") != authorization:
                    mark("invalid-auth")
                    self.send_response(403)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                root = self.path == "/"
                if root:
                    mark("bootstrap-request")
                if not root and (self.headers.get("Cookie") != "Kopia-Session-Cookie=" + cookie
                                 or self.headers.get("X-Kopia-CSRF-Token") != csrf):
                    mark("invalid-csrf")
                    self.send_response(403)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                active = (root and mode == "cancel-root") or (not root and mode == "cancel-api")
                if active:
                    self.send_response(200)
                    self.send_header("Content-Length", "1048576")
                    self.end_headers()
                    self.wfile.write(b'{"padding":"' + b"x" * 65_536)
                    self.wfile.flush()
                    mark("active")
                    self.connection.settimeout(10)
                    if not self.connection.recv(1):
                        mark("peer-closed")
                    return
                if not root and mode in ("redirect-same", "redirect-other"):
                    self.send_response(302)
                    port = server.server_port if mode == "redirect-same" else sink.server_port
                    self.send_header("Location", f"https://127.0.0.1:{port}/forbidden")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    mark("redirect-sent")
                    return
                if (root and mode == "root-declared") or (not root and mode == "declared"):
                    self.send_response(200)
                    self.send_header("Content-Length", str(LIMIT + 1))
                    self.end_headers()
                    self.wfile.write(b"x" * 65_536)
                    self.wfile.flush()
                    # Flush a TLS-sized prefix, then leave the body open: test header rejection, not premature EOF.
                    self.connection.settimeout(10)
                    if not self.connection.recv(1):
                        mark("peer-closed")
                    return
                if root:
                    body = f'<meta name="kopia-csrf-token" content="{csrf}">'.encode()
                    self.send_response(200)
                    self.send_header("Set-Cookie", f"Kopia-Session-Cookie={cookie}; Path=/; Secure; HttpOnly")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if mode.startswith("upload-"):
                    selector = parse_qs(urlsplit(self.path).query)
                    if selector != {"userName": ["user+tag"], "host": ["host+tag"],
                                    "path": ["/Source ü + & ? # %2F"]}:
                        mark("invalid-upload-selector")
                    mark("upload-request" if "/upload?" in self.path else "cancel-request")
                    key = "user+tag@host+tag:/Source ü + & ? # %2F"
                    response = {"sources": {key: {"success": mode != "upload-rejected"}}}
                    if mode == "upload-empty":
                        response = {"sources": {}}
                    if mode == "upload-foreign":
                        response = {"sources": {"foreign": {"success": True}}}
                    if mode == "upload-extra":
                        response["sources"]["foreign"] = {"success": True}
                    body = json.dumps(response).encode()
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if mode.startswith("policy-"):
                    mark("policy-request")
                    selector = parse_qs(urlsplit(self.path).query)
                    if selector != {"userName": ["user+tag"], "host": ["host+tag"],
                                    "path": ["/Source ü + & ? # %2F"]}:
                        mark("invalid-policy-selector")
                    status = 200
                    body = b'{"retention":{"keepLatest":0}}'
                    if "/resolve?" in self.path:
                        body = b'{"defined":{},"effective":{"retention":{"keepLatest":0}}}'
                    if mode != "policy-read" and not mode.startswith("policy-definition-"):
                        status = 404 if mode == "policy-http404" else 400
                        body = b'{"code":"NOT_FOUND","error":"private details"}'
                    if mode == "policy-wrong-error":
                        body = b'{"code":"NOT_CONNECTED","error":"private details"}'
                    if mode == "policy-malformed":
                        body = b'{"code":[]}'
                    if mode.startswith("policy-definition-"):
                        bodies = {
                            "policy-definition-read": b'{"future":{"number":9007199254740993,"huge":184467440737095516160,"decimal":1.234567890123456789},"files":{"ignore":["private pattern"],"future":true},"retention":{"keepLatest":0},"scheduling":{"intervalSeconds":3600}}',
                            "policy-definition-array": b'[]',
                            "policy-definition-null": b'null',
                            "policy-definition-malformed": b'{',
                            "policy-definition-duplicate": b'{"files":{},"f\\u0069les":{}}',
                            "policy-definition-section": b'{"files":{"ignore":[],"ignore":[]}}',
                            "policy-definition-type": b'{"compression":false}',
                            "policy-definition-depth": b'{"future":' + b'[' * 65 + b'0' + b']' * 65 + b'}',
                        }
                        body = bodies.get(mode, b'{}')
                        if mode in ("policy-definition-exact", "policy-definition-declared", "policy-definition-chunked"):
                            prefix, suffix = b'{"future":"', b'"}'
                            count = 1024 * 1024 + (mode != "policy-definition-exact")
                            body = prefix + b'x' * (count - len(prefix) - len(suffix)) + suffix
                        if mode == "policy-definition-chunked":
                            self.send_response(200)
                            self.send_header("Transfer-Encoding", "chunked")
                            self.end_headers()
                            for offset in range(0, len(body), 65_536):
                                chunk = body[offset:offset + 65_536]
                                self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                            self.wfile.write(b"0\r\n\r\n")
                            self.wfile.flush()
                            return
                    if mode == "policy-write":
                        status = 200
                        if self.command == "PUT":
                            server.policy_document = self.write_document
                            body = b'{}'
                        elif "/resolve?" in self.path:
                            proposal = getattr(self, "proposal", None)
                            body = json.dumps({"effective": proposal if proposal is not None else getattr(server, "policy_document", {})}).encode()
                        else:
                            body = json.dumps(getattr(server, "policy_document", {})).encode()
                    self.send_response(status)
                    self.send_header("Content-Length", str(LIMIT + 1 if mode == "policy-oversized" else len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                prefix, suffix = b'{"connected":false,"padding":"', b'"}'
                count = LIMIT if mode == "exact" else LIMIT + 1
                body = prefix + b"x" * (count - len(prefix) - len(suffix)) + suffix
                self.send_response(200)
                if mode == "exact":
                    self.send_header("Content-Length", str(len(body)))
                else:
                    self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                for offset in range(0, len(body), 65_536):
                    chunk = body[offset:offset + 65_536]
                    if mode != "exact":
                        self.wfile.write(f"{len(chunk):x}\r\n".encode())
                    self.wfile.write(chunk)
                    if mode != "exact":
                        self.wfile.write(b"\r\n")
                if mode != "exact":
                    self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                mark("peer-closed")
            except socket.timeout:
                mark("peer-timeout")
            finally:
                self.close_connection = True

    servers = []
    try:
        for _ in range(2):
            instance = LoopbackHTTPServer(("127.0.0.1", 0), Handler)
            instance.daemon_threads = True
            instance.socket = context.wrap_socket(instance.socket, server_side=True)
            servers.append(instance)
        server, sink = servers
        for instance in servers:
            threading.Thread(target=instance.serve_forever, daemon=True).start()
        der = ssl.PEM_cert_to_DER_cert(certificate.decode())
        print(f"SERVER ADDRESS: https://127.0.0.1:{server.server_port}")
        print("SERVER CERT SHA256: " + hashlib.sha256(der).hexdigest())
        print("SERVER CERTIFICATE: " + base64.b64encode(certificate).decode())
        print("SERVER PASSWORD: " + password)
        print("SERVER CONTROL PASSWORD: " + control_password, flush=True)
        sys.stdin.buffer.read(1)
    finally:
        for instance in servers:
            instance.shutdown()
            instance.server_close()


if __name__ == "__main__":
    main()
