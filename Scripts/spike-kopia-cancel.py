#!/usr/bin/env python3
"""Verify clean REST cancellation and durable reuse against an isolated temporary repository."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import ssl
import tempfile
import time
from urllib.parse import urlencode

from kopia_server_probe import ProbeError, Server

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("server_spike", ROOT / "Scripts/spike-kopia-server.py")
SERVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SERVER)


def wait_for(read, complete, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = read()
        if complete(value):
            return value
        time.sleep(0.1)
    raise ProbeError("Cancellation probe operation timed out")


def source_status(client, query):
    sources = client.json("/api/v1/sources?" + query)["sources"]
    if len(sources) != 1:
        raise ProbeError("Expected exactly one isolated source")
    return sources[0]


def credentials(server):
    client = server.client
    return [client.password, client.control_password, client.session_cookie, client.csrf_token]


def execute(spike):
    spike.run("repository", "create", "filesystem", "--path=" + str(spike.root / "repository"),
              "--cache-directory=" + str(spike.root / "cache"), "--override-hostname=test-host",
              "--override-username=test-user", "--no-check-for-updates")
    source = spike.root / "source"
    source.mkdir()
    # Kopia 0.23.1 exposes this hidden flag only on CLI snapshot create, not policy/server.
    spike.run("snapshot", "create", str(source), "--checkpoint-interval=15m", "--json")
    hashes = {}
    # Independent random files prevent compression/dedup from finishing before cancellation.
    for index in range(128):
        name = "generated-%03d.bin" % index
        data = os.urandom(2 * 1024 * 1024)
        (source / name).write_bytes(data)
        hashes[name] = hashlib.sha256(data).digest()
    query = urlencode({"userName": "test-user", "host": "test-host", "path": str(source)})
    fixtures = {}
    secrets = [spike.password]
    with Server(spike) as first:
        client = first.client
        client.request("/", bootstrap=True)
        client.json("/api/v1/repo/throttle", method="PUT", body={"maxUploadSpeedBytesPerSecond": 16 * 1024 * 1024})
        fixtures["cancel-throttle.json"] = client.json("/api/v1/repo/throttle")
        client.json("/api/v1/sources/upload?" + query, method="POST", body={})
        active = wait_for(lambda: source_status(client, query),
                          lambda s: s["status"] == "UPLOADING" and s.get("upload", {}).get("hashedFiles", 0) >= 16)
        fixtures["cancel-active-source.json"] = active
        start = time.monotonic()
        fixtures["cancel-response.json"] = client.json("/api/v1/sources/cancel?" + query, method="POST", body={})
        idle = wait_for(lambda: source_status(client, query), lambda s: s["status"] == "IDLE", timeout=30)
        cancel_seconds = time.monotonic() - start
        fixtures["cancel-idle-source.json"] = idle
        canceled = client.json("/api/v1/snapshots?" + query)
        fixtures["cancel-snapshots.json"] = canceled
        if not any(s.get("incomplete") == "canceled" for s in canceled["snapshots"]):
            raise ProbeError("Cancellation did not preserve an incomplete snapshot")
        secrets += credentials(first)
    if not first.clean_shutdown:
        raise ProbeError("Canceled server did not shut down on stdin EOF")
    # Restart the server to prove reuse comes from persisted state, not in-memory uploader state.
    with Server(spike) as resumed:
        client = resumed.client
        client.request("/", bootstrap=True)
        start = time.monotonic()
        client.json("/api/v1/sources/upload?" + query, method="POST", body={})
        def completed():
            status = source_status(client, query)
            snapshot = status.get("lastSnapshot", {})
            return status, snapshot
        idle, snapshot = wait_for(completed, lambda pair: pair[0]["status"] == "IDLE"
                                  and pair[1].get("stats", {}).get("totalSize") == 256 * 1024 * 1024
                                  and not pair[1].get("incomplete"))
        resume_seconds = time.monotonic() - start
        fixtures["resume-idle-source.json"] = idle
        if snapshot["stats"]["cachedFiles"] <= 0 or snapshot["stats"]["errorCount"] != 0:
            raise ProbeError("Resumed snapshot did not reuse completed files without errors")
        fixtures["resume-snapshots.json"] = client.json("/api/v1/snapshots?" + query)
        # Restore every generated file to a new directory; no silent overwrite is permitted.
        destination = spike.root / "restored"
        request = {"root": snapshot["rootEntry"]["obj"],
                   "fsOutput": {"targetPath": str(destination), "overwriteFiles": False,
                                "overwriteDirectories": False, "overwriteSymlinks": False, "writeFilesAtomically": True},
                   "options": {"restoreDirEntryAtDepth": 2147483647, "deleteExtra": False, "ignoreErrors": False}}
        task = client.json("/api/v1/restore", method="POST", body=request)
        SERVER.finished_task(client, task)
        if set(p.name for p in destination.iterdir()) != set(hashes):
            raise ProbeError("Resumed restore file set differs from source")
        if any(hashlib.sha256((destination / name).read_bytes()).digest() != digest for name, digest in hashes.items()):
            raise ProbeError("Resumed restore content differs from source")
        secrets += credentials(resumed)
    if not resumed.clean_shutdown:
        raise ProbeError("Resumed server did not shut down on stdin EOF")
    spike.run("snapshot", "verify", "--verify-files-percent=100")
    for path in [spike.root / "repository.config"] + list((spike.root / "logs").rglob("*")):
        if path.is_file() and any(secret.encode() in path.read_bytes() for secret in secrets):
            raise ProbeError("An ephemeral credential reached config or logs")
    for name, value in fixtures.items():
        if any(secret in json.dumps(value) for secret in secrets):
            raise ProbeError("A cancellation fixture contains an ephemeral credential")
        fixtures[name] = spike.scrub(value)
        if any(marker in json.dumps(fixtures[name]) for marker in ("/Users/", "/Volumes/", "/var/folders/", "/private/var/")):
            raise ProbeError("A cancellation fixture contains an unsanitized machine path")
    fixtures["cancel-report.json"] = {
        "checks": {"activeCounters": True, "apiCancel": True, "incompleteSnapshot": True,
                   "reuseAfterServerRestart": True, "restoreAllBytesMatch": True, "verifyAllFiles": True,
                   "stdinEOFShutdown": True, "credentialsNotPersisted": True, "cliCheckpoint15mAccepted": True},
        "generatedFiles": len(hashes), "generatedBytes": 256 * 1024 * 1024,
        "cachedFilesOnResume": snapshot["stats"]["cachedFiles"],
        "cancelSeconds": round(cancel_seconds, 3), "resumeSeconds": round(resume_seconds, 3),
        "serverCheckpointMinutes": 45, "serverCheckpointConfigurable": False,
        "timingNote": "No cold-run speed comparison; reuse is verified by cachedFiles and restored bytes.",
    }
    return fixtures


def main():
    if not ssl.HAS_TLSv1_3:
        raise ProbeError("Cancellation probe requires a Python interpreter with TLS 1.3 support")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    pin = json.loads((ROOT / "Config/kopia-version.json").read_text())
    with tempfile.TemporaryDirectory(prefix="mackopia-cancel-spike-") as temporary:
        fixtures = execute(SERVER.CLI.Spike(temporary, ROOT / "Vendor/kopia" / pin["version"] / "kopia"))
    args.output.mkdir(parents=True, exist_ok=True)
    for name, value in fixtures.items():
        (args.output / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(fixtures["cancel-report.json"], indent=2))


if __name__ == "__main__":
    main()
