#!/usr/bin/env python3
"""Check the isolated runtime used by native Swift HTTP fixtures, without credentials."""
from pathlib import Path
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix="mackopia-python-check-") as directory:
    program = """
import sys
print('interpreter ready', flush=True)
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
print('HTTP/TLS imports ready', flush=True)
assert ssl.HAS_TLSv1_3
server = ThreadingHTTPServer(('127.0.0.1', 0), BaseHTTPRequestHandler)
print('loopback bind ready', flush=True)
server.server_close()
"""
    environment = {"HOME": directory, "TMPDIR": directory, "LANG": "en_US.UTF-8",
                   "PYTHONDONTWRITEBYTECODE": "1"}
    subprocess.run([sys.executable, "-c", program], env=environment, check=True, timeout=30)
    for name, arguments in [
        ("native_tls_fixture.py", ["policy-read", directory]),
        ("native_webdav_fixture.py", [str(Path(directory) / "storage")]),
    ]:
        environment.update(FIXTURE_USER="startup-check", FIXTURE_PASSWORD="startup-check")
        child = subprocess.Popen(
            [sys.executable, str(Path(__file__).with_name(name)), *arguments],
            env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            output, diagnostics = child.communicate(input=b"", timeout=30)
            if child.returncode != 0 or not output:
                raise RuntimeError(f"{name}: isolated startup failed (exit {child.returncode})")
            print(f"{name}: isolated startup passed", flush=True)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
