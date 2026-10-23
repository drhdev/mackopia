"""Fail-closed handshake and transport checks without live sockets or stored secrets."""

import base64
import importlib.util
import io
from pathlib import Path
import secrets
import signal
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

SPEC = importlib.util.spec_from_file_location("server_probe", Path(__file__).parents[1] / "kopia_server_probe.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


def handshake(address="https://127.0.0.1:12345"):
    result = PROBE.Handshake()
    values = [address, "a" * 64, base64.b64encode(b"synthetic certificate").decode(),
              secrets.token_urlsafe(32), secrets.token_urlsafe(32)]
    for prefix, value in zip(result.PREFIXES, values):
        result.feed(prefix + ": " + value)
    return result


class HandshakeTests(unittest.TestCase):
    def test_only_https_ipv4_loopback_with_explicit_port_is_accepted(self):
        self.assertEqual(handshake().validate(), 12345)
        for address in ["http://127.0.0.1:12345", "https://0.0.0.0:12345", "https://localhost:12345",
                        "https://user@127.0.0.1:12345", "https://127.0.0.1:12345/path",
                        "https://127.0.0.1:0", "https://127.0.0.1:99999", "https://127.0.0.1:12345?redirect=1"]:
            with self.subTest(address=address), self.assertRaises(PROBE.ProbeError):
                handshake(address).validate()

    def test_missing_empty_and_duplicate_fields_are_rejected(self):
        with self.assertRaises(PROBE.ProbeError):
            PROBE.Handshake().validate()
        with self.assertRaises(PROBE.ProbeError):
            PROBE.Handshake().feed("SERVER PASSWORD: ")
        value = handshake()
        with self.assertRaises(PROBE.ProbeError):
            value.feed("SERVER ADDRESS: https://127.0.0.1:12345")

    def test_invalid_fingerprint_is_rejected(self):
        value = handshake()
        value.values["SERVER CERT SHA256"] = "invalid"
        with self.assertRaises(PROBE.ProbeError):
            value.validate()

    def test_unknown_lines_are_not_retained(self):
        value = PROBE.Handshake()
        value.feed("log: SERVER PASSWORD: " + secrets.token_urlsafe(32))
        self.assertEqual(value.values, {})

    def test_oversized_stream_fails_without_retaining_output(self):
        server = PROBE.Server(object())
        server.process = SimpleNamespace(stderr=io.BytesIO(b"x" * 16385 + b"\n"))
        server._stderr()
        self.assertIsInstance(server.failure, PROBE.ProbeError)
        self.assertTrue(server.ready.is_set())
        self.assertEqual(server.handshake.values, {})


class PinningTests(unittest.TestCase):
    def test_handshake_certificate_mismatch_prevents_trust_initialization(self):
        with patch.object(PROBE.ssl, "PEM_cert_to_DER_cert", return_value=b"different certificate"):
            with patch.object(PROBE.ssl, "SSLContext") as context:
                with self.assertRaisesRegex(PROBE.ProbeError, "fingerprint mismatch"):
                    PROBE.PinnedClient(handshake())
                context.assert_not_called()

    def test_peer_pin_mismatch_prevents_http_and_credentials(self):
        client = object.__new__(PROBE.PinnedClient)
        client.port, client.pin, client.context = 12345, "a" * 64, object()
        connection = MagicMock()
        connection.sock.getpeercert.return_value = b"untrusted peer"
        with patch.object(PROBE.http.client, "HTTPSConnection", return_value=connection):
            with self.assertRaisesRegex(PROBE.ProbeError, "Peer certificate fingerprint mismatch"):
                client.request("/api/v1/repo/status")
        connection.request.assert_not_called()
        connection.close.assert_called_once()

    def test_malformed_certificate_is_rejected(self):
        with self.assertRaises(PROBE.ProbeError):
            PROBE.PinnedClient(handshake())


class LifecycleTests(unittest.TestCase):
    def test_descriptor_inheritance_is_explicit_and_empty_by_default(self):
        spike = SimpleNamespace(base=["/fixture/kopia"], root=Path("/fixture"), env={}, working=Path("/fixture"))
        for descriptors in ((), (42,)):
            server = PROBE.Server(spike, pass_fds=descriptors)
            with patch.object(PROBE.subprocess, "Popen") as popen, \
                 patch.object(PROBE.threading, "Thread"), \
                 patch.object(PROBE.PinnedClient, "__init__", return_value=None), \
                 patch.object(server.ready, "wait", return_value=True):
                server.__enter__()
            self.assertEqual(popen.call_args.kwargs["pass_fds"], descriptors)
        self.assertEqual(PROBE.Server(spike).pass_fds, ())

    def test_eof_timeout_escalates_and_reaps_the_owned_process_group(self):
        server = PROBE.Server(object())
        server.process = MagicMock(pid=12345)
        server.process.wait.side_effect = [subprocess.TimeoutExpired("probe", 10),
                                          subprocess.TimeoutExpired("probe", 10), 0]
        with patch.object(PROBE.os, "killpg") as kill:
            server.close()
        self.assertEqual([call.args for call in kill.call_args_list],
                         [(12345, signal.SIGINT), (12345, signal.SIGTERM)])
        server.process.stdin.close.assert_called_once()
        server.process.stdout.close.assert_called_once()
        server.process.stderr.close.assert_called_once()
        self.assertFalse(server.clean_shutdown)


if __name__ == "__main__":
    unittest.main()
