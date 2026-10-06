#!/usr/bin/env python3
"""Collect verified installable build artifacts for a GitHub Release."""

import argparse
import hashlib
from pathlib import Path
import re
import shutil


APK_NAMES = (
    "app-debug.apk",
    "app-arm64-v8a-debug.apk",
    "app-armeabi-v7a-debug.apk",
    "app-x86_64-debug.apk",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def prepare_release(
    artifacts_dir: Path,
    output_dir: Path,
    notes_path: Path,
    run_number: int,
    commit: str,
    run_url: str,
) -> list[Path]:
    if run_number <= 0 or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("A positive build number and full commit SHA are required")
    if not artifacts_dir.is_dir():
        raise FileNotFoundError(f"Artifact directory is missing: {artifacts_dir}")
    if output_dir.exists() and any(output_dir.iterdir()):
        raise FileExistsError(f"Release output must be empty: {output_dir}")

    def find_asset(name: str) -> Path:
        matches = [path for path in artifacts_dir.rglob(name) if path.is_file()]
        if len(matches) != 1 or matches[0].stat().st_size == 0:
            raise ValueError(f"Expected exactly one non-empty artifact: {name}")
        return matches[0]

    ipa_name = f"emby-ios-core-{commit[:12]}-{run_number}.ipa"
    binaries = [find_asset(name) for name in (*APK_NAMES, ipa_name)]
    ipa_checksum = find_asset(f"{ipa_name}.sha256")
    record = re.fullmatch(
        rf"([0-9a-fA-F]{{64}}) [ *]{re.escape(ipa_name)}",
        ipa_checksum.read_text(encoding="utf-8").strip(),
    )
    digests = {path.name: sha256(path) for path in binaries}
    if record is None or record[1].lower() != digests[ipa_name]:
        raise ValueError("IPA checksum does not match the selected build")

    output_dir.mkdir(parents=True, exist_ok=True)
    assets = []
    for source in (*binaries, ipa_checksum):
        target = output_dir / source.name
        shutil.copyfile(source, target)
        assets.append(target)
    manifest = output_dir / "SHA256SUMS.txt"
    manifest.write_text(
        "".join(f"{digests[name]}  {name}\n" for name in sorted(digests)),
        encoding="utf-8",
    )
    assets.append(manifest)
    notes_path.parent.mkdir(parents=True, exist_ok=True)
    notes_path.write_text(
        f"Automated main build **#{run_number}**.\n\n"
        f"Commit: `{commit}`\n\n"
        f"[Build and test results]({run_url})\n\n"
        "## Downloads\n"
        "- `app-debug.apk`: universal Android APK (debug-signed).\n"
        "- `app-*-debug.apk`: smaller Android APKs for each CPU architecture.\n"
        "- `emby-ios-core-*.ipa`: iPadOS IPA for TrollStore; not an App Store package.\n"
        "- `SHA256SUMS.txt`: SHA-256 checksums for all installable packages.\n\n"
        "Both platform builds and the existing automated checks passed. "
        "This is an automated test build, not a claim of real-device acceptance.\n",
        encoding="utf-8",
    )
    return assets


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--notes-path", type=Path, required=True)
    parser.add_argument("--run-number", type=int, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--run-url", required=True)
    args = parser.parse_args()
    for asset in prepare_release(**vars(args)):
        print(asset)


if __name__ == "__main__":
    main()
