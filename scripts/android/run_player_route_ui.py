"""Run generated-media production PlayerScreen UI on a dedicated emulator.

This is route/control evidence. The separate packaged-library and texture pixel
gates are still required. Never publish the supplied test-target APK.
"""
import argparse
import http.server
import json
import pathlib
import subprocess
import threading

CYCLE_STAGES = ("opened", "pgs-a", "pgs-b", "pgs-a2", "ass-visible", "srt-visible", "off", "closed")
STAGES = (tuple(f"{cycle}-{stage}" for cycle in range(2) for stage in CYCLE_STAGES) +
          ("download-list",) +
          tuple(f"offline-{cycle}-{stage}" for cycle in range(2) for stage in CYCLE_STAGES) +
          ("download-closed",))
CLEANUP = {"routesClosed", "downloadsClosed", "apiDisposed", "serverClosed", "settingsDisposed", "subtitlePreferencesDisposed",
           "temporaryFilesRemoved"}


class RouteProtocol:
    def __init__(self):
        self.count = 0
        self.first_failure = None
        self.terminal = False
        self.complete = False

    def accept(self, value):
        try:
            self._accept(value)
        except Exception as error:
            if self.first_failure is None:
                self.first_failure = str(error)
            raise

    def _accept(self, value):
        if self.terminal:
            raise ValueError("record after terminal")
        if not isinstance(value, dict):
            raise ValueError("stage is not an object")
        stage = value.get("stage")
        if stage in ("complete", "failed"):
            self.terminal = True
            if stage != "complete":
                raise ValueError("harness failure: " + str(value.get("error")))
            expected = {"schema": "emby-android-player-route/v1",
                        "platform": "android", "scope": "production-player-route",
                        "productionPlayerScreen": True, "nativeBackend": True,
                        "physicalPhone": "NOT_RUN", "nativePixelGate": "SEPARATE_REQUIRED"}
            if any(type(value.get(key)) is not type(item) or value.get(key) != item
                   for key, item in expected.items()):
                raise ValueError("wrong route evidence identity/scope")
            cleanup = value.get("cleanup")
            if not isinstance(cleanup, dict) or set(cleanup) != CLEANUP or not all(
                    item is True for item in cleanup.values()):
                raise ValueError("route cleanup incomplete")
            if (self.first_failure or self.count != len(STAGES) or
                    type(value.get("verifiedStages")) is not int or value["verifiedStages"] != len(STAGES)):
                raise ValueError("first failure or missing UI stages")
            self.complete = True
            return
        if self.first_failure or self.count >= len(STAGES) or stage != STAGES[self.count]:
            raise ValueError("wrong or duplicate UI stage")
        if value.get("productionPlayerScreen") is not True or value.get("nativeBackend") is not True:
            raise ValueError("not the production native route")
        offline = stage.startswith(("download-", "offline-"))
        player_shown = stage != "download-list" and not stage.endswith("closed")
        downloads_shown = stage == "download-list" or (stage.startswith("offline-") and stage.endswith("closed"))
        if value.get("routeShown") is not player_shown:
            raise ValueError("route presence mismatch")
        if value.get("downloadListShown") is not downloads_shown:
            raise ValueError("download list presence mismatch")
        if value.get("entryPoint") != ("downloads" if offline else "direct-http"):
            raise ValueError("wrong playback entry point")
        if value.get("offlineItem") is not (offline and player_shown):
            raise ValueError("wrong offline route arguments")
        if offline:
            if type(value.get("networkAttempts")) is not int or value["networkAttempts"] != 0:
                raise ValueError("offline route attempted network")
            if value.get("offlineFileExists") is not True or value.get("sidecarFileExists") is not True:
                raise ValueError("offline fixture file unavailable")
            if player_shown and value.get("localPlaybackPathMatches") is not True:
                raise ValueError("offline route did not open the downloaded file")
        cue = ("TEXT_CUE" if stage.endswith("ass-visible") else
               "EXTERNAL_CUE" if stage.endswith("srt-visible") else None)
        if value.get("cue") != cue:
            raise ValueError("wrong UI cue")
        self.count += 1

    def finish(self):
        if self.first_failure or not self.complete:
            raise ValueError("no clean route completion: " + str(self.first_failure))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--apk", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if not args.serial.startswith("emulator-"):
        parser.error("Use only a dedicated disposable emulator")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    fixture = (pathlib.Path(__file__).resolve().parents[2] /
               "test/fixtures/subtitles/synthetic-pgs.mkv").read_bytes()
    adb = ["adb", "-s", args.serial]
    protocol, records = RouteProtocol(), []
    finished, lock = threading.Event(), threading.Lock()

    def run(*arguments, **kwargs):
        return subprocess.run(adb + list(arguments), check=True, **kwargs)

    def persist():
        (output / "results.json").write_text(json.dumps(records, indent=2), encoding="utf-8")
        failure = output / "first-failure.json"
        if protocol.first_failure and not failure.exists():
            failure.write_text(json.dumps({"error": protocol.first_failure,
                                           "verifiedStages": protocol.count}), encoding="utf-8")

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path != "/synthetic-pgs.mkv":
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(fixture)))
            self.end_headers()
            self.wfile.write(fixture)

        def read_body(self):
            if self.headers.get("Transfer-Encoding") == "chunked":
                chunks = []
                while True:
                    size = int(self.rfile.readline().strip().split(b";")[0], 16)
                    if not size:
                        self.rfile.readline()
                        break
                    chunks.append(self.rfile.read(size))
                    if self.rfile.read(2) != b"\r\n":
                        raise ValueError("invalid chunk terminator")
                return b"".join(chunks)
            return self.rfile.read(int(self.headers["Content-Length"]))

        def diagnostic(self):
            # A failure snapshot is collected before the app closes its route.
            # It never changes the accepted stage count or marks completion.
            with lock:
                status = 200
                try:
                    value = json.loads(self.read_body())
                    if value.get("scope") != "diagnostic-not-acceptance":
                        raise ValueError("wrong diagnostic scope")
                    png = run("exec-out", "screencap", "-p", capture_output=True).stdout
                    if not png.startswith(b"\x89PNG\r\n\x1a\n"):
                        raise ValueError("missing diagnostic screenshot")
                    index = len(list(output.glob("diagnostic-*.json")))
                    (output / f"diagnostic-{index:02d}.png").write_bytes(png)
                    (output / f"diagnostic-{index:02d}.json").write_text(
                        json.dumps(value, indent=2, ensure_ascii=False), encoding="utf-8")
                except Exception as error:
                    # Do not replace the actual harness failure with capture trouble.
                    (output / "diagnostic-capture-error.txt").write_text(str(error), encoding="utf-8")
                    status = 500
                self.send_response(status)
                self.send_header("Content-Length", "0")
                self.end_headers()

        def do_POST(self):
            if self.path == "/diagnostic":
                self.diagnostic()
                return
            if self.path != "/stage":
                self.send_error(404)
                return
            with lock:
                record, status = {}, 200
                try:
                    body = self.read_body()
                    record = json.loads(body)
                    terminal = isinstance(record, dict) and record.get("stage") in ("complete", "failed")
                    if not terminal:
                        png = run("exec-out", "screencap", "-p", capture_output=True).stdout
                        if not png.startswith(b"\x89PNG\r\n\x1a\n"):
                            raise ValueError("missing Android screenshot")
                        (output / f"ui-{len(records):02d}.png").write_bytes(png)
                    protocol.accept(record)
                except Exception as error:
                    protocol.first_failure = protocol.first_failure or str(error)
                    if not isinstance(record, dict):
                        record = {"record": record}
                    record["failure"] = str(error)
                    status = 500
                records.append(record)
                persist()
                self.send_response(status)
                self.send_header("Content-Length", "0")
                self.end_headers()
                if record.get("stage") in ("complete", "failed"):
                    finished.set()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 38766), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        run("reverse", "tcp:38766", "tcp:38766")
        run("install", "-r", str(args.apk.resolve()))
        run("shell", "am", "force-stop", "com.jsdfhasuh.emoemby")
        component = run("shell", "cmd", "package", "resolve-activity", "--brief",
                        "com.jsdfhasuh.emoemby", capture_output=True, text=True).stdout.strip().splitlines()[-1]
        if not component.startswith("com.jsdfhasuh.emoemby/"):
            raise ValueError("Unexpected launcher component")
        run("shell", "am", "start", "-n", component)
        if not finished.wait(max(240, len(STAGES) * 20)):
            raise RuntimeError("Production route harness did not finish cleanup")
        protocol.finish()
        print(f"ANDROID_PRODUCTION_PLAYER_ROUTE=PASSED stages={len(STAGES)} nativePixelGate=SEPARATE_REQUIRED")
    except Exception as error:
        protocol.first_failure = protocol.first_failure or str(error)
        persist()
        raise
    finally:
        server.shutdown()
        server.server_close()
        run("reverse", "--remove", "tcp:38766")


if __name__ == "__main__":
    main()
