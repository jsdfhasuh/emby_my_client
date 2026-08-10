#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: run_mpv_startability_probe.sh app-x86_64-debug.apk" >&2
  exit 64
fi

apk_path="$1"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ ! -f "$apk_path" ]]; then
  echo "Missing APK: $apk_path" >&2
  exit 66
fi
if ! command -v adb >/dev/null 2>&1; then
  echo "Missing required command: adb" >&2
  exit 69
fi
if [[ -z "${ANDROID_NDK_HOME:-}" || ! -d "$ANDROID_NDK_HOME" ]]; then
  echo "ANDROID_NDK_HOME must point to the fixed Flutter NDK" >&2
  exit 69
fi

host_tag='linux-x86_64'
toolchain="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host_tag"
compiler="$toolchain/bin/x86_64-linux-android23-clang"
if [[ ! -x "$compiler" ]]; then
  echo "Missing Android x86_64 compiler: $compiler" >&2
  exit 69
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/emby-android-mpv-start.XXXXXX")"
remote_dir='/data/local/tmp/emby-mpv-startability'
cleanup() {
  adb shell rm -rf "$remote_dir" >/dev/null 2>&1 || true
  rm -rf "$temp_dir"
}
trap cleanup EXIT

native_dir="$temp_dir/native"
mkdir -p "$native_dir"
mapfile -t libraries < <(
  unzip -Z1 "$apk_path" | awk '/^lib\/x86_64\/[^/]+\.so$/ { print }'
)
if (( ${#libraries[@]} == 0 )); then
  echo "No x86_64 native libraries found: $apk_path" >&2
  exit 65
fi
for entry in "${libraries[@]}"; do
  unzip -p "$apk_path" "$entry" >"$native_dir/$(basename "$entry")"
done
if [[ ! -s "$native_dir/libmpv.so" ]]; then
  echo "Packaged x86_64 libmpv.so is missing" >&2
  exit 65
fi

"$compiler" \
  "$root_dir/scripts/android/mpv_startability_probe.c" \
  -L"$native_dir" -lmpv \
  -Wl,--allow-shlib-undefined "-Wl,-rpath,\$ORIGIN" \
  -o "$native_dir/mpv_startability_probe"

adb shell rm -rf "$remote_dir"
adb shell mkdir -p "$remote_dir"
adb push "$native_dir/." "$remote_dir/" >/dev/null
adb shell chmod 0700 "$remote_dir/mpv_startability_probe"
adb shell "cd '$remote_dir' && LD_LIBRARY_PATH=. ./mpv_startability_probe"
