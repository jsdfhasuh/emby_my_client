#!/usr/bin/env python3
"""Sign tested APKs with the owner's fixed key; never publish a random debug signer."""
import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from build_version import build_version
from prepare_release import (ANDROID_APPLICATION_ID, ANDROID_LABEL, APK_NAMES,
                             SIGNING_RECEIPT, certificate_pin)

KEYSTORE_SECRET = "ANDROID_SIGNING_KEYSTORE_BASE64"
PASSWORD_SECRET = "ANDROID_SIGNING_PASSWORD"
KEY_ALIAS = "emo-emby-release"


class SigningError(Exception):
    """Only fixed, non-sensitive messages may leave the signing process."""


def credentials(environment: dict[str, str]) -> tuple[bytes, str]:
    for name in (KEYSTORE_SECRET, PASSWORD_SECRET):
        if not environment.get(name):
            raise SigningError(f"Missing required GitHub Secret: {name}")
    encoded = environment[KEYSTORE_SECRET]
    password = environment[PASSWORD_SECRET]
    if len(encoded) > 1024 * 1024 or len(password) < 12 or "\x00" in password:
        raise SigningError("Invalid Android signing configuration")
    try:
        keystore = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise SigningError("Invalid Android keystore encoding") from None
    if not keystore:
        raise SigningError("Empty Android keystore")
    return keystore, password


def run_tool(command: list[str], environment: dict[str, str]) -> str:
    try:
        result = subprocess.run(command, env=environment, capture_output=True,
                                text=True, encoding="utf-8", errors="replace", timeout=180, check=False)
    except (OSError, subprocess.SubprocessError):
        raise SigningError("Android signing tool could not complete") from None
    if result.returncode:
        # Tool diagnostics may include unexpected environment/path contents.
        # Never echo them or the supplied secrets, even in failure paths.
        raise SigningError("Android signing/verification failed; check the configured key and password")
    return result.stdout


def verify_certificate(apksigner: Path, apk: Path, expected: str,
                       environment: dict[str, str]) -> None:
    output = run_tool([str(apksigner), "verify", "--verbose", "--print-certs", str(apk)], environment)
    certificates = re.findall(r"^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]{64})$",
                              output, flags=re.MULTILINE)
    if [value.lower() for value in certificates] != [expected]:
        raise SigningError("APK signer does not match the pinned Android certificate")


def verify_package(aapt: Path, apk: Path, name: str, run_number: int,
                   environment: dict[str, str]) -> None:
    versions = build_version(run_number)
    offsets = {"app-debug.apk": 0, "app-armeabi-v7a-debug.apk": 1000,
               "app-arm64-v8a-debug.apk": 2000, "app-x86_64-debug.apk": 4000}
    architectures = {"app-debug.apk": {"armeabi-v7a", "arm64-v8a", "x86_64"},
                     "app-armeabi-v7a-debug.apk": {"armeabi-v7a"},
                     "app-arm64-v8a-debug.apk": {"arm64-v8a"},
                     "app-x86_64-debug.apk": {"x86_64"}}
    output = run_tool([str(aapt), "dump", "badging", str(apk)], environment)
    package = re.search(r"^package: (.+)$", output, re.MULTILINE)
    label = re.search(r"^application-label:'([^']*)'$", output, re.MULTILINE)
    native = re.search(r"^native-code:(.*)$", output, re.MULTILINE)
    if package is None or label is None or native is None:
        raise SigningError("Signed APK metadata is incomplete")
    fields = dict(re.findall(r"(\w+)='([^']*)'", package[1]))
    expected_code = int(versions["ANDROID_VERSION_CODE"]) + offsets[name]
    if (fields.get("name") != ANDROID_APPLICATION_ID or label[1] != ANDROID_LABEL or
        fields.get("versionName") != versions["APP_VERSION_NAME"] or
        fields.get("versionCode") != str(expected_code) or
        set(re.findall(r"'([^']+)'", native[1])) != architectures[name]):
        raise SigningError("Signed APK package, label, version or ABI violates the stable-app contract")


def sign_release(artifacts_dir: Path, output_dir: Path, apksigner: Path,
                 expected: str, environment: dict[str, str], temporary_root: Path,
                 *, aapt: Path, run_number: int) -> None:
    keystore, password = credentials(environment)
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise SigningError("Invalid pinned Android certificate")
    build_version(run_number)
    if not apksigner.is_file() or not aapt.is_file() or not artifacts_dir.is_dir() or not temporary_root.is_dir():
        raise SigningError("Android signing inputs or tools are unavailable")
    if output_dir.exists():
        raise SigningError("Signed output already exists; refusing overwrite")
    inputs = {}
    for name in APK_NAMES:
        matches = [path for path in artifacts_dir.rglob(name) if path.is_file() and not path.is_symlink()]
        if len(matches) != 1 or not matches[0].stat().st_size:
            raise SigningError(f"Expected exactly one tested APK: {name}")
        inputs[name] = matches[0]

    # Secrets are scoped to this trusted release step. The base64 key is not
    # inherited by apksigner; its password is supplied only via env:, never argv.
    child_environment = {key: value for key, value in environment.items()
                         if key not in (KEYSTORE_SECRET, PASSWORD_SECRET)}
    with tempfile.TemporaryDirectory(prefix="emo-signing-", dir=temporary_root) as scratch:
        directory = Path(scratch)
        store = directory / "signing.p12"
        with store.open("xb") as stream:
            if os.name != "nt":
                os.chmod(store, 0o600)
            stream.write(keystore)
        keystore = b""
        signed = directory / "signed"
        signed.mkdir()
        hashes = {}
        for name, source in inputs.items():
            target = signed / name
            signing_environment = dict(child_environment, **{PASSWORD_SECRET: password})
            run_tool([str(apksigner), "sign", "--ks", str(store), "--ks-type", "PKCS12",
                      "--ks-key-alias", KEY_ALIAS, "--ks-pass", f"env:{PASSWORD_SECRET}",
                      "--key-pass", f"env:{PASSWORD_SECRET}", "--out", str(target), str(source)],
                     signing_environment)
            signing_environment.clear()
            verify_certificate(apksigner, target, expected, child_environment)
            verify_package(aapt, target, name, run_number, child_environment)
            digest = hashlib.sha256()
            with target.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            hashes[name] = digest.hexdigest()
        (signed / SIGNING_RECEIPT).write_text(json.dumps({
            "format": 2, "certificateSha256": expected, "apks": hashes,
            "applicationId": ANDROID_APPLICATION_ID, "runNumber": run_number,
        }, sort_keys=True) + "\n", encoding="utf-8")
        output_dir.parent.mkdir(parents=True, exist_ok=True)
        # Publication can only see output after every APK passes verification.
        shutil.copytree(signed, output_dir)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--apksigner", type=Path, required=True)
    parser.add_argument("--aapt", type=Path, required=True)
    parser.add_argument("--run-number", type=int, required=True)
    args = parser.parse_args()
    if (os.environ.get("GITHUB_REPOSITORY") != "jsdfhasuh/emby_my_client" or
        os.environ.get("GITHUB_REF") != "refs/heads/main" or
        os.environ.get("GITHUB_EVENT_NAME") not in ("push", "workflow_dispatch")):
        raise SigningError("Signing is restricted to trusted main release runs")
    temporary = os.environ.get("RUNNER_TEMP")
    if not temporary:
        raise SigningError("Runner temporary directory is unavailable")
    sign_release(**vars(args), expected=certificate_pin(), environment=dict(os.environ),
                 temporary_root=Path(temporary))
    print("All four Android APKs verified with the pinned signing certificate.")


if __name__ == "__main__":
    try:
        main()
    except SigningError as error:
        raise SystemExit(f"Android release blocked: {error}") from None
    except Exception:
        raise SystemExit("Android release blocked: signing could not complete") from None
