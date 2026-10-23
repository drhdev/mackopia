"""Fail-closed TLS transport and bounded lifecycle for isolated Phase-0 probes."""

import base64
import hashlib
import hmac
import http.client
from http.cookies import SimpleCookie
import json
import os
import re
import signal
import ssl
import subprocess
import threading
from urllib.parse import urlsplit


class ProbeError(RuntimeError):
    """Messages intentionally exclude child output, request bodies and credentials."""


class Handshake:
    PREFIXES = ("SERVER ADDRESS", "SERVER CERT SHA256", "SERVER CERTIFICATE",
                "SERVER PASSWORD", "SERVER CONTROL PASSWORD")

    def __init__(self):
        self.values = {}

    def feed(self, line):
        for prefix in self.PREFIXES:
            if line.startswith(prefix + ": "):
                if prefix in self.values:
                    raise ProbeError("Duplicate server handshake field")
                value = line[len(prefix) + 2:].strip()
                if not value:
                    raise ProbeError("Empty server handshake field")
                self.values[prefix] = value
                break
        return len(self.values) == len(self.PREFIXES)

    def validate(self):
        if set(self.values) != set(self.PREFIXES):
            raise ProbeError("Incomplete server handshake")
        address = urlsplit(self.values["SERVER ADDRESS"])
        try:
            port = address.port
        except ValueError:
            raise ProbeError("Invalid server port") from None
        if (address.scheme != "https" or address.hostname != "127.0.0.1" or not port
                or address.netloc != "127.0.0.1:" + str(port)
                or address.path or address.query or address.fragment):
            raise ProbeError("Server address must be HTTPS on IPv4 loopback")
        if not re.fullmatch(r"[0-9a-fA-F]{64}", self.values["SERVER CERT SHA256"]):
            raise ProbeError("Invalid server certificate fingerprint")
        return port


class PinnedClient:
    def __init__(self, handshake):
        self.port = handshake.validate()
        self.pin = handshake.values["SERVER CERT SHA256"].lower()
        self.password = handshake.values["SERVER PASSWORD"]
        self.control_password = handshake.values["SERVER CONTROL PASSWORD"]
        try:
            pem = base64.b64decode(handshake.values["SERVER CERTIFICATE"], validate=True).decode("ascii")
            der = ssl.PEM_cert_to_DER_cert(pem)
        except (ValueError, UnicodeError):
            raise ProbeError("Invalid server certificate encoding") from None
        if not hmac.compare_digest(hashlib.sha256(der).hexdigest(), self.pin):
            raise ProbeError("Server certificate fingerprint mismatch")
        # Trust only the exact certificate delivered by the owned child process.
        # Hostname and chain verification remain enabled; never use CERT_NONE.
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        self.context.minimum_version = ssl.TLSVersion.TLSv1_3
        self.context.load_verify_locations(cadata=pem)
        self.session_cookie = None
        self.csrf_token = None

    def request(self, path, method="GET", body=None, expected=200, authenticated=True, control=False, bootstrap=False):
        if not path.startswith("/api/v1/") and not (bootstrap and path == "/"):
            raise ProbeError("Unexpected API path")
        connection = http.client.HTTPSConnection("127.0.0.1", self.port, context=self.context, timeout=10)
        try:
            connection.connect()
            certificate = connection.sock.getpeercert(binary_form=True)
            # Pin the peer before sending any credentials, even if trust validation passed.
            if not hmac.compare_digest(hashlib.sha256(certificate).hexdigest(), self.pin):
                raise ProbeError("Peer certificate fingerprint mismatch")
            headers = {"Content-Type": "application/json"}
            if authenticated:
                user, password = ("server-control", self.control_password) if control else ("mackopia", self.password)
                headers["Authorization"] = "Basic " + base64.b64encode((user + ":" + password).encode()).decode()
            # Kopia 0.23.1 requires the ephemeral session/token pair even on UI API GETs.
            if self.session_cookie and not control:
                headers["Cookie"] = "Kopia-Session-Cookie=" + self.session_cookie
                headers["X-Kopia-CSRF-Token"] = self.csrf_token
            payload = None if body is None else json.dumps(body).encode()
            connection.request(method, path, body=payload, headers=headers)
            response = connection.getresponse()
            content = response.read(4 * 1024 * 1024 + 1)
            if len(content) > 4 * 1024 * 1024:
                raise ProbeError("REST response exceeded probe limit")
            if response.status != expected:
                raise ProbeError("Unexpected REST status: " + str(response.status))
            if bootstrap:
                cookies = SimpleCookie()
                for name, value in response.getheaders():
                    if name.lower() == "set-cookie":
                        cookies.load(value)
                match = re.search(rb'<meta name="kopia-csrf-token" content="([0-9a-f]+)"', content)
                if "Kopia-Session-Cookie" not in cookies or not match:
                    raise ProbeError("Missing ephemeral CSRF session")
                self.session_cookie = cookies["Kopia-Session-Cookie"].value
                self.csrf_token = match.group(1).decode("ascii")
            return content
        finally:
            connection.close()

    def json(self, path, **options):
        content = self.request(path, **options)
        return json.loads(content) if content else None


class Server:
    def __init__(self, spike, ui=True, pass_fds=()):
        self.spike = spike
        self.ui = ui
        self.pass_fds = pass_fds
        self.handshake = Handshake()
        self.ready = threading.Event()
        self.failure = None
        self.diagnostic = None
        self.process = None
        self.threads = []
        self.clean_shutdown = False

    def _stderr(self):
        try:
            while True:
                line = self.process.stderr.readline(16385)
                if not line:
                    break
                if len(line) > 16384:
                    raise ProbeError("Server stderr line exceeded probe limit")
                text = line.decode("utf-8", errors="replace").rstrip("\r\n")
                if "unknown long flag" in text:
                    flags = re.findall(r"--[a-z][a-z-]+", text)
                    self.diagnostic = "Unknown CLI flag: " + ", ".join(flags)
                elif "unexpected" in text.lower():
                    self.diagnostic = "Unexpected CLI argument"
                elif "listen error" in text:
                    self.diagnostic = "Local listen socket unavailable"
                if self.handshake.feed(text):
                    self.ready.set()
        except Exception:
            self.failure = ProbeError("Server handshake stream failed")
        finally:
            self.ready.set()
            # Keep draining after parse failures until the child is reaped.
            while self.process.stderr.read(65536):
                pass

    def _stdout(self):
        while self.process.stdout.read(65536):
            pass

    def __enter__(self):
        # Kopia 0.23.1 disables the REST UI API with --no-ui; --ui does not open a browser.
        arguments = self.spike.base + [
            "server", "start", "--cache-directory=" + str(self.spike.root / "cache"),
            # Kopia 0.23.1: the default 3650-day certificate fails native macOS SSL policy.
            "--address=127.0.0.1:0", "--tls-generate-cert", "--tls-generate-cert-valid-days=365",
            "--tls-generate-rsa-key-size=2048",
            "--tls-print-server-cert", "--random-password", "--random-server-control-password",
            "--server-username=mackopia", "--shutdown-on-stdin", "--ui" if self.ui else "--no-ui", "--no-grpc",
            "--control-api", "--no-check-for-updates", "--no-async-repo-connect",
        ]
        self.process = subprocess.Popen(
            arguments, env=self.spike.env, cwd=self.spike.working,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True, pass_fds=self.pass_fds,
        )
        try:
            self.threads = [threading.Thread(target=reader, daemon=True) for reader in (self._stderr, self._stdout)]
            for thread in self.threads:
                thread.start()
            if not self.ready.wait(30):
                raise ProbeError("Server handshake timed out")
            if self.failure:
                raise self.failure
            if self.diagnostic:
                raise ProbeError(self.diagnostic)
            self.client = PinnedClient(self.handshake)
            return self
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.process is None:
            return
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
            self.clean_shutdown = self.process.returncode == 0
        except subprocess.TimeoutExpired:
            for sig, timeout in ((signal.SIGINT, 10), (signal.SIGTERM, 10), (signal.SIGKILL, 5)):
                try:
                    os.killpg(self.process.pid, sig)
                except ProcessLookupError:
                    pass
                try:
                    self.process.wait(timeout=timeout)
                    break
                except subprocess.TimeoutExpired:
                    continue
            if self.process.poll() is None:
                raise ProbeError("Server could not be reaped")
        for thread in self.threads:
            thread.join(timeout=2)
        self.process.stdout.close()
        self.process.stderr.close()

    def __exit__(self, *_):
        self.close()
