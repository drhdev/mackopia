#!/usr/bin/env python3
"""Record isolated Kopia REST contracts with TLS, pinning and CSRF protection enabled."""

import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import ssl
import time
from urllib.parse import urlencode

from kopia_server_probe import ProbeError, Server

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("cli_spike", ROOT / "Scripts/spike-kopia-cli.py")
CLI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLI)


def wait_for(read, complete):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        value = read()
        if complete(value):
            return value
        time.sleep(0.1)
    raise ProbeError("REST operation timed out")


def finished_task(client, task):
    result = wait_for(
        lambda: client.json("/api/v1/tasks/" + task["id"]),
        lambda value: value["status"] in ("SUCCESS", "FAILED", "CANCELED"),
    )
    if result["status"] != "SUCCESS":
        raise ProbeError("REST task did not succeed")
    return result


def execute(spike):
    spike.run(
        "repository", "create", "filesystem", "--path=" + str(spike.root / "repository"),
        "--cache-directory=" + str(spike.root / "cache"), "--override-hostname=test-host",
        "--override-username=test-user", "--no-check-for-updates",
    )
    source = spike.root / "source"
    source.mkdir()
    (source / "hello.txt").write_bytes(b"MacKopia server probe\n")
    (source / "empty").touch()
    spike.run("snapshot", "create", str(source), "--json")
    with Server(spike, ui=False) as disabled:
        disabled.client.json("/api/v1/control/status", control=True)
        disabled.client.request("/api/v1/repo/status", expected=404)
    if not disabled.clean_shutdown:
        raise ProbeError("Headless probe did not shut down on stdin EOF")
    fixtures = {}
    with Server(spike) as server:
        client = server.client
        client.request("/api/v1/repo/status", authenticated=False, expected=401)
        client.request("/api/v1/repo/status", expected=401)  # CSRF session is still missing.
        pin = client.pin
        client.pin = "0" * 64
        try:
            client.request("/api/v1/repo/status")
        except ProbeError as error:
            if str(error) != "Peer certificate fingerprint mismatch":
                raise
        else:
            raise ProbeError("Peer fingerprint mismatch was accepted")
        finally:
            client.pin = pin
        client.request("/", bootstrap=True)
        fixtures["rest-repo-status.json"] = client.json("/api/v1/repo/status")
        client.json("/api/v1/control/status", control=True)
        fixtures["rest-sources.json"] = client.json("/api/v1/sources")
        query = urlencode({"userName": "test-user", "host": "test-host", "path": str(source)})
        snapshot_path = "/api/v1/snapshots?" + query
        before = client.json(snapshot_path)
        (source / "hello.txt").write_bytes(b"MacKopia server probe updated\n")
        fixtures["rest-upload.json"] = client.json("/api/v1/sources/upload?" + query, method="POST", body={})
        snapshots = wait_for(lambda: client.json(snapshot_path),
                             lambda value: len(value["snapshots"]) > len(before["snapshots"]))
        fixtures["rest-snapshots.json"] = snapshots
        # Kopia 0.23.1 does not return snapshots newest-first.
        root_id = max(snapshots["snapshots"], key=lambda snapshot: snapshot["startTime"])["rootID"]
        fixtures["rest-object.json"] = client.json("/api/v1/objects/" + root_id)
        estimate = client.json("/api/v1/estimate", method="POST", body={"root": str(source)})
        fixtures["rest-estimate-start.json"] = estimate
        fixtures["rest-estimate-finished.json"] = finished_task(client, estimate)
        destination = spike.root / "restored"
        if destination.exists():
            raise ProbeError("REST restore destination already exists")
        # Kopia 0.23.1 REST defaults to depth zero (placeholders); CLI uses MaxInt32.
        request = {
            "root": root_id,
            "fsOutput": {"targetPath": str(destination), "overwriteFiles": False,
                         "overwriteDirectories": False, "overwriteSymlinks": False, "writeFilesAtomically": True},
            "options": {"restoreDirEntryAtDepth": 2147483647, "deleteExtra": False, "ignoreErrors": False},
        }
        fixtures["rest-restore-request.json"] = request
        restore = client.json("/api/v1/restore", method="POST", body=request)
        fixtures["rest-restore-start.json"] = restore
        fixtures["rest-restore-finished.json"] = finished_task(client, restore)
        if (destination / "hello.txt").read_bytes() != (source / "hello.txt").read_bytes():
            raise ProbeError("REST restore changed file contents")
        if (destination / "empty").read_bytes() != b"":
            raise ProbeError("REST restore lost empty file")
        fixtures["rest-tasks.json"] = client.json("/api/v1/tasks")
        secrets = [spike.password, disabled.client.password, disabled.client.control_password,
                   client.password, client.control_password, client.session_cookie, client.csrf_token]
    if not server.clean_shutdown:
        raise ProbeError("Server did not shut down cleanly on stdin EOF")
    # No handshake values or credentials are recorded, even in the scrubbed fixtures.
    for name, value in fixtures.items():
        text = json.dumps(value)
        if any(secret in text for secret in secrets):
            raise ProbeError("A REST fixture contains an ephemeral credential")
        fixtures[name] = spike.scrub(value)
        scrubbed = json.dumps(fixtures[name])
        if any(marker in scrubbed for marker in ("/Users/", "/Volumes/", "/var/folders/", "/private/var/")):
            raise ProbeError("A REST fixture contains an unsanitized machine path")
    for path in [spike.root / "repository.config"] + list((spike.root / "logs").rglob("*")):
        if path.is_file():
            content = path.read_bytes()
            if any(secret.encode() in content for secret in secrets):
                raise ProbeError("An ephemeral credential reached config or logs")
    fixtures["server-report.json"] = {"checks": {
        "loopbackTLS": True, "peerPinMismatchRejectedBeforeHTTP": True, "missingAuthRejected": True,
        "missingCSRFRejected": True, "ephemeralCSRFSession": True, "noUIDisablesUIAPI": True,
        "serverSnapshot": True, "estimateTask": True, "restoreBytesMatch": True,
        "stdinEOFShutdown": True, "credentialsNotPersisted": True,
    }}
    return fixtures


def main():
    if not ssl.HAS_TLSv1_3:
        raise ProbeError("Server probe requires a Python interpreter with TLS 1.3 support")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    pin = json.loads((ROOT / "Config/kopia-version.json").read_text())
    binary = ROOT / "Vendor/kopia" / pin["version"] / "kopia"
    with tempfile.TemporaryDirectory(prefix="mackopia-server-spike-") as temporary:
        fixtures = execute(CLI.Spike(temporary, binary))
    args.output.mkdir(parents=True, exist_ok=True)
    for name, value in fixtures.items():
        (args.output / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(fixtures["server-report.json"], indent=2))


if __name__ == "__main__":
    main()
