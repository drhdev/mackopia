#!/usr/bin/env python3
"""Check the isolated runtime used by native Swift HTTP fixtures, without credentials."""
import os
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
