"""Anonymous-pipe lifetime and child isolation contracts."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("secret_input", SCRIPTS / "spike-kopia-secret-input.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class ConfigPipeTests(unittest.TestCase):
    def test_control_config_is_private_and_atomically_published(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "repository.config"
            PROBE.write_config(path, b"fixture payload")
            self.assertEqual(path.read_bytes(), b"fixture payload")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_failed_config_publish_leaves_no_staged_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "repository.config"
            with patch.object(PROBE.os, "replace", side_effect=OSError("fixture failure")):
                with self.assertRaises(OSError):
                    PROBE.write_config(path, b"fixture payload")
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_pipe_delivers_bytes_and_eof_then_closes_descriptor(self):
        payload = b'{"password":"synthetic-value"}'
        with PROBE.config_pipe(payload) as descriptor:
            self.assertFalse(os.get_inheritable(descriptor))
            self.assertEqual(os.read(descriptor, 65536), payload)
            self.assertEqual(os.read(descriptor, 1), b"")
        with self.assertRaises(OSError):
            os.fstat(descriptor)

    def test_pipe_closes_when_child_rejects_without_reading(self):
        with self.assertRaisesRegex(RuntimeError, "fixture failure"):
            with PROBE.config_pipe(b"x" * 65536):
                raise RuntimeError("fixture failure")

    def test_oversized_configuration_is_rejected_before_opening_pipe(self):
        with patch.object(PROBE.os, "pipe") as create:
            with self.assertRaises(PROBE.ProbeError):
                with PROBE.config_pipe(b"x" * 65537):
                    self.fail("Oversized payload was accepted")
            create.assert_not_called()

    def test_pipe_descriptor_only_is_in_argv_and_inheritance_is_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            spike = PROBE.BACKENDS.CLI.Spike(directory, Path("/fixture/kopia"))
            result = subprocess.CompletedProcess([], 0, b"", b"")
            with patch.object(PROBE.subprocess, "run", return_value=result) as run:
                PROBE.pipe_status(spike, b'{"password":"synthetic-value"}')
            args, options = run.call_args
            self.assertNotIn("synthetic-value", str(args))
            self.assertNotIn("synthetic-value", str(options["env"]))
            self.assertEqual(len(options["pass_fds"]), 1)
            descriptor = options["pass_fds"][0]
            self.assertIn("--config-file=/dev/fd/" + str(descriptor), args[0])
            self.assertEqual(options["stdin"], subprocess.DEVNULL)
            self.assertEqual(options["timeout"], 30)
            with self.assertRaises(OSError):
                os.fstat(descriptor)


if __name__ == "__main__":
    unittest.main()
