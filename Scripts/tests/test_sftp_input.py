"""Secret handling and diagnostic boundaries of the SFTP input probe."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("sftp_input", SCRIPTS / "spike-kopia-sftp-input.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class SFTPInputTests(unittest.TestCase):
    def test_failure_never_exports_raw_diagnostics(self):
        result = subprocess.CompletedProcess([], 1, b"private-output", b"private-error")
        with self.assertRaises(PROBE.ProbeError) as error:
            PROBE.checked_output(result, b"expected", [])
        self.assertEqual(str(error.exception), "SFTP credential parsing contract changed")

    def test_secret_leak_is_rejected_even_with_expected_marker(self):
        for output in (b"private-value expected", b"expected private-value"):
            result = subprocess.CompletedProcess([], 1, output, b"")
            with self.assertRaisesRegex(PROBE.ProbeError, "exposed credential material"):
                PROBE.checked_output(result, b"expected", [b"private-value"])

    def test_success_is_not_evidence_of_expected_rejection(self):
        result = subprocess.CompletedProcess([], 0, b"expected", b"")
        with self.assertRaises(PROBE.ProbeError):
            PROBE.checked_output(result, b"expected", [])

    def test_passphrase_only_in_environment_and_key_only_in_stdin(self):
        result = subprocess.CompletedProcess([], 0, b"ENCRYPTED PRIVATE KEY", b"")
        with patch.object(PROBE.subprocess, "run", return_value=result) as run:
            PROBE.encrypt_key(b"private-key", "private-passphrase", {"HOME": "/fixture"})
        args, options = run.call_args
        self.assertNotIn("private-key", str(args))
        self.assertNotIn("private-passphrase", str(args))
        self.assertEqual(options["input"], b"private-key")
        self.assertEqual(options["env"]["MACKOPIA_PROBE_PASSPHRASE"], "private-passphrase")
        self.assertEqual(options["timeout"], 30)
        self.assertTrue(options["capture_output"])

    def test_decryption_passphrase_and_key_stay_out_of_arguments(self):
        result = subprocess.CompletedProcess([], 0, b"PRIVATE KEY", b"")
        with patch.object(PROBE.subprocess, "run", return_value=result) as run:
            PROBE.decrypt_key(b"encrypted-key", "private-passphrase", {"HOME": "/fixture"})
        args, options = run.call_args
        self.assertNotIn("encrypted-key", str(args))
        self.assertNotIn("private-passphrase", str(args))
        self.assertEqual(options["input"], b"encrypted-key")
        self.assertEqual(options["env"]["MACKOPIA_PROBE_PASSPHRASE"], "private-passphrase")
        self.assertEqual(options["timeout"], 30)
        self.assertTrue(options["capture_output"])

    def test_decryption_failure_never_exports_output_or_partial_key(self):
        for result in (
            subprocess.CompletedProcess([], 1, b"PRIVATE KEY partial-secret", b"private-error"),
            subprocess.CompletedProcess([], 0, b"invalid-output", b"private-error"),
        ):
            with patch.object(PROBE.subprocess, "run", return_value=result):
                with self.assertRaises(PROBE.ProbeError) as error:
                    PROBE.decrypt_key(b"encrypted-key", "wrong-passphrase", {})
            self.assertEqual(str(error.exception), "Could not decrypt in-memory probe key")

    def test_generation_failure_does_not_export_openssl_output(self):
        result = subprocess.CompletedProcess([], 1, b"private-output", b"private-error")
        with patch.object(PROBE.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(PROBE.ProbeError, "Could not generate in-memory probe key"):
                PROBE.generate_key({})


if __name__ == "__main__":
    unittest.main()
