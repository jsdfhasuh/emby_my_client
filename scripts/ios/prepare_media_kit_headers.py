"""Prepare pinned upstream mpv headers before CocoaPods can swallow make errors.

Only upstream-generated files are written by the original Makefile. Package
sources, podspecs, dependency locks, and the binary XCFramework stay unchanged.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tarfile
import time
from urllib.parse import urljoin, urlparse
from urllib.request import url2pathname


PACKAGE = "media_kit_video"
PACKAGE_VERSION = "2.0.1"
MPV_VERSION = "v0.36.0"
ARCHIVE_SHA256 = "29abc44f8ebee013bb2f9fe14d80b30db19b534c679056e4851ceadf5a5e8bf6"
ARCHIVE_URL = f"https://github.com/mpv-player/mpv/archive/refs/tags/{MPV_VERSION}.tar.gz"
HEADERS = ("client.h", "render.h", "render_gl.h", "stream_cb.h")
MAX_ATTEMPTS = 3
ATTEMPT_TIMEOUT = 60


def package_root(config):
    config = config.resolve()
    packages = json.loads(config.read_text(encoding="utf-8"))["packages"]
    matches = [item for item in packages if item["name"] == PACKAGE]
    if len(matches) != 1:
        raise ValueError("Expected one locked media_kit_video package")
    uri = urlparse(urljoin(config.as_uri(), matches[0]["rootUri"]))
    if uri.scheme != "file" or uri.netloc not in ("", "localhost"):
        raise ValueError("Expected a local media_kit_video package")
    root = Path(url2pathname(uri.path)).resolve()
    pubspec = (root / "pubspec.yaml").read_text(encoding="utf-8")
    if not re.search(rf"^version:\s*{re.escape(PACKAGE_VERSION)}\s*$", pubspec, re.M):
        raise ValueError("media_kit_video differs from the fixed package version")
    makefile = (root / "common/darwin/Makefile").read_text(encoding="utf-8")
    for name, value in (("MPV_HEADERS_VERSION", MPV_VERSION),
                        ("MPV_HEADERS_SHA256SUM", ARCHIVE_SHA256)):
        if not re.search(rf"^{name}={re.escape(value)}\s*$", makefile, re.M):
            raise ValueError(f"Upstream {name} differs from the fixed value")
    return root


def verify_headers(root):
    archive = root / f"common/darwin/.cache/headers/mpv-{MPV_VERSION}.tar.gz"
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != ARCHIVE_SHA256:
        raise ValueError("mpv header archive checksum mismatch")
    hashes = {}
    with tarfile.open(archive, "r:gz") as source:
        for name in HEADERS:
            member = source.getmember(f"mpv-{MPV_VERSION[1:]}/libmpv/{name}")
            if not member.isfile():
                raise ValueError(f"mpv archive header is not a regular file: {name}")
            expected = source.extractfile(member).read()
            actual = (root / "ios/Headers/mpv" / name).read_bytes()
            if not expected or actual != expected:
                raise ValueError(f"Generated mpv header differs from verified archive: {name}")
            hashes[name] = hashlib.sha256(actual).hexdigest()
    return {"archiveSha256": digest, "headers": hashes}


def verify_pods(root, pods):
    result = verify_headers(root)
    public = pods / "Headers/Public/media_kit_video"
    umbrella = (pods / "Target Support Files/media_kit_video/media_kit_video-umbrella.h")
    contents = umbrella.read_text(encoding="utf-8")
    for name in HEADERS:
        if (public / name).read_bytes() != (root / "ios/Headers/mpv" / name).read_bytes():
            raise ValueError(f"CocoaPods public mpv header differs: {name}")
        if not re.search(rf'^#import\s+"{re.escape(name)}"\s*$', contents, re.M):
            raise ValueError(f"CocoaPods umbrella omits mpv header: {name}")
    result["podHeadersVerified"] = True
    return result


def run_make(root, log):
    command = ["make", "-C", str(root / "common/darwin"),
               f"HEADERS_DESTDIR={root / 'ios/Headers'}"]
    with log.open("xb") as output:
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=(os.name == "posix"))
        try:
            return process.wait(timeout=ATTEMPT_TIMEOUT)
        except subprocess.TimeoutExpired:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
            process.wait()
            return 124


def prepare(config, evidence, *, pods=None):
    # Evidence is never overwritten, including after an unsuccessful first run.
    evidence.mkdir(parents=True, exist_ok=False)
    receipt = {"package": PACKAGE, "packageVersion": PACKAGE_VERSION,
               "mpvVersion": MPV_VERSION, "url": ARCHIVE_URL,
               "expectedSha256": ARCHIVE_SHA256, "attempts": [], "status": "started"}

    def checkpoint():
        (evidence / "receipt.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")

    checkpoint()
    try:
        root = package_root(config)
        if pods is not None:
            receipt.update(verify_pods(root, pods))
        else:
            for number in range(1, MAX_ATTEMPTS + 1):
                attempt = {"attempt": number, "timeoutSeconds": ATTEMPT_TIMEOUT,
                           "log": f"attempt-{number}.log"}
                receipt["attempts"].append(attempt)
                checkpoint()
                started = time.monotonic()
                print(f"IOS_MPV_HEADERS_ATTEMPT={number}", flush=True)
                try:
                    attempt["exitCode"] = run_make(root, evidence / attempt["log"])
                finally:
                    attempt["elapsedSeconds"] = round(time.monotonic() - started, 3)
                    partial = root / "common/darwin/.cache/headers/mpv.tar.gz.tmp"
                    if partial.is_file():
                        copy = evidence / f"attempt-{number}-download.part"
                        shutil.copyfile(partial, copy)
                        attempt["partialBytes"] = copy.stat().st_size
                        attempt["partialSha256"] = hashlib.sha256(copy.read_bytes()).hexdigest()
                    checkpoint()
                if attempt["exitCode"] == 0:
                    # Even an apparently successful make must prove its outputs.
                    receipt.update(verify_headers(root))
                    attempt["headersVerified"] = True
                    break
                if number == MAX_ATTEMPTS:
                    raise RuntimeError("Pinned mpv header preparation failed after bounded attempts")
                time.sleep(number * 2)
        receipt["status"] = "verified"
        checkpoint()
        print("IOS_MPV_HEADERS_VERIFIED", flush=True)
        return receipt
    except Exception as error:
        receipt.update(status="failed", error=str(error), errorType=type(error).__name__)
        checkpoint()
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-config", type=Path, default=Path(".dart_tool/package_config.json"))
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--verify-pods", type=Path)
    args = parser.parse_args()
    prepare(args.package_config, args.evidence, pods=args.verify_pods)


if __name__ == "__main__":
    main()
