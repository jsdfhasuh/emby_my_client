#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo 'Usage: run_subtitle_render_probe.sh app-x86_64-debug.apk' >&2
  exit 64
fi
apk_path="$1"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output="$root_dir/build/android/artifacts/subtitle-render"
mkdir -p "$output"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/emby-subtitle-render.XXXXXX")"
remote_dir="/data/local/tmp/emby-subtitle-render-$$"
case "$remote_dir" in /data/local/tmp/emby-subtitle-render-[0-9]*) ;; *) exit 65 ;; esac
server_pid=''
port=''
cleanup() {
  adb pull "$remote_dir/frames" "$output/" >/dev/null 2>&1 || true
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  if [[ -n "$port" ]]; then adb reverse --remove "tcp:$port" >/dev/null 2>&1 || true; fi
  adb shell rm -rf "$remote_dir" >/dev/null 2>&1 || true
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT
native_dir="$temp_dir/native"
mkdir -p "$native_dir"
mapfile -t libraries < <(unzip -Z1 "$apk_path" | awk '/^lib\/x86_64\/[^/]+\.so$/ {print}')
test "${#libraries[@]}" -gt 0
for entry in "${libraries[@]}"; do
  unzip -p "$apk_path" "$entry" > "$native_dir/$(basename "$entry")"
done
compiler="${ANDROID_NDK_HOME:?}/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android23-clang"
# ORIGIN is expanded by the Android dynamic loader, not this shell.
# shellcheck disable=SC2016
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
  "$root_dir/scripts/android/subtitle_render_probe.c" \
  -L"$native_dir" -lmpv -ldl -Wl,--allow-shlib-undefined '-Wl,-rpath,$ORIGIN' \
  -o "$native_dir/subtitle_render_probe"
cp "$root_dir"/test/fixtures/subtitles/{synthetic-pgs.mkv,external.srt,expected-PGS-ALPHA.mask,expected-PGS-BETA.mask} "$native_dir/"
python3 "$root_dir/scripts/android/subtitle_fixture_server.py" \
  "$native_dir/synthetic-pgs.mkv" "$temp_dir/port" >"$output/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  [[ -s "$temp_dir/port" ]] && break
  kill -0 "$server_pid"
  sleep 0.1
done
port="$(cat "$temp_dir/port")"
[[ "$port" =~ ^[0-9]+$ ]]
adb reverse "tcp:$port" "tcp:$port" >/dev/null
adb shell mkdir -p "$remote_dir/frames"
adb push "$native_dir/." "$remote_dir/" >/dev/null
adb shell chmod 0700 "$remote_dir/subtitle_render_probe"
adb shell "cd '$remote_dir' && LD_LIBRARY_PATH=. ./subtitle_render_probe synthetic-pgs.mkv 'http://127.0.0.1:$port/synthetic-pgs.mkv' expected-PGS-ALPHA.mask expected-PGS-BETA.mask external.srt frames" \
  | tr -d '\r' > "$output/manifest.json"
adb pull "$remote_dir/frames" "$output/" >/dev/null
python3 - "$output/manifest.json" <<'PY'
import json
import sys
from pathlib import Path
manifest = json.loads(Path(sys.argv[1]).read_text())
assert manifest == {
    "schema": "emby-android-subtitle-render/v1",
    "decoderRegistration": "PASSED",
    "nativeSoftwarePixels": "PASSED",
    "localFile": "PASSED",
    "loopbackHttp": "PASSED",
    "switchDisableSeekReopen": "PASSED",
    "bitmapTextSwitch": "PASSED",
    "verifiedFrames": 40,
    "flutterTexture": "NOT_RUN",
    "physicalPhone": "NOT_RUN",
}
print("ANDROID_PACKAGED_SUBTITLE_SOFTWARE_PIXELS=PASSED")
PY
