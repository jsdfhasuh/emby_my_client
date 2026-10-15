"""Verify actual APK native bytes against the audited Android artifact lock."""
import argparse
import hashlib
import json
import zipfile
from pathlib import Path


def verify(apk, expected):
    with zipfile.ZipFile(apk) as archive:
        natives = [name for name in archive.namelist()
                   if name.endswith(("/libmpv.so", "/libmediakitandroidhelper.so"))]
        if not natives or len(natives) != len(set(natives)):
            raise ValueError("Missing or duplicate media-kit native libraries")
        for abi in {name.split('/')[1] for name in natives}:
            for library in ['libmpv.so', 'libmediakitandroidhelper.so']:
                if f'lib/{abi}/{library}' not in natives:
                    raise ValueError(f"Missing paired native library: {abi}/{library}")
        for name in natives:
            actual = hashlib.sha256(archive.read(name)).hexdigest()
            if expected.get(name) != actual:
                raise ValueError(f"Native provenance mismatch: {name}")
    return len(natives)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apks", nargs="+", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    lock = json.loads((root / "android/media_kit_libs_android_video/artifacts.json").read_text())
    expected = {name: digest for artifact in lock["artifacts"].values()
                for name, digest in artifact["libraries"].items()}
    for apk in args.apks:
        count = verify(apk, expected)
        print(f"android_native_provenance=PASSED apk={apk.name} libraries={count}")


if __name__ == '__main__':
    main()
