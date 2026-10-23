"""Fetch pinned release archives; only verified bytes become bundled executables."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent


def verified_archive(archive, expected):
    if not archive.is_file():
        return False
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest() == expected


def fetch_archive(url, archive, expected):
    if archive.exists():
        if not verified_archive(archive, expected):
            raise ValueError("Cached Kopia archive failed SHA256 verification: " + archive.name)
        return
    descriptor, temporary = tempfile.mkstemp(dir=archive.parent, prefix="download-")
    try:
        with os.fdopen(descriptor, "wb") as output:
            with urllib.request.urlopen(url, timeout=60) as response:
                shutil.copyfileobj(response, output)
        if not verified_archive(Path(temporary), expected):
            raise ValueError("Downloaded Kopia archive failed SHA256 verification")
        os.replace(temporary, archive)
    finally:
        Path(temporary).unlink(missing_ok=True)


def extract_member(archive, name, destination):
    # Never extract archive paths or links onto the filesystem.
    with tarfile.open(archive, "r:gz") as source:
        members = [m for m in source.getmembers() if Path(m.name).name == name and m.isfile()]
        if len(members) != 1:
            raise ValueError("Expected exactly one " + name + " in " + archive.name)
        with source.extractfile(members[0]) as content, destination.open("wb") as output:
            shutil.copyfileobj(content, output)


def run(*arguments):
    subprocess.run(arguments, check=True)


def sign_binary(binary):
    # Signing is deferred until explicitly enabled for a future release/build.
    if os.environ.get("CODE_SIGNING_ALLOWED", "NO") == "YES":
        run("/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", str(binary))
        run("/usr/bin/codesign", "--verify", "--strict", str(binary))


def main():
    pin = json.loads((ROOT / "Config/kopia-version.json").read_text())
    version = pin["version"]
    cache = ROOT / "Vendor/kopia" / version
    cache.mkdir(parents=True, exist_ok=True)
    archives = {}
    for architecture, upstream in (("arm64", "arm64"), ("amd64", "x64")):
        name = "kopia-" + version + "-macOS-" + upstream + ".tar.gz"
        archive = cache / name
        fetch_archive(
            "https://github.com/kopia/kopia/releases/download/v" + version + "/" + name,
            archive,
            pin["sha256"][architecture],
        )
        archives[architecture] = archive
    with tempfile.TemporaryDirectory(prefix="assemble-", dir=cache) as temporary:
        staging = Path(temporary)
        for architecture, archive in archives.items():
            extract_member(archive, "kopia", staging / architecture)
        binary = staging / "kopia"
        run("/usr/bin/lipo", "-create", str(staging / "arm64"), str(staging / "amd64"), "-output", str(binary))
        binary.chmod(0o755)
        architectures = subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True).split()
        if set(architectures) != {"arm64", "x86_64"}:
            raise ValueError("Kopia universal binary has unexpected architectures")
        # The enclosing app signs the helper with its own identity when embedding it.
        sign_binary(binary)
        for name in ("LICENSE", "README.md"):
            extract_member(archives["arm64"], name, staging / name)
            extract_member(archives["amd64"], name, staging / (name + ".amd64"))
            if (staging / name).read_bytes() != (staging / (name + ".amd64")).read_bytes():
                raise ValueError("Kopia license files differ between architectures")
        for name in ("kopia", "LICENSE", "README.md"):
            os.replace(staging / name, cache / name)
    print("Verified Kopia " + version + " (arm64 + x86_64): " + str(cache / "kopia"))


if __name__ == "__main__":
    main()
