#!/usr/bin/env python3
"""Probe actual SFTP authentication and host-key rejection without secret files."""

import argparse
import copy
import importlib.util
import json
from pathlib import Path
import secrets
import tempfile
import subprocess

from kopia_server_probe import ProbeError
from sftp_probe_fixture import ssh_fixture

SPEC = importlib.util.spec_from_file_location(
    "sftp_input", Path(__file__).with_name("spike-kopia-sftp-input.py"))
INPUT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INPUT)
ROOT = Path(__file__).resolve().parent.parent


def create(spike, config):
    options = config["storage"]["config"]
    with INPUT.LIFECYCLE.INPUT.config_pipe(options["keyData"].encode()) as descriptor:
        return subprocess.run(
            spike.base + ["repository", "create", "sftp", "--create-only",
                          "--keyfile=/dev/fd/" + str(descriptor),
                          "--path=" + options["path"], "--host=" + options["host"],
                          "--port=" + str(options["port"]), "--username=" + options["username"],
                          "--known-hosts=" + options["knownHostsFile"],
                          "--cache-directory=" + str(spike.root / "cache")],
            env=spike.env, cwd=spike.working, stdin=subprocess.DEVNULL,
            capture_output=True, timeout=30, pass_fds=(descriptor,), start_new_session=True,
        )


def lifecycle(spike, config, root, sensitive):
    def success(result, stage):
        if any(value and value in result.stdout + result.stderr for value in sensitive):
            raise ProbeError("SFTP lifecycle exposed credential material")
        return INPUT.LIFECYCLE.require_success(result, stage)

    success(create(spike, config), "SFTP create-only")
    storage = root / "storage"
    initial = (storage / "kopia.repository.f").read_bytes()
    duplicate = create(spike, config)
    if any(value and value in duplicate.stdout + duplicate.stderr for value in sensitive):
        raise ProbeError("SFTP duplicate creation exposed credential material")
    if duplicate.returncode == 0 or (storage / "kopia.repository.f").read_bytes() != initial:
        raise ProbeError("SFTP duplicate create changed existing destination")
    if (spike.root / "repository.config").exists():
        raise ProbeError("SFTP create-only published configuration")
    payload = json.dumps(config).encode()
    def run(arguments):
        return INPUT.LIFECYCLE.pipe_run(spike, payload, arguments)
    success(run(["policy", "set", "--global", "--compression=zstd", "--keep-latest=10"]), "policy")
    success(run(["maintenance", "set", "--owner=me"]), "owner")
    source = root / "source"
    source.mkdir(mode=0o700)
    expected = b"MacKopia SFTP lifecycle\n"
    (source / "hello.txt").write_bytes(expected)
    success(run(["snapshot", "create", str(source), "--json"]), "SFTP backup")
    success(run(["snapshot", "verify", "--verify-files-percent=100"]), "SFTP verify")
    with INPUT.LIFECYCLE.pipe_server(spike, payload) as server:
        root_id = INPUT.LIFECYCLE.latest(server.client, source)
        INPUT.LIFECYCLE.restore(server.client, root_id, root / "restore", expected)
    if not server.clean_shutdown:
        raise ProbeError("SFTP server failed EOF shutdown")
    with INPUT.LIFECYCLE.pipe_server(spike, payload) as restarted:
        INPUT.LIFECYCLE.restore(restarted.client, root_id, root / "restart-restore", expected)
    if not restarted.clean_shutdown:
        raise ProbeError("SFTP restarted server failed EOF shutdown")
    return {"createdWithoutLocalConfig": True, "duplicateCreatePreservedFormat": True,
            "backupVerifyRestoreSucceeded": True, "freshPipeRestartRestoreSucceeded": True,
            "cleanEOFShutdown": True}


def execute(directory, binary):
    root = Path(directory)
    spike = INPUT.LIFECYCLE.INPUT.make_spike(root, "client", binary, secrets.token_hex(32))
    key = INPUT.generate_key(spike.tool_env)
    with ssh_fixture(root / "ssh", key, INPUT.generate_key, spike.tool_env) as (ssh, host_key):
        storage = root / "storage"
        storage.mkdir(mode=0o700)
        config = {
            "storage": {"type": "sftp", "config": {
                "path": str(storage), "host": "127.0.0.1", "externalSSH": False,
                "keyData": key.decode(), **ssh}},
            "caching": {"cacheDirectory": str(spike.root / "cache"), "maxCacheSize": 5242880000,
                        "maxMetadataCacheSize": 5242880000, "maxListCacheDuration": 30},
            "username": "test-user", "hostname": "test-host", "enableActions": False,
        }
        sensitive = [key, key.splitlines()[1], host_key, host_key.splitlines()[1],
                     spike.password.encode()]
        def probe(candidate, marker):
            result = INPUT.LIFECYCLE.pipe_run(
                spike, json.dumps(candidate).encode(), ["repository", "status", "--json"])
            INPUT.checked_output(result, marker, sensitive)

        # An empty directory reached over authenticated SFTP has no repository format blob.
        probe(config, b"error getting kopia.repository blob: BLOB not found")
        wrong = copy.deepcopy(config)
        wrong_key = INPUT.generate_key(spike.tool_env)
        sensitive.extend([wrong_key, wrong_key.splitlines()[1]])
        wrong["storage"]["config"]["keyData"] = wrong_key.decode()
        probe(wrong, b"unable to authenticate")
        mismatch = root / "wrong_known_hosts"
        original = Path(ssh["knownHostsFile"]).read_bytes()
        # Same host identity, another valid public key: actual mismatch rather than missing trust.
        client_public = (root / "ssh" / "authorized_keys").read_bytes()
        mismatch.write_bytes(original.split(b" ", 1)[0] + b" " + client_public)
        mismatch.chmod(0o600)
        wrong_host = copy.deepcopy(config)
        wrong_host["storage"]["config"]["knownHostsFile"] = str(mismatch)
        probe(wrong_host, b"key mismatch")
        lifecycle_report = lifecycle(spike, config, root, sensitive)
    for path in root.rglob("*"):
        if path.is_file() and any(value in path.read_bytes() for value in sensitive):
            raise ProbeError("SFTP authentication probe persisted credential material")
    return {"version": spike.run("--version").strip(), "sshAuthenticationVerified": True,
            "wrongKeyRejected": True, "hostKeyMismatchRejected": True,
            "credentialsFoundInFilesOrOutput": False, **lifecycle_report}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    import ssl
    if not ssl.HAS_TLSv1_3:
        raise ProbeError("SFTP lifecycle requires a Python interpreter with TLS 1.3")
    pin = json.loads((ROOT / "Config/kopia-version.json").read_text())
    with tempfile.TemporaryDirectory(prefix="mackopia-sftp-auth-") as directory:
        report = execute(directory, ROOT / "Vendor/kopia" / pin["version"] / "kopia")
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "sftp-auth-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
