#!/usr/bin/python3
"""Expand only the validated app identity in the bundled LaunchAgent template."""

import argparse
import os
from pathlib import Path
import plistlib
import re
import tempfile


def expand(value, bundle_id):
    if isinstance(value, dict):
        return {expand(key, bundle_id): expand(item, bundle_id) for key, item in value.items()}
    if isinstance(value, list):
        return [expand(item, bundle_id) for item in value]
    if isinstance(value, str):
        return value.replace("$(APP_BUNDLE_ID)", bundle_id)
    return value


def embed(template, destination, bundle_id):
    if len((bundle_id + ".Agent.xpc").encode()) >= 128 or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
        raise ValueError("Invalid app bundle identifier")
    value = expand(plistlib.loads(template.read_bytes()), bundle_id)
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / (bundle_id + ".Agent.plist")
    descriptor, temporary = tempfile.mkstemp(prefix=".agent-", dir=destination)
    try:
        with os.fdopen(descriptor, "wb") as output:
            plistlib.dump(value, output)
        os.replace(temporary, target)
        # Bundled job metadata must remain readable after a root-owned installation.
        target.chmod(0o644)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--bundle-id", required=True)
    args = parser.parse_args()
    embed(args.template, args.destination, args.bundle_id)


if __name__ == "__main__":
    main()
