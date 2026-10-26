"""SFTP bootstrap argument and fixture cleanup boundaries."""

import importlib.util
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("sftp_auth", SCRIPTS / "spike-kopia-sftp-auth.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)
import sftp_probe_fixture as FIXTURE


class SFTPAuthTests(unittest.TestCase):
    def test_create_only_passes_key_via_inherited_pipe(self):
        spike = SimpleNamespace(base=["kopia", "--config-file=/fixture/config"],
                                root=Path("/fixture"), env={"KOPIA_PASSWORD": "backup-secret"},
                                working=Path("/fixture"))
        config = {"storage": {"config": {
            "keyData": "private-key-data", "path": "/storage", "host": "127.0.0.1",
            "port": 1234, "username": "fixture", "knownHostsFile": "/known_hosts",
        }}}
        result = subprocess.CompletedProcess([], 0, b"", b"")
        with patch.object(PROBE.INPUT.LIFECYCLE.INPUT, "config_pipe") as pipe:
            pipe.return_value.__enter__.return_value = 42
            with patch.object(PROBE.subprocess, "run", return_value=result) as run:
                self.assertIs(PROBE.create(spike, config), result)
        pipe.assert_called_once_with(b"private-key-data")
        args, options = run.call_args
        self.assertNotIn("private-key-data", str(args))
        self.assertNotIn("backup-secret", str(args))
        self.assertIn("--create-only", args[0])
        self.assertIn("--keyfile=/dev/fd/42", args[0])
        self.assertEqual(options["pass_fds"], (42,))
        self.assertTrue(options["capture_output"])
        self.assertEqual(options["timeout"], 30)

    def test_fixture_errors_are_sanitized(self):
        result = subprocess.CompletedProcess([], 1, b"private-output", b"private-error")
        with self.assertRaises(PROBE.ProbeError) as error:
            FIXTURE.checked(result, "test stage")
        self.assertEqual(str(error.exception), "SFTP fixture failed at test stage")

    def test_fixture_escalates_cleanup_after_timeout(self):
        from unittest.mock import Mock
        process = Mock()
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired("fixture", 5), 0]
        FIXTURE.stop(process)
        process.terminate.assert_called_once()
        process.kill.assert_called_once()
        self.assertEqual(process.wait.call_count, 2)

    def test_fixture_reaps_exited_process(self):
        from unittest.mock import Mock
        process = Mock()
        process.poll.return_value = 0
        FIXTURE.stop(process)
        process.terminate.assert_not_called()
        process.kill.assert_not_called()
        process.wait.assert_called_once_with(timeout=5)


if __name__ == "__main__":
    unittest.main()
