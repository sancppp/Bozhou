"""Loopback-only streaming fixture for the updater's real URLSession transport."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/missing":
            self.send_error(404)
            return
        size = 512 * 1024 if self.path == "/slow" else 64 * 1024
        self.send_response(200)
        self.send_header("Content-Length", str(size))
        self.end_headers()
        try:
            for _ in range(size // 1024):
                self.wfile.write(b"x" * 1024)
                self.wfile.flush()
                if self.path == "/slow":
                    time.sleep(0.02)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
