"""Loopback OpenSSH fixture with private keys held only in RAM and ssh-agent."""

from contextlib import contextmanager
import os
from pathlib import Path
import pwd
import socket
import subprocess
import time
import tempfile

from kopia_server_probe import ProbeError


def checked(result, stage):
    if result.returncode:
        raise ProbeError("SFTP fixture failed at " + stage)
    return result.stdout


def stop(process):
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


@contextmanager
def ssh_fixture(root, key, generate_key, environment):
    """Use only a disposable agent socket, public key files and explicit sshd config."""
    root = Path(root)
    root.mkdir(mode=0o700)
    # macOS Unix-domain socket paths are limited to 104 bytes, shorter than Swift's test TMPDIR.
    socket_directory = tempfile.TemporaryDirectory(prefix="mkssh-", dir="/private/tmp")
    agent_socket = Path(socket_directory.name) / "agent.sock"
    env = environment | {"SSH_AUTH_SOCK": str(agent_socket)}
    agent = subprocess.Popen(
        ["/usr/bin/ssh-agent", "-D", "-a", str(agent_socket)], env=env,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    server = None
    try:
        deadline = time.monotonic() + 5
        while not agent_socket.exists():
            if agent.poll() is not None or time.monotonic() >= deadline:
                raise ProbeError("SFTP fixture agent unavailable")
            time.sleep(0.02)
        host_key = generate_key(env)
        checked(subprocess.run(["/usr/bin/ssh-add", "-"], input=host_key, env=env,
                               capture_output=True, timeout=10), "host key loading")
        host_public = checked(subprocess.run(["/usr/bin/ssh-add", "-L"], env=env,
                                            capture_output=True, timeout=10), "host public key")
        checked(subprocess.run(["/usr/bin/ssh-add", "-"], input=key, env=env,
                               capture_output=True, timeout=10), "client key loading")
        public_keys = checked(subprocess.run(["/usr/bin/ssh-add", "-L"], env=env,
                                            capture_output=True, timeout=10), "client public key")
        client_public = [line for line in public_keys.splitlines()
                         if line not in host_public.splitlines()]
        if len(client_public) != 1:
            raise ProbeError("SFTP fixture public key identity ambiguous")
        host_path, authorized = root / "host.pub", root / "authorized_keys"
        host_path.write_bytes(host_public)
        authorized.write_bytes(client_public[0] + b"\n")
        host_path.chmod(0o600)
        authorized.chmod(0o600)
        # Bind first to allocate an ephemeral loopback port; sshd binds immediately after release.
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            port = reserved.getsockname()[1]
        username = pwd.getpwuid(os.getuid()).pw_name
        config = root / "sshd_config"
        config.write_text("\n".join([
            "ListenAddress 127.0.0.1", "Port " + str(port), "PidFile " + str(root / "pid"),
            "HostKey " + str(host_path), "HostKeyAgent " + str(agent_socket),
            "AuthorizedKeysFile " + str(authorized), "StrictModes yes", "UsePAM no",
            "PasswordAuthentication no", "KbdInteractiveAuthentication no", "PubkeyAuthentication yes",
            "AllowUsers " + username, "AllowAgentForwarding no", "AllowTcpForwarding no",
            "X11Forwarding no", "PermitTunnel no", "PermitTTY no", "PermitUserRC no",
            "ForceCommand internal-sftp", "Subsystem sftp internal-sftp", "LogLevel ERROR", "",
        ]))
        checked(subprocess.run(["/usr/sbin/sshd", "-t", "-f", str(config)], env=env,
                               capture_output=True, timeout=10), "sshd configuration")
        server = subprocess.Popen(
            ["/usr/sbin/sshd", "-D", "-e", "-f", str(config)], env=env,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 5
        while True:
            if server.poll() is not None:
                raise ProbeError("SFTP fixture server exited before readiness")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except OSError:
                if time.monotonic() >= deadline:
                    raise ProbeError("SFTP fixture loopback listener unavailable") from None
                time.sleep(0.02)
        known_hosts = root / "known_hosts"
        parts = host_public.split()
        known_hosts.write_bytes(b"[127.0.0.1]:" + str(port).encode() + b" "
                               + parts[0] + b" " + parts[1] + b"\n")
        known_hosts.chmod(0o600)
        yield {"port": port, "username": username, "knownHostsFile": str(known_hosts)}, host_key
    finally:
        if server is not None:
            stop(server)
        stop(agent)
        socket_directory.cleanup()
