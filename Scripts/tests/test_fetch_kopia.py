"""Fail-closed archive verification tests; no network or user repositories."""

import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("fetch_kopia", Path(__file__).parents[1] / "fetch_kopia.py")
FETCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FETCH)


class ArchiveTests(unittest.TestCase):
    def test_signing_is_disabled_by_default_and_when_explicitly_disabled(self):
        for environment in ({}, {"CODE_SIGNING_ALLOWED": "NO"}):
            with patch.dict(FETCH.os.environ, environment, clear=True), patch.object(FETCH, "run") as command:
                FETCH.sign_binary(Path("/fixture/kopia"))
                command.assert_not_called()

    def test_signing_requires_explicit_enablement(self):
        with patch.dict(FETCH.os.environ, {"CODE_SIGNING_ALLOWED": "YES"}, clear=True):
            with patch.object(FETCH, "run") as command:
                FETCH.sign_binary(Path("/fixture/kopia"))
                self.assertEqual(command.call_count, 2)
                self.assertEqual(command.call_args_list[0].args[:4], ("/usr/bin/codesign", "--force", "--sign", "-"))
                self.assertEqual(command.call_args_list[1].args[:3], ("/usr/bin/codesign", "--verify", "--strict"))

    def test_main_uses_only_verified_arm64_archive_and_preserves_output_on_wrong_architecture(self):
        for architecture in ("arm64", "x86_64"):
            with self.subTest(architecture=architecture), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "Config").mkdir()
                cache = root / "Vendor/kopia/test"
                cache.mkdir(parents=True)
                archive = cache / "kopia-test-macOS-arm64.tar.gz"
                with tarfile.open(archive, "w:gz") as tar:
                    for name, value in (("kopia", b"native binary"), ("LICENSE", b"license"), ("README.md", b"readme")):
                        member = tarfile.TarInfo("release/" + name)
                        member.size = len(value)
                        tar.addfile(member, io.BytesIO(value))
                pin = {"version": "test", "sha256": {"arm64": hashlib.sha256(archive.read_bytes()).hexdigest()}}
                (root / "Config/kopia-version.json").write_text(FETCH.json.dumps(pin))
                (cache / "kopia").write_bytes(b"previous binary")
                with patch.object(FETCH, "ROOT", root), patch.object(FETCH.urllib.request, "urlopen") as network:
                    with patch.object(FETCH.subprocess, "check_output", return_value=architecture):
                        with patch.object(FETCH, "sign_binary"), contextlib.redirect_stdout(io.StringIO()):
                            if architecture == "arm64":
                                FETCH.main()
                                self.assertEqual((cache / "kopia").read_bytes(), b"native binary")
                                self.assertEqual((cache / "LICENSE").read_bytes(), b"license")
                            else:
                                with self.assertRaisesRegex(ValueError, "only the supported arm64"):
                                    FETCH.main()
                                self.assertEqual((cache / "kopia").read_bytes(), b"previous binary")
                    network.assert_not_called()
                self.assertFalse(any("amd64" in item.name or "x64" in item.name for item in cache.iterdir()))

    def test_modified_cache_is_rejected_without_network(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "kopia.tar.gz"
            archive.write_bytes(b"modified")
            expected = hashlib.sha256(b"original").hexdigest()
            with patch.object(FETCH.urllib.request, "urlopen") as network:
                with self.assertRaisesRegex(ValueError, "Cached Kopia archive failed SHA256"):
                    FETCH.fetch_archive("https://example.invalid/kopia", archive, expected)
                network.assert_not_called()
            self.assertEqual(archive.read_bytes(), b"modified")

    def test_bad_download_is_not_cached(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "kopia.tar.gz"
            with patch.object(FETCH.urllib.request, "urlopen", return_value=io.BytesIO(b"bad")):
                with self.assertRaisesRegex(ValueError, "Downloaded Kopia archive failed SHA256"):
                    FETCH.fetch_archive("https://example.invalid/kopia", archive, "0" * 64)
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_verified_cache_needs_no_network(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "kopia.tar.gz"
            archive.write_bytes(b"verified")
            with patch.object(FETCH.urllib.request, "urlopen") as network:
                FETCH.fetch_archive("https://example.invalid/kopia", archive, hashlib.sha256(b"verified").hexdigest())
                network.assert_not_called()

    def test_extraction_never_uses_archive_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "kopia.tar.gz"
            output = Path(temporary) / "output"
            with tarfile.open(archive, "w:gz") as tar:
                member = tarfile.TarInfo("../../kopia")
                member.size = 6
                tar.addfile(member, io.BytesIO(b"binary"))
            FETCH.extract_member(archive, "kopia", output)
            self.assertEqual(output.read_bytes(), b"binary")
            self.assertEqual({p.name for p in Path(temporary).iterdir()}, {"kopia.tar.gz", "output"})

    def test_symbolic_link_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "kopia.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                member = tarfile.TarInfo("kopia")
                member.type = tarfile.SYMTYPE
                member.linkname = "/usr/bin/true"
                tar.addfile(member)
            with self.assertRaisesRegex(ValueError, "Expected exactly one"):
                FETCH.extract_member(archive, "kopia", Path(temporary) / "output")


if __name__ == "__main__":
    unittest.main()
