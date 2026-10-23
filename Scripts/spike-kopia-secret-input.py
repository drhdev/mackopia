#!/usr/bin/env python3
"""Test secret-free S3 config and anonymous-pipe WebDAV config against pinned Kopia."""

import argparse
from contextlib import contextmanager
import copy
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlencode

from kopia_server_probe import ProbeError, Server

SPEC = importlib.util.spec_from_file_location(
    "secrets_probe", Path(__file__).with_name("spike-kopia-secrets.py"))
BACKENDS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BACKENDS)
ROOT = Path(__file__).resolve().parent.parent


@contextmanager
def config_pipe(payload):
    """Transfer a bounded config through an inherited descriptor, never a disk file."""
    if len(payload) > 65536:
        raise ProbeError("Pipe configuration exceeded probe limit")
    read_fd, write_fd = os.pipe()
    errors = []

    def write():
        try:
            remaining = memoryview(payload)
            while remaining:
                count = os.write(write_fd, remaining)
                remaining = remaining[count:]
        except BrokenPipeError:
            pass  # The child may reject input before it needs the configuration.
        except OSError:
            errors.append(True)
        finally:
            os.close(write_fd)

    writer = threading.Thread(target=write, daemon=True)
    writer.start()
    try:
        yield read_fd
    finally:
        os.close(read_fd)
        writer.join(timeout=5)
        if writer.is_alive() or errors:
            raise ProbeError("Pipe writer failed to stop cleanly")


def write_config(path, payload):
    descriptor, temporary = tempfile.mkstemp(prefix=".config-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def make_spike(root, name, binary, password):
    directory = root / name
    directory.mkdir(mode=0o700)
    spike = BACKENDS.CLI.Spike(str(directory), binary)
    spike.password = password
    spike.env["KOPIA_PASSWORD"] = password
    return spike


def pipe_run(spike, payload, arguments):
    with config_pipe(payload) as descriptor:
        base = [arg for arg in spike.base if not arg.startswith("--config-file=")]
        return subprocess.run(
            base + ["--config-file=/dev/fd/" + str(descriptor)] + arguments,
            env=spike.env, cwd=spike.working, stdin=subprocess.DEVNULL,
            capture_output=True, timeout=30, start_new_session=True, pass_fds=(descriptor,),
        )


def pipe_status(spike, payload):
    return pipe_run(spike, payload, ["repository", "status", "--json"])


def wait_for(read, complete):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        result = read()
        if complete(result):
            return result
        time.sleep(0.1)
    raise ProbeError("Secret input workflow timed out")


def snapshot_restore(client, source, destination):
    query = urlencode({"userName": "test-user", "host": "test-host", "path": str(source)})
    path = "/api/v1/snapshots?" + query
    before = client.json(path)
    (source / "hello.txt").write_bytes(b"MacKopia pipe-backed update\n")
    client.json("/api/v1/sources/upload?" + query, method="POST", body={})
    snapshots = wait_for(lambda: client.json(path),
                         lambda value: len(value["snapshots"]) > len(before["snapshots"]))
    root_id = max(snapshots["snapshots"], key=lambda item: item["startTime"])["rootID"]
    if destination.exists():
        raise ProbeError("Probe restore destination already exists")
    task = client.json("/api/v1/restore", method="POST", body={
        "root": root_id,
        "fsOutput": {"targetPath": str(destination), "overwriteFiles": False,
                     "overwriteDirectories": False, "overwriteSymlinks": False, "writeFilesAtomically": True},
        "options": {"restoreDirEntryAtDepth": 2147483647, "deleteExtra": False, "ignoreErrors": False},
    })
    completed = wait_for(lambda: client.json("/api/v1/tasks/" + task["id"]),
                         lambda value: value["status"] in ("SUCCESS", "FAILED", "CANCELED"))
    if completed["status"] != "SUCCESS" or (destination / "hello.txt").read_bytes() != (source / "hello.txt").read_bytes():
        raise ProbeError("Pipe-backed WebDAV restore did not preserve contents")


def execute(directory, binary):
    root = Path(directory)
    seed = make_spike(root, "seed", binary, secrets.token_hex(32))
    seed.run(
        "repository", "create", "filesystem", "--path=" + str(root / "storage"),
        "--cache-directory=" + str(seed.root / "cache"), "--no-check-for-updates",
        "--override-hostname=test-host", "--override-username=test-user",
    )
    source = root / "source"
    source.mkdir()
    (source / "hello.txt").write_bytes(b"MacKopia pipe-backed initial\n")
    seed.run("snapshot", "create", str(source), "--json")
    template = json.loads((seed.root / "repository.config").read_text())
    user, password, access, secret, token = [secrets.token_hex(24) for _ in range(5)]
    report = {"version": seed.run("--version").strip()}
    with BACKENDS.storage_server(root / "storage", user, password, access, token, secret) as (port, observations):
        s3 = make_spike(root, "s3", binary, seed.password)
        config = copy.deepcopy(template)
        config["storage"] = {"type": "s3", "config": {
            "bucket": "bucket", "endpoint": "127.0.0.1:" + str(port), "region": "us-east-1",
            "doNotUseTLS": True,
        }}
        config["caching"]["cacheDirectory"] = str(s3.root / "cache")
        config_file = s3.root / "repository.config"
        write_config(config_file, json.dumps(config).encode())
        original = config_file.read_bytes()
        env = {"AWS_ACCESS_KEY_ID": access, "AWS_SECRET_ACCESS_KEY": secret, "AWS_SESSION_TOKEN": token}
        result = BACKENDS.invoke(s3, ["repository", "status", "--json"], env)
        if result.returncode or not observations["s3Authenticated"]:
            raise ProbeError("S3 environment fallback did not open the fixture repository")
        s3.env.update(env)
        shutil.rmtree(s3.root / "cache")
        observations["s3Authenticated"] = False
        with Server(s3) as server:
            server.client.request("/", bootstrap=True)
            status = server.client.json("/api/v1/repo/status")
            if not status.get("connected") or not observations["s3Authenticated"]:
                raise ProbeError("S3 server did not use environment fallback")
        if not server.clean_shutdown or config_file.read_bytes() != original:
            raise ProbeError("S3 server changed configuration or failed EOF shutdown")
        report["s3"] = {"cliOpenedWithEnvironment": True, "tlsServerOpenedWithEnvironment": True,
                        "configurationUnchanged": True, "cleanEOFShutdown": True}
        for field, label in (("AWS_SECRET_ACCESS_KEY", "wrongSecretRejected"), ("AWS_SESSION_TOKEN", "wrongTokenRejected")):
            shutil.rmtree(s3.root / "cache", ignore_errors=True)
            observations["s3Authenticated"] = False
            result = BACKENDS.invoke(s3, ["repository", "status", "--json"], env | {field: secrets.token_hex(24)})
            if result.returncode == 0 or observations["s3Authenticated"]:
                raise ProbeError("S3 fixture accepted incorrect environment credentials")
            report["s3"][label] = True


        dav = make_spike(root, "webdav-pipe", binary, seed.password)
        config = copy.deepcopy(template)
        config["storage"] = {"type": "webdav", "config": {
            "url": "http://127.0.0.1:" + str(port), "username": user, "password": password,
        }}
        config["caching"]["cacheDirectory"] = str(dav.root / "cache")
        payload = json.dumps(config).encode()
        observations["webdavAuthenticated"] = False
        result = pipe_status(dav, payload)
        report["webdavPipe"] = {
            "cliOpened": result.returncode == 0 and observations["webdavAuthenticated"],
            "configurationFileCreated": (dav.root / "repository.config").exists(),
        }
        if not report["webdavPipe"]["cliOpened"] or report["webdavPipe"]["configurationFileCreated"]:
            raise ProbeError("WebDAV CLI pipe contract changed")
        # Match the pipe run with a disposable file-backed control; no production exception.
        control_file = dav.root / "repository.config"
        write_config(control_file, payload)
        try:
            with Server(dav) as control:
                control.client.request("/", bootstrap=True)
                if not control.client.json("/api/v1/repo/status").get("connected"):
                    raise ProbeError("WebDAV control repository did not open")
            report["webdavPipe"]["fileControlCleanEOFShutdown"] = control.clean_shutdown
        finally:
            control_file.unlink(missing_ok=True)
        # A pipe is forward-only: a second config read sees EOF. Test server startup too.
        shutil.rmtree(dav.root / "cache", ignore_errors=True)
        with config_pipe(payload) as descriptor:
            dav.base = [arg for arg in dav.base if not arg.startswith("--config-file=")]
            dav.base += ["--config-file=/dev/fd/" + str(descriptor)]
            try:
                with Server(dav, pass_fds=(descriptor,)) as server:
                    server.client.request("/", bootstrap=True)
                    status = server.client.json("/api/v1/repo/status")
                    report["webdavPipe"]["tlsServerOpened"] = bool(status.get("connected"))
                    snapshot_restore(server.client, source, root / "restored")
                    report["webdavPipe"]["snapshotAndRestoreBytesMatch"] = True
                report["webdavPipe"]["cleanEOFShutdown"] = server.clean_shutdown
                report["webdavPipe"]["shutdownExitCode"] = server.process.returncode
            except ProbeError:
                raise ProbeError("Pipe-backed WebDAV server workflow failed") from None
    if (not report["webdavPipe"].get("tlsServerOpened")
            or not report["webdavPipe"].get("cleanEOFShutdown")
            or not report["webdavPipe"].get("fileControlCleanEOFShutdown")):
        raise ProbeError("WebDAV server lifecycle contract changed")
    values = (user, password, access, secret, token, seed.password)
    leaked = any(value.encode() in path.read_bytes() for path in root.rglob("*") if path.is_file()
                 for value in values)
    report["credentialsFoundInFiles"] = leaked
    if leaked or any(value in json.dumps(report) for value in (*values, str(root))):
        raise ProbeError("Secret input probe persisted or exported private data")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    pin = json.loads((ROOT / "Config/kopia-version.json").read_text())
    with tempfile.TemporaryDirectory(prefix="mackopia-secret-input-") as directory:
        report = execute(directory, ROOT / "Vendor/kopia" / pin["version"] / "kopia")
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "secret-input-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
