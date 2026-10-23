"""Isolation and redaction contracts for the Phase-0 probe."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("kopia_spike", Path(__file__).parents[1] / "spike-kopia-cli.py")
SPIKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SPIKE)


class SpikeTests(unittest.TestCase):
    def test_child_receives_isolated_paths_and_secret_only_in_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            spike = SPIKE.Spike(temporary, Path("/fixture/kopia"))
            with patch.object(SPIKE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "{}", "")) as run:
                spike.run("repository", "status", "--json")
            args, options = run.call_args
            self.assertNotIn(spike.password, " ".join(args[0]))
            self.assertIn("--config-file=" + temporary + "/repository.config", args[0])
            self.assertIn("--log-dir=" + temporary + "/logs", args[0])
            self.assertIn("--no-persist-credentials", args[0])
            self.assertIn("--no-use-keychain", args[0])
            self.assertEqual(options["env"]["KOPIA_PASSWORD"], spike.password)
            self.assertEqual(options["env"]["KOPIA_CACHE_DIRECTORY"], temporary + "/cache")
            self.assertEqual(options["env"]["KOPIA_CHECK_FOR_UPDATES"], "false")
            self.assertEqual(options["env"]["HOME"], temporary)
            self.assertTrue(options["capture_output"])
            self.assertEqual(options["timeout"], 120)

    def test_error_does_not_expose_child_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            spike = SPIKE.Spike(temporary, Path("/fixture/kopia"))
            result = subprocess.CompletedProcess([], 1, spike.password, spike.password)
            with patch.object(SPIKE.subprocess, "run", return_value=result):
                with self.assertRaises(RuntimeError) as error:
                    spike.run("repository", "status")
            self.assertNotIn(spike.password, str(error.exception))

    def test_fixture_dictionary_keys_are_scrubbed(self):
        with tempfile.TemporaryDirectory() as temporary:
            spike = SPIKE.Spike(temporary, Path("/fixture/kopia"))
            self.assertEqual(spike.scrub({"test-user@test-host:" + temporary + "/source": {"success": True}}),
                             {"test-user@test-host:/fixture/source": {"success": True}})

    def test_nested_fixture_redaction(self):
        with tempfile.TemporaryDirectory() as temporary:
            spike = SPIKE.Spike(temporary, Path("/fixture/kopia"))
            scrubbed = spike.scrub({"items": [{"path": temporary + "/source", "value": spike.password}]})
            self.assertEqual(scrubbed, {"items": [{"path": "/fixture/source", "value": "[REDACTED]"}]})


if __name__ == "__main__":
    unittest.main()
