"""Isolation checks for the disposable backend credential probe."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))

SPEC = importlib.util.spec_from_file_location("secrets_spike", Path(__file__).parents[1] / "spike-kopia-secrets.py")
SPIKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SPIKE)


class SecretsSpikeTests(unittest.TestCase):
    def test_backend_secret_only_reaches_child_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            spike = SPIKE.CLI.Spike(directory, Path("/fixture/kopia"))
            result = subprocess.CompletedProcess([], 0, b"", b"")
            with patch.object(SPIKE.subprocess, "run", return_value=result) as run:
                SPIKE.invoke(spike, ["repository", "status"], {"AWS_SECRET_ACCESS_KEY": "fixture-secret"})
            args, options = run.call_args
            self.assertNotIn("fixture-secret", str(args))
            self.assertEqual(options["env"]["AWS_SECRET_ACCESS_KEY"], "fixture-secret")
            self.assertEqual(options["env"]["HOME"], directory)
            self.assertEqual(options["stdin"], subprocess.DEVNULL)
            self.assertEqual(options["timeout"], 30)
            self.assertTrue(options["capture_output"])
            self.assertTrue(options["start_new_session"])
            self.assertNotIn("AWS_SECRET_ACCESS_KEY", spike.env)

    def test_import_does_not_start_server_or_child(self):
        with patch.object(SPIKE.subprocess, "run") as run, patch.object(SPIKE, "ThreadingHTTPServer") as server:
            SPEC.loader.exec_module(SPIKE)
            run.assert_not_called()
            server.assert_not_called()


if __name__ == "__main__":
    unittest.main()
