"""Loopback-only HTTP range server for the generated subtitle fixture."""
import argparse
import http.server
import re
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("fixture", type=Path)
parser.add_argument("port_file", type=Path)
args = parser.parse_args()
data = args.fixture.read_bytes()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/synthetic-pgs.mkv":
            self.send_error(404)
            return
        match = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
        start = int(match[1]) if match else 0
        end = min(int(match[2]), len(data) - 1) if match and match[2] else len(data) - 1
        if start > end:
            self.send_error(416)
            return
        self.send_response(206 if match else 200)
        self.send_header("Content-Type", "video/x-matroska")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        if match:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.end_headers()
        try:
            self.wfile.write(data[start : end + 1])
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
args.port_file.write_text(str(server.server_port), encoding="ascii")
server.serve_forever()
