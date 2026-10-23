#!/usr/bin/python3
"""Repeatable Phase-0 filesystem/metadata probe. Never connects to a real repository."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import secrets
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


class Spike:
    def __init__(self, directory, binary):
        self.root = Path(directory)
        self.working = self.root / "working"
        self.working.mkdir()
        self.password = secrets.token_urlsafe(32)
        self.env = {
            "HOME": directory,
            "USER": "test-user",
            "LANG": "en_US.UTF-8",
            "TMPDIR": directory,
            "KOPIA_CHECK_FOR_UPDATES": "false",
            "KOPIA_PASSWORD": self.password,
            "KOPIA_CACHE_DIRECTORY": str(self.root / "cache"),
        }
        self.tool_env = {key: self.env[key] for key in ("HOME", "USER", "LANG", "TMPDIR")}
        self.base = [
            str(binary),
            "--config-file=" + str(self.root / "repository.config"),
            "--log-dir=" + str(self.root / "logs"),
            "--no-progress",
            "--no-persist-credentials",
            "--no-use-keychain",
        ]

    def run(self, *arguments):
        result = subprocess.run(
            self.base + list(arguments), env=self.env, cwd=self.working,
            capture_output=True, text=True, timeout=120, start_new_session=True,
        )
        if result.returncode:
            # Raw CLI output may contain paths or credentials; do not surface it.
            raise RuntimeError("Kopia probe failed at " + " ".join(arguments[:2]))
        if self.password in result.stdout or self.password in result.stderr:
            raise RuntimeError("Kopia exposed the probe password in output")
        return result.stdout

    def scrub(self, value):
        if isinstance(value, dict):
            return {self.scrub(key): self.scrub(item) for key, item in value.items()}
        if isinstance(value, list):
            return [self.scrub(item) for item in value]
        if isinstance(value, str):
            return value.replace(str(self.root), "/fixture").replace(self.password, "[REDACTED]")
        return value

    def execute(self):
        version = self.run("--version").strip()
        self.run(
            "repository", "create", "filesystem", "--path=" + str(self.root / "repository"),
            "--cache-directory=" + str(self.root / "cache"),
            "--override-hostname=test-host", "--override-username=test-user", "--no-check-for-updates",
        )
        config = (self.root / "repository.config").read_text()
        # Kopia 0.23.1 stores a cache path relative to the config directory when possible.
        cache = Path(json.loads(config)["caching"]["cacheDirectory"])
        if not cache.is_absolute():
            cache = self.root / cache
        if self.password in config or cache.resolve() != (self.root / "cache").resolve():
            raise RuntimeError("Isolated repository configuration failed validation")
        source = self.root / "source"
        source.mkdir()
        file = source / "Grüße 🗂.txt"
        file.write_bytes(b"MacKopia metadata probe\n")
        file.chmod(0o640)
        os.utime(file, ns=(1700000000000000000, 1700000000000000000))
        (source / "empty").touch()
        (source / "link").symlink_to(file.name)
        attributes = {
            "com.mackopia.spike": b"test attribute",
            "com.apple.metadata:_kMDItemUserTags": plistlib.dumps(["Green\n2"], fmt=plistlib.FMT_BINARY),
            "com.apple.ResourceFork": b"test resource fork",
        }
        for name, value in attributes.items():
            subprocess.run(
                ["/usr/bin/xattr", "-wx", name, value.hex(), str(file)],
                env=self.tool_env, check=True, capture_output=True, timeout=10,
            )
        acl = "everyone allow read,readattr,readextattr,readsecurity"
        subprocess.run(["/bin/chmod", "+a", acl, str(file)], env=self.tool_env, check=True, capture_output=True, timeout=10)
        for name, value in attributes.items():
            original = subprocess.run(
                ["/usr/bin/xattr", "-px", name, str(file)], env=self.tool_env,
                check=True, capture_output=True, text=True, timeout=10,
            )
            if bytes.fromhex(original.stdout) != value:
                raise RuntimeError("Probe attribute setup failed")
        original_acl = subprocess.run(
            ["/bin/ls", "-le", str(file)], env=self.tool_env,
            capture_output=True, text=True, timeout=10, check=True,
        ).stdout
        original_acl_entries = [line.strip() for line in original_acl.splitlines()[1:]]
        if not original_acl_entries or "allow read,readattr,readextattr,readsecurity" not in original_acl:
            raise RuntimeError("Probe ACL setup failed")
        snapshot = json.loads(self.run("snapshot", "create", str(source), "--json"))
        snapshots = json.loads(self.run("snapshot", "list", "--json", "--all"))
        if len(snapshots) != 1:
            raise RuntimeError("Expected exactly one probe snapshot")
        object_id = snapshots[0]["rootEntry"]["obj"]
        destination = self.root / "restored"
        self.run(
            "snapshot", "restore", object_id, str(destination),
            "--no-overwrite-files", "--no-overwrite-directories", "--no-overwrite-symlinks",
        )
        restored = destination / file.name
        data_matches = restored.read_bytes() == file.read_bytes()
        restored_attributes = {}
        for name, value in attributes.items():
            try:
                result = subprocess.run(
                    ["/usr/bin/xattr", "-px", name, str(restored)],
                    env=self.tool_env, capture_output=True, text=True, timeout=10, check=True,
                )
                restored_attributes[name] = bytes.fromhex(result.stdout) == value
            except subprocess.CalledProcessError:
                restored_attributes[name] = False
        restored_acl = subprocess.run(
            ["/bin/ls", "-le", str(restored)], env=self.tool_env, capture_output=True, text=True, timeout=10, check=True,
        ).stdout
        self.run("snapshot", "verify", "--verify-files-percent=100")
        if not cache.is_dir() or (self.working / "cache").exists():
            raise RuntimeError("Cache was not resolved relative to the isolated config")
        self.run("repository", "status", "--json")
        wrong_password = secrets.token_urlsafe(32)
        rejected = subprocess.run(
            self.base + ["repository", "status", "--json"],
            env={**self.env, "KOPIA_PASSWORD": wrong_password}, cwd=self.working,
            capture_output=True, text=True, timeout=120, start_new_session=True,
        )
        if rejected.returncode == 0 or "invalid repository password" not in rejected.stderr.lower():
            raise RuntimeError("Wrong-password probe did not produce the expected rejection")
        if wrong_password in rejected.stdout or wrong_password in rejected.stderr:
            raise RuntimeError("Wrong-password probe exposed its password")
        # Scan generated config/logs, never emit their raw contents.
        for path in [self.root / "repository.config"] + list((self.root / "logs").rglob("*")):
            if path.is_file() and any(secret.encode() in path.read_bytes() for secret in (self.password, wrong_password)):
                raise RuntimeError("Probe password persisted in configuration or logs")
        checks = {
            "fileBytes": data_matches,
            "emptyFile": (destination / "empty").read_bytes() == b"",
            "symlink": (destination / "link").is_symlink() and os.readlink(destination / "link") == file.name,
            "posixMode": restored.stat().st_mode & 0o777 == 0o640,
            "modificationTime": restored.stat().st_mtime_ns == file.stat().st_mtime_ns,
            "acl": [line.strip() for line in restored_acl.splitlines()[1:]] == original_acl_entries,
            "extendedAttributes": restored_attributes,
            "verify100Percent": True,
            "cacheIsolated": True,
            "passwordNotPersisted": True,
            "wrongPasswordRejected": True,
        }
        if not all(checks[key] for key in ("fileBytes", "emptyFile", "symlink")):
            raise RuntimeError("Restore lost basic file content")
        return {
            "cli-snapshot-create.json": self.scrub(snapshot),
            "cli-snapshot-list.json": self.scrub(snapshots),
            "metadata-report.json": {"version": version, "checks": checks},
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    pin = json.loads((ROOT / "Config/kopia-version.json").read_text())
    binary = ROOT / "Vendor/kopia" / pin["version"] / "kopia"
    with tempfile.TemporaryDirectory(prefix="mackopia-cli-spike-") as temporary:
        artifacts = Spike(temporary, binary).execute()
    args.output.mkdir(parents=True, exist_ok=True)
    for name, value in artifacts.items():
        (args.output / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(artifacts["metadata-report.json"], indent=2))


if __name__ == "__main__":
    main()
