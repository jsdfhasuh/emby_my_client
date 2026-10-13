"""One public build identity for all packages; leave room for Flutter ABI offsets."""
import argparse


def build_version(run_number: int) -> dict[str, str]:
    # Android codes must stay below 2,100,000,000, including ABI offsets.
    if not 1 <= run_number <= 209999:
        raise ValueError("Run number outside the supported Android version range")
    return {
        "APP_VERSION_NAME": f"1.0.{run_number}",
        "ANDROID_VERSION_CODE": str(run_number * 10000),
        "IOS_BUILD_NUMBER": str(run_number),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-number", type=int, required=True)
    args = parser.parse_args()
    for key, value in build_version(args.run_number).items():
        print(f"{key}={value}")
