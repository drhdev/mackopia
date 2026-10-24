#!/usr/bin/python3
"""Probe pinned backend credential handling with disposable loopback-only storage."""

import argparse
import base64
from datetime import datetime, timezone
from email.utils import formatdate
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler
from loopback_http_server import LoopbackHTTPServer
import importlib.util
import json
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import threading
from urllib.parse import parse_qs, quote, unquote, urlsplit
from xml.sax.saxutils import escape

from s3_fixture_auth import authorized as s3_authorized

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("cli_spike", Path(__file__).with_name("spike-kopia-cli.py"))
CLI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLI)


@contextmanager
def storage_server(repository, username, password, access_key, session_token, secret_key):
    """Serve only fixture objects. HTTP is confined to this disposable test endpoint."""
    observations = {"webdavAuthenticated": False, "s3Authenticated": False}
    basic = "Basic " + base64.b64encode((username + ":" + password).encode()).decode()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            # Request headers and URLs must never enter logs.
            pass

        def do_OPTIONS(self):
            self.serve(head=True)

        def do_PROPFIND(self):
            self.serve(head=False)

        def do_PUT(self):
            self.serve(head=False)

        def do_MKCOL(self):
            self.serve(head=False)

        def do_MOVE(self):
            self.serve(head=False)

        def do_DELETE(self):
            self.serve(head=False)

        def do_HEAD(self):
            self.serve(head=True)

        def do_GET(self):
            self.serve(head=False)

        def serve(self, head):
            path = unquote(urlsplit(self.path).path)
            auth = self.headers.get("Authorization", "")
            if path.startswith("/bucket/"):
                authorized = s3_authorized(self.command, self.path, self.headers,
                                           access_key, secret_key, session_token)
                observations["s3Authenticated"] |= authorized
                relative = path[len("/bucket/"):]
            else:
                authorized = auth == basic
                observations["webdavAuthenticated"] |= authorized
                relative = path.lstrip("/")
            if not authorized:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="fixture"')
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            target = (repository / relative).resolve()
            # Filesystem/WebDAV shard objects and append .f; S3 uses flat blob names.
            if path.startswith("/bucket/") and not target.exists() and "/" not in relative:
                matches = list(repository.rglob(relative + ".f"))
                if len(matches) == 1:
                    target = matches[0].resolve()
            if not target.is_relative_to(repository.resolve()):
                self.send_response(403)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if self.command in ("PUT", "MKCOL", "DELETE", "MOVE"):
                if self.command == "PUT":
                    length = int(self.headers.get("Content-Length", "0"))
                    if not 0 <= length <= 4 * 1024 * 1024:
                        self.send_error(413)
                        return
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(self.rfile.read(length))
                elif self.command == "MKCOL":
                    target.mkdir(parents=True, exist_ok=True)
                elif self.command == "MOVE":
                    destination_url = urlsplit(self.headers.get("Destination", ""))
                    destination = (repository / unquote(destination_url.path).lstrip("/")).resolve()
                    if (destination_url.hostname != "127.0.0.1" or destination_url.port != self.server.server_port
                            or not destination.is_relative_to(repository.resolve()) or not target.is_file()):
                        self.send_error(403)
                        return
                    target.replace(destination)
                elif target.is_file():
                    target.unlink()
                self.send_response(204 if self.command == "DELETE" else 201)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if not target.exists():
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if self.command == "PROPFIND":
                entries = [target]
                if target.is_dir() and self.headers.get("Depth") != "0":
                    entries += list(target.iterdir())
                items = []
                for entry in entries:
                    name = "/" + entry.relative_to(repository.resolve()).as_posix()
                    resource = "<d:collection/>" if entry.is_dir() else ""
                    items.append(
                        "<d:response><d:href>" + escape(quote(name)) + "</d:href><d:propstat><d:prop>"
                        + "<d:resourcetype>" + resource + "</d:resourcetype>"
                        + "<d:getcontentlength>" + str(entry.stat().st_size) + "</d:getcontentlength>"
                        + "<d:getlastmodified>" + formatdate(entry.stat().st_mtime, usegmt=True) + "</d:getlastmodified>"
                        + "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
                    )
                content = ('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">' + "".join(items)
                           + "</d:multistatus>").encode()
            elif path == "/bucket/":
                items = []
                for entry in repository.rglob("*.f"):
                    prefix = parse_qs(urlsplit(self.path).query).get("prefix", [""])[0]
                    if not entry.name[:-2].startswith(prefix):
                        continue
                    items.append("<Contents><Key>" + escape(entry.name[:-2]) + "</Key>"
                                 + "<LastModified>" + datetime.fromtimestamp(entry.stat().st_mtime, timezone.utc).isoformat().replace("+00:00", "Z") + "</LastModified>"
                                 + '<ETag>"fixture"</ETag><Size>' + str(entry.stat().st_size)
                                 + "</Size><StorageClass>STANDARD</StorageClass></Contents>")
                content = ('<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                           + "<Name>bucket</Name><IsTruncated>false</IsTruncated>"
                           + "".join(items) + "</ListBucketResult>").encode()
            else:
                content = target.read_bytes() if target.is_file() else b""

            total = len(content)
            start, end = 0, total - 1
            ranged = self.headers.get("Range", "")
            if ranged.startswith("bytes=") and target.is_file():
                first, last = ranged[6:].split("-", 1)
                start = int(first)
                end = min(int(last), end) if last else end
                content = content[start:end + 1]
            self.send_response(206 if ranged and target.is_file() else 207 if self.command == "PROPFIND" else 200)
            if ranged and target.is_file():
                self.send_header("Content-Range", "bytes " + str(start) + "-" + str(end) + "/" + str(total))
            self.send_header("DAV", "1, 2")
            self.send_header("Content-Length", str(len(content)))
            self.send_header("Content-Type", "application/xml" if self.command == "PROPFIND" else "application/octet-stream")
            self.send_header("ETag", '"fixture"')
            self.send_header("Last-Modified", formatdate(target.stat().st_mtime, usegmt=True))
            self.end_headers()
            if not head:
                try:
                    self.wfile.write(content)
                except (BrokenPipeError, ConnectionResetError):
                    pass

    server = LoopbackHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_address[1], observations
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        if thread.is_alive():
            raise RuntimeError("Fixture server failed to stop")


def invoke(spike, arguments, extra_env=None):
    result = subprocess.run(
        spike.base + arguments, env=spike.env | (extra_env or {}), cwd=spike.working,
        stdin=subprocess.DEVNULL, capture_output=True, timeout=30, start_new_session=True,
    )
    # Keep raw output in memory only: it can contain backend options.
    return result


def execute(directory, binary):
    root = Path(directory)
    (root / "seed").mkdir(mode=0o700)
    seed = CLI.Spike(str(root / "seed"), binary)
    seed.run(
        "repository", "create", "filesystem", "--path=" + str(root / "storage"),
        "--cache-directory=" + str(seed.root / "cache"), "--no-check-for-updates",
        "--override-hostname=test-host", "--override-username=test-user",
    )
    config = (seed.root / "repository.config").read_bytes()
    if seed.password.encode() in config:
        raise RuntimeError("Repository password unexpectedly persisted")
    username, password, access_key, secret_key, token = [secrets.token_hex(24) for _ in range(5)]
    report = {"version": seed.run("--version").strip(), "filesystemPasswordNotPersisted": True}
    with storage_server(root / "storage", username, password, access_key, token, secret_key) as (port, observations):
        cases = {
            "webdav": (
                ["--url=http://127.0.0.1:" + str(port)],
                {"KOPIA_WEBDAV_USERNAME": username, "KOPIA_WEBDAV_PASSWORD": password},
                {"password": password},
            ),
            "s3": (
                ["--bucket=bucket", "--endpoint=127.0.0.1:" + str(port), "--region=us-east-1", "--disable-tls"],
                {"AWS_ACCESS_KEY_ID": access_key, "AWS_SECRET_ACCESS_KEY": secret_key, "AWS_SESSION_TOKEN": token},
                {"accessKeyID": access_key, "secretAccessKey": secret_key, "sessionToken": token},
            ),
        }
        for backend, (flags, env, expected) in cases.items():
            (root / backend).mkdir(mode=0o700)
            spike = CLI.Spike(str(root / backend), binary)
            spike.env["KOPIA_PASSWORD"] = seed.password
            result = invoke(spike, ["repository", "connect", backend, *flags,
                                    "--cache-directory=" + str(spike.root / "cache"),
                                    "--no-check-for-updates", "--override-hostname=test-host",
                                    "--override-username=test-user"], env)
            if result.returncode:
                raise RuntimeError("Loopback credential probe failed for " + backend)
            stored = json.loads((spike.root / "repository.config").read_text())
            options = stored["storage"]["config"]
            persisted = all(options.get(key) == value for key, value in expected.items())
            if seed.password.encode() in (spike.root / "repository.config").read_bytes():
                raise RuntimeError("Repository password unexpectedly persisted")
            if not persisted or not observations[backend + "Authenticated"]:
                raise RuntimeError("Pinned backend credential contract changed for " + backend)
            report[backend] = {
                "environmentAccepted": True, "credentialsPersistedInConfig": persisted,
                "persistedFields": list(expected),
                "repositoryPasswordPersisted": seed.password.encode() in (spike.root / "repository.config").read_bytes(),
            }
            # Kopia 0.23.1: stored backend options can supersede the next process's environment.
            changed_env = {key: secrets.token_hex(24) for key in env}
            before = (spike.root / "repository.config").read_bytes()
            observations[backend + "Authenticated"] = False
            # Force a fresh format fetch rather than accepting the local format cache.
            shutil.rmtree(spike.root / "cache", ignore_errors=True)
            reopened = invoke(spike, ["repository", "status", "--json"], changed_env)
            if reopened.returncode or not observations[backend + "Authenticated"] or (spike.root / "repository.config").read_bytes() != before:
                raise RuntimeError("Reopen contract changed for " + backend)
            report[backend]["reopenWithChangedEnvironmentSucceeded"] = True
    (root / "sftp").mkdir(mode=0o700)
    sftp = CLI.Spike(str(root / "sftp"), binary)
    result = invoke(sftp, [
        "repository", "connect", "sftp", "--host=127.0.0.1", "--port=1", "--username=test-user",
        "--path=/fixture", "--known-hosts=" + str(root / "known_hosts"),
        "--cache-directory=" + str(sftp.root / "cache"), "--no-check-for-updates",
    ], {"KOPIA_SFTP_PASSWORD": password})
    missing_auth = b"must provide either --sftp-password, --keyfile or --key-data" in result.stderr
    if result.returncode == 0 or not missing_auth or (sftp.root / "repository.config").exists():
        raise RuntimeError("Pinned SFTP environment contract changed")
    report["sftp"] = {"passwordEnvironmentAccepted": False, "rejectedBeforeConnection": True}
    credential_values = (password, access_key, secret_key, token, seed.password)
    report["credentialsFoundInLogs"] = any(
        value.encode() in file.read_bytes()
        for file in root.rglob("*.log") if file.is_file()
        for value in credential_values
    )
    # Only a fixed-schema result leaves the temporary directory, never config or child output.
    encoded = json.dumps(report)
    if any(value in encoded for value in (username, password, access_key, secret_key, token, seed.password, str(root))):
        raise RuntimeError("Probe report contains private data")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    pin = json.loads((ROOT / "Config/kopia-version.json").read_text())
    with tempfile.TemporaryDirectory(prefix="mackopia-secrets-spike-") as directory:
        report = execute(directory, ROOT / "Vendor/kopia" / pin["version"] / "kopia")
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "secrets-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
