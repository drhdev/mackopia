"""Loopback fixture startup must never wait for external hostname resolution."""

from http.server import BaseHTTPRequestHandler
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
from loopback_http_server import LoopbackHTTPServer


class LoopbackHTTPServerTests(unittest.TestCase):
    def test_binding_never_resolves_a_hostname(self):
        with patch("socket.getfqdn", side_effect=AssertionError("unexpected DNS lookup")) as resolve:
            with LoopbackHTTPServer(("127.0.0.1", 0), BaseHTTPRequestHandler) as server:
                self.assertEqual(server.server_name, "127.0.0.1")
                self.assertGreater(server.server_port, 0)
                self.assertEqual(server.server_address, ("127.0.0.1", server.server_port))
            resolve.assert_not_called()

    def test_nonloopback_binding_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "loopback"):
            LoopbackHTTPServer(("0.0.0.0", 0), BaseHTTPRequestHandler)
