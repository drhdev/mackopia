#!/usr/bin/env python3
"""Fail early if the isolated native HTTP fixtures cannot start; never log handshakes."""
from pathlib import Path
import subprocess
import secrets
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix="mackopia-python-check-") as directory:
    environment = {"HOME": directory, "TMPDIR": directory, "LANG": "en_US.UTF-8",
                   "PYTHONDONTWRITEBYTECODE": "1",
                   "FIXTURE_USER": secrets.token_hex(24), "FIXTURE_PASSWORD": secrets.token_hex(24)}
    for name, arguments in [
        ("native_tls_fixture.py", ["policy-read", directory]),
        ("native_webdav_fixture.py", [str(Path(directory) / "storage")]),
    ]:
        child = subprocess.Popen(
            [sys.executable, str(Path(__file__).with_name(name)), *arguments],
            env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            output, _ = child.communicate(input=b"", timeout=30)
            if child.returncode != 0 or not output:
                raise RuntimeError(f"{name}: isolated startup failed (exit {child.returncode})")
            print(f"{name}: isolated startup passed", flush=True)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
