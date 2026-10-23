"""Privacy and cleanup contracts around the disposable remote lifecycle probe."""

import importlib.util
import fcntl
from pathlib import Path
import subprocess
import os
import tempfile
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("remote_lifecycle", SCRIPTS / "spike-kopia-remote-lifecycle.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class RemoteLifecycleTests(unittest.TestCase):
    def test_runtime_directory_blocks_config_writes_but_allows_shared_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            spike = SimpleNamespace(root=Path(directory))
            with PROBE.protected_config(spike, b"fixture payload") as (path, descriptor):
                self.assertTrue(path.is_symlink())
                self.assertEqual(path.read_bytes(), b"fixture payload")
                self.assertEqual(path.parent.stat().st_mode & 0o777, 0o500)
                with self.assertRaises(PermissionError):
                    os.open(path.parent / "blocked", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                lock = path.parent / "repository.config.mlock"
                lock_fd = os.open(lock, os.O_RDWR)
                os.close(lock_fd)
                self.assertEqual(lock.stat().st_mode & 0o777, 0o600)
                self.assertEqual(os.read(descriptor, 1), b"")
            self.assertFalse(path.parent.exists())
            self.assertEqual(list(Path(directory).iterdir()), [Path(directory) / "repository.mlock"])

    def test_fresh_runtime_paths_use_the_same_maintenance_lock_inode(self):
        with tempfile.TemporaryDirectory() as directory:
            spike = SimpleNamespace(root=Path(directory))
            with PROBE.protected_config(spike, b"one") as (first, _):
                with PROBE.protected_config(spike, b"two") as (second, _):
                    self.assertNotEqual(first.parent, second.parent)
                    self.assertEqual((first.parent / "repository.config.mlock").stat().st_ino,
                                     (second.parent / "repository.config.mlock").stat().st_ino)
                    first_fd = os.open(first.parent / "repository.config.mlock", os.O_RDWR)
                    second_fd = os.open(second.parent / "repository.config.mlock", os.O_RDWR)
                    try:
                        fcntl.flock(first_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        with self.assertRaises(BlockingIOError):
                            fcntl.flock(second_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    finally:
                        os.close(first_fd)
                        os.close(second_fd)

    def test_failure_does_not_export_child_output(self):
        result = subprocess.CompletedProcess([], 1, b"synthetic private output", b"synthetic private error")
        with self.assertRaises(PROBE.ProbeError) as error:
            PROBE.require_success(result, "fixture stage")
        self.assertEqual(str(error.exception), "Remote lifecycle probe failed at fixture stage")

    def test_pipe_configuration_restored_when_server_rejects_startup(self):
        original = ["/fixture/kopia", "--config-file=/fixture/repository.config"]
        spike = SimpleNamespace(base=original)
        with patch.object(PROBE, "protected_config") as pipe, patch.object(PROBE, "Server") as server:
            pipe.return_value.__enter__.return_value = (Path("/fixture/runtime/repository.config"), 42)
            server.return_value.__enter__.side_effect = PROBE.ProbeError("fixture failure")
            with self.assertRaises(PROBE.ProbeError):
                with PROBE.pipe_server(spike, b"fixture"):
                    self.fail("Server should have rejected startup")
            self.assertIs(spike.base, original)
            self.assertEqual(server.call_args.kwargs["pass_fds"], (42,))
            pipe.return_value.__exit__.assert_called_once()

    def test_pipe_configuration_restored_when_caller_fails(self):
        original = ["/fixture/kopia", "--config-file=/fixture/repository.config"]
        spike = SimpleNamespace(base=original)
        with patch.object(PROBE, "protected_config") as pipe, patch.object(PROBE, "Server") as server:
            pipe.return_value.__enter__.return_value = (Path("/fixture/runtime/repository.config"), 42)
            server.return_value.__enter__.return_value.client.json.return_value = {"connected": True}
            with self.assertRaisesRegex(RuntimeError, "caller failed"):
                with PROBE.pipe_server(spike, b"fixture"):
                    self.assertIn("--config-file=/fixture/runtime/repository.config", spike.base)
                    self.assertNotIn("--config-file=/fixture/repository.config", spike.base)
                    raise RuntimeError("caller failed")
            self.assertIs(spike.base, original)
            server.return_value.__exit__.assert_called_once()
            pipe.return_value.__exit__.assert_called_once()

    def test_latest_snapshot_is_selected_by_time_after_reconnect(self):
        client = SimpleNamespace(json=lambda _: {"snapshots": [
            {"rootID": "old", "startTime": "2026-10-01T12:00:00Z"},
            {"rootID": "new", "startTime": "2026-10-02T12:00:00Z"}]})
        self.assertEqual(PROBE.latest(client, Path("/fixture/source")), "new")


if __name__ == "__main__":
    unittest.main()
