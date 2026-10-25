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
    # The app build enables local ad-hoc signing; standalone fixture setup can opt out.
    if os.environ.get("CODE_SIGNING_ALLOWED", "NO") == "YES":
        run("/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", str(binary))
        run("/usr/bin/codesign", "--verify", "--strict", str(binary))


def main():
    pin = json.loads((ROOT / "Config/kopia-version.json").read_text())
    version = pin["version"]
    cache = ROOT / "Vendor/kopia" / version
    cache.mkdir(parents=True, exist_ok=True)
    name = "kopia-" + version + "-macOS-arm64.tar.gz"
    archive = cache / name
    fetch_archive(
        "https://github.com/kopia/kopia/releases/download/v" + version + "/" + name,
        archive, pin["sha256"]["arm64"],
    )
    with tempfile.TemporaryDirectory(prefix="assemble-", dir=cache) as temporary:
        staging = Path(temporary)
        binary = staging / "kopia"
        extract_member(archive, "kopia", binary)
        binary.chmod(0o755)
        architectures = subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True).split()
        if architectures != ["arm64"]:
            raise ValueError("Kopia binary must contain only the supported arm64 architecture")
        sign_binary(binary)
        for name in ("LICENSE", "README.md"):
            extract_member(archive, name, staging / name)
        for name in ("kopia", "LICENSE", "README.md"):
            os.replace(staging / name, cache / name)
    print("Verified Kopia " + version + " (arm64): " + str(cache / "kopia"))


if __name__ == "__main__":
    main()
