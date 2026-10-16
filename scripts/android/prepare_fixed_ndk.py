"""Install the pinned Linux NDK before Gradle, preserving any first failure."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

VERSION = "28.2.13676358"
ROOT = "android-ndk-r28c"
URL = "https://dl.google.com/android/repository/android-ndk-r28c-linux.zip"
SIZE = 722261334
SHA1 = "a7b54a5de87fecd125a17d54f73c446199e72a64"
# Published by the Android NDK project, not learned from the download response.
SOURCE = "https://github.com/android/ndk/wiki/Unsupported-Downloads"


def validate_install(root):
    properties = dict(
        line.split("=", 1) for line in
        (root / "source.properties").read_text().splitlines() if "=" in line
    )
    properties = {key.strip(): value.strip() for key, value in properties.items()}
    if properties.get("Pkg.Revision") != VERSION:
        raise ValueError("Installed NDK revision differs from the fixed version")
    toolchain = root / "toolchains/llvm/prebuilt/linux-x86_64"
    clang = toolchain / "bin/clang"
    for path in (root / "build/cmake/android.toolchain.cmake",
                 toolchain / "sysroot/usr/include/android/api-level.h"):
        if not path.is_file():
            raise ValueError("Installed NDK toolchain is incomplete")
    if not os.access(clang, os.X_OK):
        raise ValueError("Installed NDK compiler is not executable")
    result = subprocess.run([str(clang), "--version"], check=True,
                            capture_output=True, text=True, timeout=30)
    return {"revision": VERSION, "clangVersion": result.stdout.strip(),
            "clangExecutable": True, "toolchainPresent": True}


def download(archive, receipt):
    try:
        response = urllib.request.urlopen(URL, timeout=30)
    except urllib.error.HTTPError as error:
        response = error  # Preserve the actual failure body as well as status.
    digest = hashlib.sha1()
    size = 0
    started = time.monotonic()
    with response, archive.open("xb") as output:
        receipt["httpStatus"] = response.status
        try:
            while block := response.read(1024 * 1024):
                output.write(block)
                digest.update(block)
                size += len(block)
                if size > SIZE or time.monotonic() - started > 900:
                    raise ValueError("NDK response exceeded the fixed size/time bound")
        finally:
            receipt.update(receivedBytes=size, receivedSha1=digest.hexdigest())
    if receipt["httpStatus"] != 200:
        raise ValueError("NDK download did not return HTTP 200")
    if size != SIZE or digest.hexdigest() != SHA1:
        raise ValueError("NDK archive size or official checksum mismatch")
    receipt["archiveVerified"] = True


def install(sdk, evidence):
    # Refuse reuse rather than overwrite a previous attempt or its evidence.
    evidence.mkdir(parents=True, exist_ok=False)
    archive = evidence / "download.part"
    receipt = {"version": VERSION, "url": URL, "checksumSource": SOURCE,
               "expectedBytes": SIZE, "expectedSha1": SHA1,
               "downloadAttempts": 0, "archiveVerified": False}
    destination = sdk / "ndk" / VERSION

    def checkpoint(phase):
        receipt["phase"] = phase
        (evidence / "receipt.json").write_text(json.dumps(receipt, indent=2))
        print(f"ANDROID_FIXED_NDK_STAGE phase={phase}", flush=True)

    try:
        if destination.exists():
            checkpoint("validate_existing")
            receipt.update(validate_install(destination))
            receipt["status"] = "existing_install_verified"
        else:
            receipt["downloadAttempts"] = 1
            checkpoint("download")
            download(archive, receipt)
            checkpoint("verify_archive_layout")
            with zipfile.ZipFile(archive) as zipped:
                for entry in zipped.infolist():
                    path = PurePosixPath(entry.filename)
                    if (path.is_absolute() or ".." in path.parts or
                            "\\" in entry.filename or not path.parts or
                            path.parts[0] != ROOT):
                        raise ValueError("NDK archive has an unexpected path")
            destination.parent.mkdir(parents=True, exist_ok=True)
            # unzip retains the official Linux executable bits and symlinks;
            # zipfile.extractall does not. The archive was authenticated above.
            with tempfile.TemporaryDirectory(prefix=".ndk-prepare-",
                                             dir=destination.parent) as staging:
                checkpoint("extract")
                with (evidence / "unzip.log").open("wb") as log:
                    subprocess.run(["unzip", "-q", str(archive.resolve()),
                                    "-d", staging], check=True, stdout=log,
                                   stderr=subprocess.STDOUT, timeout=300)
                prepared = Path(staging) / ROOT
                checkpoint("validate_prepared")
                receipt.update(validate_install(prepared))
                checkpoint("promote")
                prepared.rename(destination)
            receipt["status"] = "installed_verified"
            # Successful archive bytes need not become a 722 MB CI artifact.
            # Any failure keeps its original partial/complete response intact.
            archive.unlink()
        checkpoint("complete")
        print(f"ANDROID_FIXED_NDK_READY version={VERSION}")
    except Exception as error:
        receipt.update(status="failed", errorType=type(error).__name__)
        raise
    finally:
        (evidence / "receipt.json").write_text(json.dumps(receipt, indent=2))
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-root", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    configured = os.environ.get("ANDROID_NDK_VERSION", VERSION)
    if configured != VERSION:
        parser.error("ANDROID_NDK_VERSION must match the pinned installer")
    install(args.sdk_root.resolve(), args.evidence.resolve())


if __name__ == "__main__":
    main()
