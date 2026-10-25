"""Disposable loopback S3 fixture: real SigV4 verification, flat objects, no request/secret logs."""

from datetime import datetime, timezone
from email.utils import formatdate
from hashlib import md5
from http.server import BaseHTTPRequestHandler
import json
import hashlib
import hmac
import re
import os
from pathlib import Path
import sys
import threading
from urllib.parse import parse_qs, unquote, urlsplit
from xml.sax.saxutils import escape

from loopback_http_server import LoopbackHTTPServer
from s3_fixture_auth import authorized as s3_authorized


def decode_chunks(payload, headers):
    fields = dict(item.strip().split("=", 1) for item in headers["Authorization"][17:].split(","))
    credential = fields["Credential"].split("/")
    key = ("AWS4" + os.environ["FIXTURE_SECRET"]).encode()
    for value in credential[1:]:
        key = hmac.new(key, value.encode(), hashlib.sha256).digest()
    previous = fields["Signature"]
    result = bytearray()
    while payload:
        match = re.match(rb"([0-9a-fA-F]+);chunk-signature=([0-9a-f]+)\r\n", payload)
        if not match:
            raise ValueError("Invalid signed chunk")
        count = int(match[1], 16)
        body = payload[match.end():match.end() + count]
        if len(body) != count or payload[match.end() + count:match.end() + count + 2] != b"\r\n":
            raise ValueError("Truncated chunk")
        text = "\n".join(("AWS4-HMAC-SHA256-PAYLOAD", headers["X-Amz-Date"], "/".join(credential[1:]),
                           previous, hashlib.sha256(b"").hexdigest(), hashlib.sha256(body).hexdigest()))
        expected = hmac.new(key, text.encode(), hashlib.sha256).hexdigest()
        previous = match[2].decode()
        if not hmac.compare_digest(expected, previous):
            raise ValueError("Invalid chunk signature")
        result.extend(body)
        payload = payload[match.end() + count + 2:]
        if count == 0:
            if payload:
                raise ValueError("Unexpected trailer")
            return bytes(result)
    raise ValueError("Missing final chunk")


def run(storage):
    storage.mkdir(mode=0o700)
    objects = {}  # Names stay in memory; hashed disk names cannot escape the disposable directory.
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            self.serve()

        def do_HEAD(self):
            self.serve()

        def do_PUT(self):
            self.serve()

        def do_DELETE(self):
            self.serve()

        def respond(self, status, payload=b"", headers=None):
            self.send_response(status)
            self.send_header("Content-Length", str(len(payload)))
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.end_headers()
            if self.command != "HEAD":
                try:
                    self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        def serve(self):
            if not s3_authorized(self.command, self.path, self.headers, os.environ["FIXTURE_ACCESS"],
                                 os.environ["FIXTURE_SECRET"], os.environ["FIXTURE_TOKEN"], methods=("GET", "HEAD", "PUT", "DELETE")):
                self.respond(403, b"<Error><Code>AccessDenied</Code></Error>")
                return
            path = unquote(urlsplit(self.path).path)
            if not path.startswith("/bucket/"):
                self.respond(404)
                return
            key = path[len("/bucket/"):]
            query = parse_qs(urlsplit(self.path).query)
            with lock:
                if not key:
                    prefix = query.get("prefix", [""])[0]
                    items = []
                    for name, (file, date, etag) in sorted(objects.items()):
                        if name.startswith(prefix):
                            items.append("<Contents><Key>" + escape(name) + "</Key><LastModified>"
                                         + datetime.fromtimestamp(date, timezone.utc).isoformat().replace("+00:00", "Z")
                                         + "</LastModified><ETag>&quot;" + etag + "&quot;</ETag><Size>"
                                         + str(file.stat().st_size) + "</Size><StorageClass>STANDARD</StorageClass></Contents>")
                    payload = ('<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                               '<Name>bucket</Name><IsTruncated>false</IsTruncated>' + "".join(items)
                               + '</ListBucketResult>').encode()
                    self.respond(200, payload, {"Content-Type": "application/xml"})
                elif self.command == "PUT":
                    length = int(self.headers.get("Content-Length", "-1"))
                    if not 0 <= length <= 8 * 1024 * 1024:
                        self.respond(413)
                        return
                    payload = self.rfile.read(length)
                    if self.headers.get("X-Amz-Content-Sha256", "").startswith("STREAMING-"):
                        try:
                            payload = decode_chunks(payload, self.headers)
                        except ValueError:
                            self.respond(403)
                            return
                    etag = md5(payload).hexdigest()
                    file = storage / md5(key.encode()).hexdigest()
                    file.write_bytes(payload)
                    objects[key] = (file, file.stat().st_mtime, etag)
                    self.respond(200, headers={"ETag": '"' + etag + '"'})
                elif self.command == "DELETE":
                    if key in objects:
                        objects.pop(key)[0].unlink()
                    self.respond(204)
                elif key not in objects:
                    self.respond(404, b"<Error><Code>NoSuchKey</Code></Error>")
                else:
                    file, date, etag = objects[key]
                    payload = file.read_bytes()
                    headers = {"ETag": '"' + etag + '"', "Last-Modified": formatdate(date, usegmt=True)}
                    ranged = self.headers.get("Range", "")
                    if ranged.startswith("bytes="):
                        first, last = ranged[6:].split("-", 1)
                        start, end = int(first), min(int(last), len(payload) - 1) if last else len(payload) - 1
                        headers["Content-Range"] = f"bytes {start}-{end}/{len(payload)}"
                        payload = payload[start:end + 1]
                    self.respond(206 if ranged else 200, payload, headers)

    server = LoopbackHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        print(json.dumps({"port": server.server_port}), flush=True)
        sys.stdin.buffer.read(1)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


if __name__ == "__main__":
    run(Path(sys.argv[1]))
