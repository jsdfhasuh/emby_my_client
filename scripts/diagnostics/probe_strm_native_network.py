"""P0 evidence probe; synthetic loopback endpoints, never production media.

Usage: python probe_strm_native_network.py /absolute/path/to/libmpv-2.dll
Success means evidence was collected, NOT that source-direct is supported.
No URL, request header value or native log is emitted.
"""

import argparse
import ctypes
import hashlib
import io
import json
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("library", type=Path)
    args = parser.parse_args()
    payload = io.BytesIO()
    with wave.open(payload, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(8000)
        audio.writeframes(b"\0\0" * 16000)
    media = payload.getvalue()
    received = []

    class Fixture(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            received.append((self.server.server_port, self.path, dict(self.headers)))
            if self.path.startswith("/redirect"):
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{other.server_port}/media")
                self.end_headers()
                return
            if self.path.startswith("/hop/"):
                hop = int(self.path.rsplit("/", 1)[1])
                if hop < 6:
                    self.send_response(302)
                    self.send_header("Location", f"/hop/{hop + 1}")
                    self.end_headers()
                    return
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(media)))
            self.end_headers()
            try:
                self.wfile.write(media)
            except (BrokenPipeError, ConnectionResetError):
                pass

    first = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    other = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    for server in (first, other):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    lib = ctypes.CDLL(str(args.library.resolve()))
    lib.mpv_create.restype = ctypes.c_void_p
    lib.mpv_initialize.argtypes = [ctypes.c_void_p]
    lib.mpv_set_option_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.mpv_set_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.mpv_get_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.mpv_get_property_string.restype = ctypes.c_void_p
    lib.mpv_command.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p)]
    lib.mpv_free.argtypes = [ctypes.c_void_p]
    lib.mpv_terminate_destroy.argtypes = [ctypes.c_void_p]
    ctx = lib.mpv_create()
    assert ctx

    def checked(code):
        if code < 0:
            raise RuntimeError(f"native operation failed: {code}")

    def prop(name):
        ptr = lib.mpv_get_property_string(ctx, name.encode())
        if not ptr:
            return None
        try:
            return ctypes.string_at(ptr).decode()
        finally:
            lib.mpv_free(ptr)

    def command(*parts):
        values = (ctypes.c_char_p * (len(parts) + 1))()
        for index, part in enumerate(parts):
            values[index] = part.encode()
        checked(lib.mpv_command(ctx, values))

    def load(path, expected):
        received.clear()
        command("loadfile", f"http://127.0.0.1:{first.server_port}{path}", "replace")
        deadline = time.monotonic() + 5
        while not any(entry[1] == expected for entry in received):
            if time.monotonic() >= deadline:
                raise RuntimeError("fixture endpoint did not receive native request")
            time.sleep(0.01)
        command("stop")
        return list(received)

    try:
        for key, value in {"vo": "null", "ao": "null", "idle": "yes", "terminal": "no"}.items():
            checked(lib.mpv_set_option_string(ctx, key.encode(), value.encode()))
        checked(lib.mpv_initialize(ctx))
        version = prop("mpv-version")
        ffmpeg = prop("ffmpeg-version")
        checked(lib.mpv_set_property_string(ctx, b"http-header-fields", b"Authorization: fixture-only,X-Fixture: synthetic"))
        redirected = load("/redirect", "/media")
        target = next(entry for entry in redirected if entry[0] == other.server_port)
        hops = load("/hop/0", "/hop/6")
        checked(lib.mpv_set_property_string(ctx, b"http-header-fields", b""))
        cleared = load("/empty", "/empty")
        raw = "/media%2fpart?x=1&x=2&empty=&api_key=fixture&q=a+b&q=a%20b&sig=%7e"
        raw_requests = load(raw, raw)
        print(json.dumps({
            "schema": "strm-native-probe/v1",
            "platform": "host-only",
            "binarySha256": hashlib.sha256(args.library.read_bytes()).hexdigest(),
            "mpvVersion": version,
            "ffmpegVersion": ffmpeg,
            "directNativeRawPathPreserved": raw_requests[0][1] == raw,
            "crossOriginCustomAuthorizationForwarded": "Authorization" in target[2],
            "sixRedirectsFollowed": len({entry[1] for entry in hops}) >= 7,
            "explicitEmptyHeaderResetObserved": "Authorization" not in cleared[0][2],
            "rangeReopenPolicy": "NOT_RUN",
            "subresources": "NOT_RUN",
            "cookieJarReset": "NOT_RUN",
            "mediaKitNormalization": "NOT_TESTED_BY_THIS_PROBE",
            "sourceDirectCapability": "UNSUPPORTED",
        }, indent=2))
    finally:
        lib.mpv_terminate_destroy(ctx)
        for server in (first, other):
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
