#!/usr/bin/env python3
"""Probe SFTP credential parsing without an SSH account or any secret files.

This diagnostic probe does not establish SSH authentication or host-key trust.
The loopback port is reserved but never listens: reaching dial proves parsing only.
"""

import argparse
import copy
import importlib.util
import json
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile

from kopia_server_probe import ProbeError

SPEC = importlib.util.spec_from_file_location(
    "remote_lifecycle", Path(__file__).with_name("spike-kopia-remote-lifecycle.py"))
LIFECYCLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LIFECYCLE)
ROOT = Path(__file__).resolve().parent.parent


def checked_output(result, expected, sensitive):
    """Never expose raw Kopia diagnostics, including unexpected failure paths."""
    output = result.stdout + result.stderr
    if any(value and value in output for value in sensitive):
        raise ProbeError("SFTP probe exposed credential material")
    if result.returncode == 0 or expected not in output:
        raise ProbeError("SFTP credential parsing contract changed")


def generate_key(environment):
    # stdout remains in RAM; no key path, passphrase argument or temporary key file.
    result = subprocess.run(
        ["/usr/bin/openssl", "genrsa", "2048"], env=environment,
        capture_output=True, timeout=30, check=False,
    )
    if result.returncode or b"PRIVATE KEY" not in result.stdout:
        raise ProbeError("Could not generate in-memory probe key")
    return result.stdout


def encrypt_key(key, passphrase, environment):
    result = subprocess.run(
        ["/usr/bin/openssl", "rsa", "-aes256", "-passout", "env:MACKOPIA_PROBE_PASSPHRASE"],
        input=key, env=environment | {"MACKOPIA_PROBE_PASSPHRASE": passphrase},
        capture_output=True, timeout=30, check=False,
    )
    if result.returncode or b"PRIVATE KEY" not in result.stdout:
        raise ProbeError("Could not encrypt in-memory probe key")
    return result.stdout


def decrypt_key(key, passphrase, environment):
    """Decrypt PEM entirely in memory; never expose OpenSSL diagnostics."""
    result = subprocess.run(
        ["/usr/bin/openssl", "rsa", "-passin", "env:MACKOPIA_PROBE_PASSPHRASE"],
        input=key, env=environment | {"MACKOPIA_PROBE_PASSPHRASE": passphrase},
        capture_output=True, timeout=30, check=False,
    )
    if result.returncode or b"PRIVATE KEY" not in result.stdout:
        raise ProbeError("Could not decrypt in-memory probe key")
    return result.stdout


def execute(directory, binary):
    root = Path(directory)
    spike = LIFECYCLE.INPUT.make_spike(root, "client", binary, secrets.token_hex(32))
    password, passphrase = secrets.token_hex(24), secrets.token_hex(24)
    key = generate_key(spike.tool_env)
    encrypted = encrypt_key(key, passphrase, spike.tool_env)
    decrypted = decrypt_key(encrypted, passphrase, spike.tool_env)
    if decrypted != key:
        raise ProbeError("In-memory PEM round trip changed key material")
    try:
        decrypt_key(encrypted, secrets.token_hex(24), spike.tool_env)
    except ProbeError:
        pass
    else:
        raise ProbeError("Encrypted PEM accepted an incorrect passphrase")
    # Also scan a body line: serializers can escape newlines in a complete PEM.
    sensitive = [password.encode(), passphrase.encode(), spike.password.encode(), key,
                 key.splitlines()[1], encrypted, encrypted.splitlines()[-2]]
    known_hosts = root / "known_hosts"
    known_hosts.write_bytes(b"")
    known_hosts.chmod(0o600)
    config = {
        "storage": {"type": "sftp", "config": {
            "path": "/probe", "host": "127.0.0.1", "username": "probe-user",
            "knownHostsFile": str(known_hosts), "externalSSH": False}},
        "caching": {"cacheDirectory": str(spike.root / "cache"), "maxCacheSize": 5242880000,
                    "maxMetadataCacheSize": 5242880000, "maxListCacheDuration": 30},
        "username": "test-user", "hostname": "test-host", "enableActions": False,
    }
    report = {"version": spike.run("--version").strip()}
    # Reserve an ephemeral port without listening, avoiding a race with another service.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reserved:
        reserved.bind(("127.0.0.1", 0))
        config["storage"]["config"]["port"] = reserved.getsockname()[1]

        def probe(options, expected):
            candidate = copy.deepcopy(config)
            candidate["storage"]["config"].update(options)
            result = LIFECYCLE.pipe_run(spike, json.dumps(candidate).encode(),
                                        ["repository", "status", "--json"])
            checked_output(result, expected, sensitive)

        probe({"password": password}, b"unable to dial")
        report["passwordPipeParsedBeforeDial"] = True
        probe({"keyData": key.decode()}, b"unable to dial")
        report["unencryptedKeyDataPipeParsedBeforeDial"] = True
        # Kopia 0.23.1 has no passphrase option and calls ssh.ParsePrivateKey.
        probe({"keyData": encrypted.decode()}, b"private key is passphrase protected")
        report["encryptedKeyRejectedBeforeDial"] = True
        probe({"keyData": decrypted.decode()}, b"unable to dial")
        report["decryptedPEMKeyParsedBeforeDial"] = True
        report["incorrectPEMPassphraseRejected"] = True
        probe({"keyData": "invalid-key"}, b"no key found")
        report["malformedKeyRejectedBeforeDial"] = True
        missing = root / "missing_known_hosts"
        probe({"password": password, "knownHostsFile": str(missing)}, b"unable to getHostKey")
        report["missingKnownHostsRejectedBeforeDial"] = True

    for path in root.rglob("*"):
        if path.is_file() and any(value in path.read_bytes() for value in sensitive):
            raise ProbeError("SFTP probe persisted credential material")
    if (spike.root / "repository.config").exists():
        raise ProbeError("SFTP probe published a regular configuration")
    report["credentialsFoundInFilesOrOutput"] = False
    report["sshAuthenticationAndHostKeyMismatchVerified"] = False
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    pin = json.loads((ROOT / "Config/kopia-version.json").read_text())
    with tempfile.TemporaryDirectory(prefix="mackopia-sftp-input-") as directory:
        report = execute(directory, ROOT / "Vendor/kopia" / pin["version"] / "kopia")
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "sftp-input-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
