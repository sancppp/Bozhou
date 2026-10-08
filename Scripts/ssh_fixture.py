#!/usr/bin/env python3
"""Project-local SSH/SFTP fixture. No system services or user SSH files are touched."""
import asyncio
import json
import os
from pathlib import Path
import pty
import signal
import fcntl
import struct
import termios
import socket
import asyncssh

ROOT = Path(__file__).resolve().parent.parent / ".runtime" / "integration"
ROOT.mkdir(parents=True, exist_ok=True)
REMOTE = ROOT / "remote"
REMOTE.mkdir(exist_ok=True)
for name in ("tmp", "zsh-home"):
    (ROOT / name).mkdir(exist_ok=True)
TEST_ENV = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "SHELL": "/bin/bash", "HISTFILE": "/dev/null", "TERM": "xterm-256color",
    "LANG": "en_US.UTF-8",
    "TMPDIR": str(ROOT / "tmp"), "ZDOTDIR": str(ROOT / "zsh-home"),
    "BASH_SILENCE_DEPRECATION_WARNING": "1",
}
CLIENT_KEY = asyncssh.generate_private_key("ssh-ed25519")
HOST_KEY = asyncssh.generate_private_key("ssh-ed25519")
CLIENT_KEY.write_private_key(ROOT / "id_ed25519")
os.chmod(ROOT / "id_ed25519", 0o600)
(ROOT / "id_ed25519.pub").write_bytes(CLIENT_KEY.export_public_key())


class Server(asyncssh.SSHServer):
    def __init__(self, routes=None):
        self.routes = routes or {}

    def connection_made(self, connection):
        self.connection = connection
        CONNECTIONS.add(connection)

    def connection_lost(self, exc):
        CONNECTIONS.discard(self.connection)

    def begin_auth(self, username):
        return True

    def password_auth_supported(self):
        return True

    def validate_password(self, username, password):
        return password == {"jump1": "jump-one-test-only", "jump2": "bozhou-test-only",
                            "tester": "target-test-only"}.get(username)

    def public_key_auth_supported(self):
        return True

    def validate_public_key(self, username, key):
        return username in ("jump1", "jump2", "tester") and key == CLIENT_KEY.convert_to_public()

    def connection_requested(self, dest_host, dest_port, orig_host, orig_port):
        # Different gateways resolve the same documentation-only endpoint to
        # different loopback servers. No traffic leaves the fixture.
        if (dest_host, dest_port) in self.routes:
            return self.connection.forward_connection("127.0.0.1", self.routes[(dest_host, dest_port)])
        # Forward only to project-owned loopback SSH/HTTP listeners.
        return dest_host == "127.0.0.1" and dest_port in PORTS + [HTTP_PORT]


PORTS = []
CONNECTIONS = set()
HTTP_PORT = 0


async def run_command(process, remote):
    # Interactive test startup must not source the developer's shell configuration.
    command = (process.command or "/bin/bash --noprofile --norc -i").replace(
        "[[ -r ~/.bashrc ]] && source ~/.bashrc", "HISTFILE=/dev/null"
    )
    if process.term_type:
        await run_terminal(process, command, remote)
        return
    child = await asyncio.create_subprocess_shell(
        command, cwd=remote, stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
        env=TEST_ENV,
    )
    writer, reader = child.stdin, child.stdout
    assert writer is not None and reader is not None

    async def input_loop():
        try:
            while True:
                data = await process.stdin.read(32768)
                if not data:
                    writer.close()
                    return
                writer.write(data)
                await writer.drain()
        except (BrokenPipeError, ConnectionResetError, asyncssh.BreakReceived):
            pass

    async def output_loop():
        while True:
            data = await reader.read(32768)
            if not data:
                return
            process.stdout.write(data)
            await process.stdout.drain()

    incoming = asyncio.create_task(input_loop())
    try:
        await output_loop()
        process.exit(await child.wait())
    finally:
        incoming.cancel()
        if child.returncode is None:
            child.terminate()


async def run_terminal(process, command, remote):
    """A real PTY is required for readline, signals, line endings and resize."""
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(remote)
        os.execve("/bin/sh", ["sh", "-c", command], {
            **TEST_ENV, "TERM": process.term_type,
        })
    loop = asyncio.get_running_loop()
    os.set_blocking(fd, False)
    ended = loop.create_future()

    def resize(size):
        cols, rows, xpixels, ypixels = size
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, xpixels, ypixels))

    def readable():
        try:
            data = os.read(fd, 32768)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if data:
            process.stdout.write(data)
        else:
            loop.remove_reader(fd)
            if not ended.done():
                ended.set_result(None)

    async def incoming():
        while True:
            try:
                data = await process.stdin.read(32768)
                if not data:
                    os.killpg(pid, signal.SIGHUP)
                    return
                while data:
                    try:
                        count = os.write(fd, data)
                        data = data[count:]
                    except BlockingIOError:
                        writable = loop.create_future()
                        loop.add_writer(fd, lambda: not writable.done() and writable.set_result(None))
                        try:
                            await writable
                        finally:
                            loop.remove_writer(fd)
            except asyncssh.TerminalSizeChanged as event:
                resize(event.term_size)
            except (OSError, asyncssh.BreakReceived, asyncssh.SignalReceived):
                return

    resize(process.term_size)
    loop.add_reader(fd, readable)
    reader = asyncio.create_task(incoming())
    try:
        await ended
        _, status = await asyncio.to_thread(os.waitpid, pid, 0)
        code = os.waitstatus_to_exitcode(status)
        process.exit(code if code >= 0 else 128 - code)
    finally:
        reader.cancel()
        loop.remove_reader(fd)
        os.close(fd)
        try:
            os.killpg(pid, signal.SIGHUP)
        except ProcessLookupError:
            pass


async def main():
    global HTTP_PORT
    servers = []
    async def serve_http(reader, writer):
        try:
            await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=3)
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 14\r\nConnection: close\r\n\r\nforwarding-ok\n")
            await writer.drain()
        except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            writer.close()
    http_server = await asyncio.start_server(serve_http, "127.0.0.1", 0)
    HTTP_PORT = http_server.sockets[0].getsockname()[1]
    for index in range(3):
        remote = REMOTE / f"server-{index}"
        remote.mkdir(exist_ok=True)
        server = await asyncssh.create_server(
            Server, "127.0.0.1", 0, server_host_keys=[HOST_KEY],
            process_factory=lambda process, remote=remote: run_command(process, remote), encoding=None,
            sftp_factory=lambda chan, remote=remote: asyncssh.SFTPServer(chan, chroot=str(remote)),
        )
        servers.append(server)
        PORTS.append(server.get_port())
    key = HOST_KEY.export_public_key().decode().strip()
    (ROOT / "known_hosts").write_text("".join(f"[127.0.0.1]:{port} {key}\n" for port in PORTS))
    wrong_key = asyncssh.generate_private_key("ssh-ed25519").export_public_key().decode().strip()
    (ROOT / "wrong_known_hosts").write_text("".join(f"[127.0.0.1]:{port} {wrong_key}\n" for port in PORTS))
    routes = []
    for site in ("a", "b"):
        mapping = {}
        for role, address in (("target", "192.0.2.2"), ("relay", "192.0.2.1"), ("gateway", None)):
            remote = REMOTE / f"route-{site}-{role}"
            remote.mkdir(exist_ok=True)
            (remote / f"site-{site}.txt").write_text(f"site-{site}\n")
            route_key = asyncssh.generate_private_key("ssh-ed25519")
            server = await asyncssh.create_server(
                lambda mapping=mapping: Server(mapping), "127.0.0.1", 0,
                server_host_keys=[route_key],
                process_factory=lambda process, remote=remote: run_command(process, remote), encoding=None,
                sftp_factory=lambda chan, remote=remote: asyncssh.SFTPServer(chan, chroot=str(remote)),
            )
            servers.append(server)
            if address:
                mapping[(address, 22)] = server.get_port()
            else:
                routes.append({"gateway_port": server.get_port(), "site": site,
                               "gateway_key": route_key.export_public_key().decode().strip()})
    with socket.socket() as free_port:
        free_port.bind(("127.0.0.1", 0))
        local_port = free_port.getsockname()[1]
    (ROOT / "fixture.json").write_text(json.dumps({"ports": PORTS, "http_port": HTTP_PORT, "forward_port": local_port,
                                                "root": str(ROOT), "routes": routes, "wrong_key": wrong_key}))
    print(json.dumps({"ready": True, "ports": PORTS}), flush=True)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    # UI reconnect verification: close only active fixture transports, retaining listeners/keys.
    loop.add_signal_handler(signal.SIGUSR1, lambda: [conn.abort() for conn in list(CONNECTIONS)])
    await stop.wait()
    http_server.close()
    await http_server.wait_closed()
    for connection in list(CONNECTIONS):
        connection.abort()
    for server in servers:
        server.close()
        await server.wait_closed()


asyncio.run(main())
