#!/usr/bin/env python3
"""Probe config-free WebDAV creation, fresh pipe reconnects and crash recovery."""

import argparse
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import tempfile
from urllib.parse import urlencode

from kopia_server_probe import ProbeError, Server

SPEC = importlib.util.spec_from_file_location(
    "secret_input", Path(__file__).with_name("spike-kopia-secret-input.py"))
INPUT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INPUT)
ROOT = Path(__file__).resolve().parent.parent


def require_success(result, stage):
    if result.returncode:
        raise ProbeError("Remote lifecycle probe failed at " + stage)
    return result.stdout


@contextmanager
def protected_config(spike, payload):
    # Kopia 0.23.1 derives its maintenance lock from the config pathname.
    shared_lock = spike.root / "repository.mlock"
    descriptor = os.open(shared_lock, os.O_CREAT | os.O_RDWR, 0o600)
    os.close(descriptor)
    with INPUT.config_pipe(payload) as pipe_fd:
        with tempfile.TemporaryDirectory(prefix="runtime-", dir=spike.root) as directory:
            parent = Path(directory)
            path = parent / "repository.config"
            path.symlink_to("/dev/fd/" + str(pipe_fd))
            (parent / "repository.config.mlock").symlink_to(shared_lock)
            parent.chmod(0o500)
            try:
                yield path, pipe_fd
            finally:
                unchanged = path.is_symlink() and set(item.name for item in parent.iterdir()) == {
                    "repository.config", "repository.config.mlock"}
                parent.chmod(0o700)
                if not unchanged:
                    raise ProbeError("Runtime configuration directory was modified")


def pipe_run(spike, payload, arguments, extra_env=None):
    with protected_config(spike, payload) as (path, descriptor):
        base = [arg for arg in spike.base if not arg.startswith("--config-file=")]
        return subprocess.run(
            base + ["--config-file=" + str(path)] + arguments,
            env=spike.env | (extra_env or {}), cwd=spike.working, stdin=subprocess.DEVNULL,
            capture_output=True, timeout=30, start_new_session=True, pass_fds=(descriptor,),
        )


@contextmanager
def pipe_server(spike, payload):
    original = spike.base
    with protected_config(spike, payload) as (path, descriptor):
        spike.base = [arg for arg in original if not arg.startswith("--config-file=")]
        spike.base += ["--config-file=" + str(path)]
        try:
            with Server(spike, pass_fds=(descriptor,)) as server:
                server.client.request("/", bootstrap=True)
                if not server.client.json("/api/v1/repo/status").get("connected"):
                    raise ProbeError("Pipe server did not reconnect")
                yield server
        finally:
            spike.base = original


def latest(client, source):
    query = urlencode({"userName": "test-user", "host": "test-host", "path": str(source)})
    snapshots = client.json("/api/v1/snapshots?" + query)["snapshots"]
    if not snapshots:
        raise ProbeError("Reconnected server lost snapshot history")
    return max(snapshots, key=lambda item: item["startTime"])["rootID"]


def restore(client, root_id, destination, expected):
    if destination.exists():
        raise ProbeError("Probe restore destination already exists")
    task = client.json("/api/v1/restore", method="POST", body={
        "root": root_id,
        "fsOutput": {"targetPath": str(destination), "overwriteFiles": False,
                     "overwriteDirectories": False, "overwriteSymlinks": False, "writeFilesAtomically": True},
        "options": {"restoreDirEntryAtDepth": 2147483647, "deleteExtra": False, "ignoreErrors": False},
    })
    result = INPUT.wait_for(lambda: client.json("/api/v1/tasks/" + task["id"]),
                            lambda value: value["status"] in ("SUCCESS", "FAILED", "CANCELED"))
    if result["status"] != "SUCCESS" or (destination / "hello.txt").read_bytes() != expected:
        raise ProbeError("Reconnected server failed byte-identical restore")


def execute(directory, binary):
    root = Path(directory)
    storage = root / "storage"
    storage.mkdir(mode=0o700)
    user, password, access, token, secret, repo_password = [secrets.token_hex(24) for _ in range(6)]
    spike = INPUT.make_spike(root, "client", binary, repo_password)
    credentials = {"KOPIA_WEBDAV_USERNAME": user, "KOPIA_WEBDAV_PASSWORD": password}
    report = {"version": spike.run("--version").strip()}
    with INPUT.BACKENDS.storage_server(storage, user, password, access, token, secret) as (port, _):
        create = ["repository", "create", "webdav", "--create-only", "--url=http://127.0.0.1:" + str(port),
                  "--cache-directory=" + str(spike.root / "cache"), "--no-check-for-updates",
                  "--override-hostname=test-host", "--override-username=test-user"]
        require_success(INPUT.BACKENDS.invoke(spike, create, credentials), "create-only")
        if (spike.root / "repository.config").exists() or not (storage / "kopia.repository.f").is_file():
            raise ProbeError("Create-only unexpectedly wrote local configuration or failed to initialize storage")
        initial_format = (storage / "kopia.repository.f").read_bytes()
        duplicate = INPUT.BACKENDS.invoke(spike, create, credentials)
        if duplicate.returncode == 0 or (storage / "kopia.repository.f").read_bytes() != initial_format:
            raise ProbeError("Duplicate creation changed the existing destination")
        report["createdWithoutLocalConfig"] = True
        report["duplicateCreationRejectedWithoutFormatChange"] = True

        config = {
            "storage": {"type": "webdav", "config": {
                "url": "http://127.0.0.1:" + str(port), "username": user, "password": password}},
            # Kopia 0.23.1: omitting cache capacities can panic while reading new manifests.
            "caching": {"cacheDirectory": str(spike.root / "cache"), "maxCacheSize": 5242880000,
                        "maxMetadataCacheSize": 5242880000, "maxListCacheDuration": 30},
            "username": "test-user", "hostname": "test-host", "enableActions": False,
        }
        payload = json.dumps(config).encode()
        # Kopia 0.23.1: --create-only skips populateRepository (policy and maintenance owner).
        policy_result = pipe_run(spike, payload, [
            "policy", "set", "--global", "--keep-latest=10", "--keep-hourly=48", "--keep-daily=14",
            "--keep-weekly=8", "--keep-monthly=24", "--keep-annual=3", "--compression=zstd",
        ])
        require_success(policy_result, "initial policy")
        require_success(pipe_run(spike, payload, ["maintenance", "set", "--owner=me"]), "maintenance owner")
        owner = json.loads(require_success(pipe_run(spike, payload, ["maintenance", "info", "--json"]), "maintenance info"))
        if owner.get("owner") != "test-user@test-host":
            raise ProbeError("Maintenance owner was not initialized")
        policy = json.loads(require_success(pipe_run(spike, payload, ["policy", "show", "--global", "--json"]), "read policy"))
        retention = policy.get("retention", {})
        if [retention.get(key) for key in ("keepLatest", "keepHourly", "keepDaily", "keepWeekly", "keepMonthly", "keepAnnual")] != [10, 48, 14, 8, 24, 3]:
            raise ProbeError("Initialized retention differs from the balanced preset")
        report["explicitPolicyAndOwnerInitialized"] = True
        blocked = pipe_run(spike, payload, ["repository", "connect", "webdav",
            "--url=http://127.0.0.1:" + str(port), "--cache-directory=" + str(spike.root / "cache"),
            "--no-check-for-updates", "--override-hostname=test-host", "--override-username=test-user"], credentials)
        if blocked.returncode == 0:
            raise ProbeError("Read-only runtime directory allowed secret config publication")
        report["configPublicationBlocked"] = True

        source = root / "source"
        source.mkdir()
        (source / "hello.txt").write_bytes(b"MacKopia remote lifecycle initial\n")
        snapshot_result = pipe_run(spike, payload, ["snapshot", "create", str(source), "--json"])
        require_success(snapshot_result, "initial snapshot")
        require_success(pipe_run(spike, payload, ["maintenance", "run"]), "quick maintenance")
        report["quickMaintenanceSucceeded"] = True
        with pipe_server(spike, payload) as server:
            server.client.json("/api/v1/repo/sync", method="POST", body={})
            INPUT.snapshot_restore(server.client, source, root / "first-restore")
            root_id = latest(server.client, source)
            # A consumed pipe cannot serve config read/modify/write operations.
            server.client.request("/api/v1/repo/description", method="POST",
                                  body={"description": "Fixture description"}, expected=500)
            if not server.client.json("/api/v1/repo/status").get("connected"):
                raise ProbeError("Rejected config mutation disconnected the server")
        if not server.clean_shutdown:
            raise ProbeError("Initial server failed EOF shutdown")
        report["syncAndBackupRestoreSucceeded"] = True
        report["configMutationRejectedWithoutDisconnect"] = True

        expected = (source / "hello.txt").read_bytes()
        # Kill only this probe's owned server, after the completed snapshot was flushed.
        with pipe_server(spike, payload) as killed:
            if latest(killed.client, source) != root_id:
                raise ProbeError("Graceful restart lost snapshot history")
            os.killpg(killed.process.pid, signal.SIGKILL)
            killed.process.wait(timeout=5)
        if killed.process.returncode != -signal.SIGKILL:
            raise ProbeError("Owned server was not killed as intended")
        report["forcedExitObserved"] = True

        with pipe_server(spike, payload) as recovered:
            if latest(recovered.client, source) != root_id:
                raise ProbeError("Crash restart lost snapshot history")
            restore(recovered.client, root_id, root / "crash-restore", expected)
        if not recovered.clean_shutdown:
            raise ProbeError("Recovered server failed EOF shutdown")
        report["freshPipeReconnectAndCrashRestoreSucceeded"] = True
        report["cleanEOFShutdownAfterRecovery"] = True
        wrong_env = spike.env.copy()
        spike.env["KOPIA_PASSWORD"] = secrets.token_hex(24)
        try:
            rejected = pipe_run(spike, payload, ["repository", "status", "--json"])
            if rejected.returncode == 0:
                raise ProbeError("Wrong backup password was accepted")
        finally:
            spike.env = wrong_env
        require_success(pipe_run(spike, payload, ["repository", "status", "--json"]), "correct password after rejection")
        report["wrongBackupPasswordRejectedThenReconnectSucceeded"] = True
    values = (user, password, access, token, secret, repo_password)
    if any(value.encode() in path.read_bytes() for path in root.rglob("*") if path.is_file() for value in values):
        raise ProbeError("Remote lifecycle probe persisted credentials")
    if any(value in json.dumps(report) for value in (*values, str(root))):
        raise ProbeError("Remote lifecycle report contains private data")
    report["credentialsFoundInFiles"] = False
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    pin = json.loads((ROOT / "Config/kopia-version.json").read_text())
    with tempfile.TemporaryDirectory(prefix="mackopia-remote-lifecycle-") as directory:
        report = execute(directory, ROOT / "Vendor/kopia" / pin["version"] / "kopia")
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "remote-lifecycle-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
