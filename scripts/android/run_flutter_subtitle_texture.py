"""Screenshot test for a dedicated Android emulator. Requires Pillow 11.3.0.

Build test/support/android_bitmap_harness.dart explicitly before running.
Never install the harness APK on a user device or publish it as the app.
"""
import argparse
import http.server
import io
import json
import pathlib
import subprocess
import threading

from PIL import Image
from subtitle_texture_protocol import TextureProtocol


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--apk", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if not args.serial.startswith("emulator-"):
        parser.error("Use a dedicated disposable emulator, never a physical phone")
    root = pathlib.Path(__file__).resolve().parents[2]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    adb = ["adb", "-s", args.serial]
    fixture = (root / "test/fixtures/subtitles/synthetic-pgs.mkv").read_bytes()
    masks = {name: (root / ("test/fixtures/subtitles/expected-PGS-" +
                           name.upper() + ".mask")).read_bytes()
             for name in ("alpha", "beta")}
    protocol = TextureProtocol(masks)
    results = []
    finished = threading.Event()
    stage_lock = threading.Lock()

    def run(*arguments, **kwargs):
        return subprocess.run(adb + list(arguments), check=True, **kwargs)

    def persist():
        (out / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
        if protocol.first_failure is not None:
            failure = out / "first-failure.json"
            if not failure.exists():
                failure.write_text(json.dumps({"error": protocol.first_failure,
                                                "verifiedFrames": protocol.frames}),
                                   encoding="utf-8")

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path != "/synthetic-pgs.mkv":
                self.send_error(404)
                return
            start, end, status = 0, len(fixture) - 1, 200
            header = self.headers.get("Range")
            if header:
                lo, hi = header.removeprefix("bytes=").split("-")
                start, end, status = int(lo), min(int(hi) if hi else end, end), 206
            if start < 0 or start > end:
                self.send_error(416)
                return
            self.send_response(status)
            self.send_header("Content-Type", "video/x-matroska")
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Accept-Ranges", "bytes")
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(fixture)}")
            self.end_headers()
            try:
                self.wfile.write(fixture[start:end + 1])
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_POST(self):
            if self.path != "/stage":
                self.send_error(404)
                return
            with stage_lock:
                value, status, terminal = {}, 200, False
                try:
                    if self.headers.get("Transfer-Encoding") == "chunked":
                        chunks = []
                        while True:
                            size = int(self.rfile.readline().strip().split(b";")[0], 16)
                            if size == 0:
                                self.rfile.readline()
                                break
                            chunks.append(self.rfile.read(size))
                            if self.rfile.read(2) != b"\r\n":
                                raise ValueError("invalid chunk terminator")
                        body = b"".join(chunks)
                    else:
                        body = self.rfile.read(int(self.headers["Content-Length"]))
                    value = json.loads(body)
                    terminal = isinstance(value, dict) and value.get("stage") in ("complete", "failed")
                    frame = None
                    if not terminal:
                        png = run("exec-out", "screencap", "-p", capture_output=True).stdout
                        # Never use the untrusted reported stage as a file path.
                        (out / f"capture-{len(results):02d}.png").write_bytes(png)
                        frame = Image.open(io.BytesIO(png))
                    protocol.accept(value, frame)
                    if not terminal:
                        value["screenshotPixels"] = "PASSED"
                except Exception as error:
                    protocol.reject(error)
                    if not isinstance(value, dict):
                        value = {"record": value}
                    value["failure"] = str(error)
                    status = 500
                results.append(value)
                persist()
                print(json.dumps({key: item for key, item in value.items()
                                  if key != "nativeLogs"}), flush=True)
                self.send_response(status)
                self.send_header("Content-Length", "0")
                self.end_headers()
                # On a pixel failure keep serving until the harness acknowledges
                # disposal, so an unfinished cleanup cannot be reported as success.
                if terminal:
                    finished.set()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 38765), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        run("reverse", "tcp:38765", "tcp:38765")
        run("shell", "wm", "size", "640x360")
        run("shell", "wm", "density", "160")
        run("shell", "settings", "put", "secure", "immersive_mode_confirmations", "confirmed")
        run("install", "-r", str(args.apk.resolve()))
        run("shell", "am", "force-stop", "com.jsdfhasuh.emoemby")
        component = run("shell", "cmd", "package", "resolve-activity", "--brief",
                        "com.jsdfhasuh.emoemby", capture_output=True,
                        text=True).stdout.strip().splitlines()[-1]
        if not component.startswith("com.jsdfhasuh.emoemby/"):
            raise RuntimeError("Unexpected launcher component")
        run("shell", "am", "start", "-n", component)
        if not finished.wait(180):
            raise RuntimeError("Harness did not report completed cleanup")
        protocol.finish()
        print("ANDROID_FLUTTER_TEXTURE_SCREENSHOTS=PASSED frames=32 cleanup=PASSED")
    except Exception as error:
        protocol.reject(error)
        persist()
        raise
    finally:
        server.shutdown()
        server.server_close()
        run("reverse", "--remove", "tcp:38765")


if __name__ == "__main__":
    main()
