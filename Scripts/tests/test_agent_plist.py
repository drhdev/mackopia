"""The embedded launchd job must match the app identity and actual helper location."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("agent_plist", Path(__file__).parents[1] / "embed-agent-plist.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
TEMPLATE = Path(__file__).parents[2] / "Agent/LaunchAgent/Agent.plist"


class AgentPlistTests(unittest.TestCase):
    def test_expands_keys_and_values_for_custom_bundle_prefix(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = MODULE.embed(TEMPLATE, Path(temporary), "org.test.MacKopia")
            value = plistlib.loads(path.read_bytes())
            self.assertEqual(path.stat().st_mode & 0o777, 0o644)
            self.assertEqual(path.name, "org.test.MacKopia.Agent.plist")
            self.assertEqual(value["Label"], "org.test.MacKopia.Agent")
            self.assertEqual(value["MachServices"], {"org.test.MacKopia.Agent.xpc": True})
            self.assertEqual(value["AssociatedBundleIdentifiers"], ["org.test.MacKopia"])
            self.assertEqual(value["BundleProgram"], "Contents/Library/LoginItems/MacKopia Agent.app/Contents/MacOS/MacKopia Agent")
            self.assertEqual(value["KeepAlive"], {"SuccessfulExit": False})
            self.assertEqual(value["LimitLoadToSessionType"], "Aqua")
            self.assertEqual(value["ProcessType"], "Standard")
            self.assertNotIn("RunAtLoad", value)
            self.assertNotIn("ProgramArguments", value)
            self.assertNotIn("EnvironmentVariables", value)
            self.assertEqual(list(Path(temporary).iterdir()), [path])

    def test_rejects_untrusted_identity_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            for value in ("", "../escape", "com..test", "com.test/other", "com.ü", "a" * 201 + ".b", "com." + "a" * 114):
                with self.assertRaises(ValueError):
                    MODULE.embed(TEMPLATE, Path(temporary), value)
            self.assertEqual(list(Path(temporary).iterdir()), [])
