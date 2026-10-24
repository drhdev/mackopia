"""HTTP fixtures bind numeric loopback addresses without depending on reverse DNS."""

from http.server import ThreadingHTTPServer
from socketserver import TCPServer


class LoopbackHTTPServer(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind calls getfqdn, which can stall on hosted macOS runners.
        # These private fixtures have no hostname-based routing or external DNS dependency.
        if self.server_address[0] != "127.0.0.1":
            raise ValueError("fixture must bind IPv4 loopback")
        TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]
