"""Loopback-only subprocess fixture for Swift integration tests; secrets stay in environment/memory."""

import importlib.util
import json
import os
from pathlib import Path
import sys

SPEC = importlib.util.spec_from_file_location("backends", Path(__file__).with_name("spike-kopia-secrets.py"))
BACKENDS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BACKENDS)

if __name__ == "__main__":
    storage = Path(sys.argv[1])
    storage.mkdir(mode=0o700)
    with BACKENDS.storage_server(storage, os.environ["FIXTURE_USER"], os.environ["FIXTURE_PASSWORD"],
                                 "unused-access", "unused-token", "unused-key") as (port, _):
        print(json.dumps({"port": port}), flush=True)
        sys.stdin.buffer.read(1)
