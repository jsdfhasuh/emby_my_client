#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: run_mpv_startability_probe.sh app-x86_64-debug.apk [evidence.json]" >&2
  exit 64
fi

apk_path="$1"
evidence_path="${2:-build/android/artifacts/android-mpv-capability-manifest.json}"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ ! -f "$apk_path" ]]; then
  echo "Missing APK: $apk_path" >&2
  exit 66
fi
if ! command -v adb >/dev/null 2>&1; then
  echo "Missing required command: adb" >&2
  exit 69
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "Missing required command: python3" >&2
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

run_id="${GITHUB_RUN_ID:-0}"
run_attempt="${GITHUB_RUN_ATTEMPT:-0}"
if [[ ! "$run_id" =~ ^[0-9]+$ || ! "$run_attempt" =~ ^[0-9]+$ ]]; then
  echo 'Unsafe Android probe run identity' >&2
  exit 65
fi
remote_dir="/data/local/tmp/emby-mpv-startability-${run_id}-${run_attempt}-$$"
case "$remote_dir" in
  /data/local/tmp/emby-mpv-startability-[0-9]*-[0-9]*-[0-9]*) ;;
  *) echo 'Unsafe Android probe remote directory' >&2; exit 65 ;;
esac
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/emby-android-mpv-start.XXXXXX")"
cleanup() {
  adb shell rm -rf "$remote_dir" >/dev/null 2>&1 || true
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT

native_dir="$temp_dir/native"
mkdir -p "$native_dir" "$(dirname "$evidence_path")"
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
  -std=c11 -Wall -Wextra -Werror \
  "$root_dir/scripts/android/mpv_startability_probe.c" \
  -L"$native_dir" -lmpv \
  -Wl,--allow-shlib-undefined "-Wl,-rpath,\$ORIGIN" \
  -o "$native_dir/mpv_startability_probe"

adb shell rm -rf "$remote_dir"
adb shell mkdir -p "$remote_dir"
adb shell mkdir -p "$remote_dir/cache-probe"
adb push "$native_dir/." "$remote_dir/" >/dev/null
adb shell chmod 0700 "$remote_dir/mpv_startability_probe"
self_test="$(
  adb shell "cd '$remote_dir' && LD_LIBRARY_PATH=. ./mpv_startability_probe --self-test" |
    tr -d '\r'
)"
test "$self_test" = 'android_mpv_probe_semantics=passed'
raw_evidence="$temp_dir/android-mpv-capability-manifest.json"
adb shell "cd '$remote_dir' && LD_LIBRARY_PATH=. ./mpv_startability_probe" \
  | tr -d '\r' >"$raw_evidence"

ANDROID_MPV_EVIDENCE="$raw_evidence" python3 - <<'PY'
import json
import os
import re
from pathlib import Path

path = Path(os.environ['ANDROID_MPV_EVIDENCE'])
manifest = json.loads(path.read_text(encoding='utf-8'))
expected_top = {
    'schema', 'mpvVersionFingerprint', 'platform', 'logicalOptionCount',
    'nativeCandidateCount', 'nativeCandidates', 'resolvedOptions',
    'candidateEvidence', 'profileReadBack', 'optionalTuningDegraded',
    'optionBindingGate', 'memoryProfileGate', 'disabledProfileGate',
    'diskProfileGate', 'activeContextGate', 'diskTelemetryEvidenceGate',
}
candidates = {
    'cache': ['cache'],
    'cacheOnDisk': ['cache-on-disk'],
    'cacheDirectory': ['demuxer-cache-dir', 'cache-dir'],
    'cacheUnlinkFiles': [
        'demuxer-cache-unlink-files', 'cache-unlink-files'
    ],
    'cacheSeconds': ['cache-secs'],
    'forwardMetadataBytes': ['demuxer-max-bytes'],
    'backwardMetadataBytes': ['demuxer-max-back-bytes'],
    'donateBuffer': ['demuxer-donate-buffer'],
    'seekableCache': ['demuxer-seekable-cache'],
    'cachePause': ['cache-pause'],
    'cachePauseWait': ['cache-pause-wait'],
    'streamBufferSize': ['stream-buffer-size'],
}
record_keys = {
    'nativeName', 'status', 'optionNameMatches', 'optionExists',
    'resetAvailable', 'requiredChoiceAvailable', 'writeReadBackPassed',
}
assert set(manifest) == expected_top
assert manifest['schema'] == 'emby-android-mpv-capabilities/v1'
assert manifest['platform'] == 'Android'
assert re.fullmatch(
    r'mpv-[0-9]+(?:\.[0-9]+)+(?:[-+][A-Za-z0-9._-]+)?',
    manifest['mpvVersionFingerprint'],
)
assert manifest['logicalOptionCount'] == 12
assert manifest['nativeCandidateCount'] == 14
all_native = {name for names in candidates.values() for name in names}
assert set(manifest['nativeCandidates']) == all_native
assert all(type(value) is bool for value in manifest['nativeCandidates'].values())
assert set(manifest['candidateEvidence']) == set(candidates)
assert set(manifest['resolvedOptions']).issubset(candidates)
for logical, names in candidates.items():
    records = manifest['candidateEvidence'][logical]
    assert [record['nativeName'] for record in records] == names
    for record in records:
        assert set(record) == record_keys
        assert record['status'] in {'unavailable', 'incomplete', 'usable'}
        for key in record_keys - {'nativeName', 'status'}:
            assert type(record[key]) is bool
        complete = (
            record['optionNameMatches']
            and record['optionExists']
            and record['resetAvailable']
            and record['requiredChoiceAvailable']
            and record['writeReadBackPassed']
        )
        expected_status = (
            'usable' if complete else
            'unavailable' if not record['optionExists'] else
            'incomplete'
        )
        assert record['status'] == expected_status
    usable = next(
        (record['nativeName'] for record in records if record['status'] == 'usable'),
        None,
    )
    assert manifest['resolvedOptions'].get(logical) == usable
assert set(manifest['profileReadBack']) == {'disk', 'memory', 'disabled'}
assert all(type(value) is bool for value in manifest['profileReadBack'].values())
assert type(manifest['optionalTuningDegraded']) is bool
assert manifest['optionBindingGate'] == 'PASSED'
assert manifest['profileReadBack']['memory'] is True
assert manifest['memoryProfileGate'] == 'PASSED'
assert manifest['profileReadBack']['disabled'] is True
assert manifest['disabledProfileGate'] == 'PASSED'
expected_disk = (
    'PASSED' if manifest['profileReadBack']['disk']
    else 'BLOCKED_BY_BUNDLED_LIBMPV'
)
assert manifest['diskProfileGate'] == expected_disk
assert manifest['activeContextGate'] == 'NOT_RUN'
assert manifest['diskTelemetryEvidenceGate'] == 'NOT_RUN'
PY

cp "$raw_evidence" "$evidence_path"
test -s "$evidence_path"
echo "android_mpv_semantic_evidence=$evidence_path"
