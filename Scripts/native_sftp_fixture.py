"""Disposable loopback SSH server; private keys leave only through the parent pipe."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import secrets
import sys

from sftp_probe_fixture import ssh_fixture

SPEC = importlib.util.spec_from_file_location("sftp_input", Path(__file__).with_name("spike-kopia-sftp-input.py"))
INPUT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INPUT)


def interrupted(_signal, _frame):
    raise SystemExit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    root = Path(sys.argv[1])
    environment = {"HOME": str(root), "TMPDIR": str(root), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    key = INPUT.generate_key(environment)
    wrong = INPUT.generate_key(environment)
    passphrase = secrets.token_hex(24)
    encrypted = INPUT.encrypt_key(key, passphrase, environment)
    with ssh_fixture(root / "ssh", key, INPUT.generate_key, environment) as (ssh, _):
        storage = root / "storage"
        storage.mkdir(mode=0o700)
        public = (root / "ssh/host.pub").read_text().split()
        print(json.dumps({**ssh, "privateKey": key.decode(), "wrongKey": wrong.decode(),
                          "hostKey": " ".join(public[:2]), "encryptedKey": encrypted.decode(), "passphrase": passphrase}), flush=True)
        sys.stdin.buffer.read(1)
