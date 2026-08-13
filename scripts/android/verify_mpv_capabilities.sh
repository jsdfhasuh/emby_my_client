#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: verify_mpv_capabilities.sh apk [...]" >&2
  exit 64
fi

if ! command -v unzip >/dev/null 2>&1; then
  echo "Missing required command: unzip" >&2
  exit 69
fi

readelf_command="${READELF:-}"
if [[ -z "$readelf_command" ]]; then
  if command -v readelf >/dev/null 2>&1; then
    readelf_command=readelf
  elif command -v llvm-readelf >/dev/null 2>&1; then
    readelf_command=llvm-readelf
  else
    echo "Missing required command: readelf or llvm-readelf" >&2
    exit 69
  fi
fi

strings_command="${STRINGS:-}"
if [[ -z "$strings_command" ]]; then
  if command -v strings >/dev/null 2>&1; then
    strings_command='strings'
  elif command -v llvm-strings >/dev/null 2>&1; then
    strings_command=llvm-strings
  else
    echo "Missing required command: strings or llvm-strings" >&2
    exit 69
  fi
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/emby-android-mpv.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

required_symbols=(
  mpv_create
  mpv_initialize
  mpv_get_property
  mpv_get_property_string
  mpv_set_property_string
  mpv_command
  mpv_terminate_destroy
)

required_common_strings=(
  cache
  cache-on-disk
  cache-secs
  demuxer-cache-state
  demuxer-max-bytes
  demuxer-max-back-bytes
  immediate
)

directory_aliases=(demuxer-cache-dir cache-dir)
unlink_aliases=(demuxer-cache-unlink-files cache-unlink-files)

for apk_path in "$@"; do
  if [[ ! -f "$apk_path" ]]; then
    echo "Missing APK: $apk_path" >&2
    exit 66
  fi

  mapfile -t libraries < <(
    unzip -Z1 "$apk_path" | awk '/^lib\/(arm64-v8a|armeabi-v7a|x86|x86_64)\/libmpv\.so$/ { print }'
  )
  if (( ${#libraries[@]} == 0 )); then
    echo "No packaged libmpv.so found: $apk_path" >&2
    exit 65
  fi

  for entry in "${libraries[@]}"; do
    abi="$(cut -d/ -f2 <<<"$entry")"
    output="$temp_dir/$(basename "$apk_path")-$abi-libmpv.so"
    unzip -p "$apk_path" "$entry" >"$output"
    test -s "$output"

    symbols="$("$readelf_command" --wide --dyn-syms "$output")"
    for symbol in "${required_symbols[@]}"; do
      if ! grep -Eq "[[:space:]]${symbol}(@@[^[:space:]]+)?$" <<<"$symbols"; then
        echo "Missing libmpv symbol $symbol in $apk_path ($abi)" >&2
        exit 65
      fi
    done

    binary_strings="$("$strings_command" -a "$output")"
    for capability in "${required_common_strings[@]}"; do
      if ! grep -Fqx "$capability" <<<"$binary_strings"; then
        echo "Missing libmpv capability string $capability in $apk_path ($abi)" >&2
        exit 65
      fi
    done
    directory_found=''
    for capability in "${directory_aliases[@]}"; do
      if grep -Fqx "$capability" <<<"$binary_strings"; then
        directory_found='1'
      fi
    done
    unlink_found=''
    for capability in "${unlink_aliases[@]}"; do
      if grep -Fqx "$capability" <<<"$binary_strings"; then
        unlink_found='1'
      fi
    done
    if [[ "$directory_found" != '1' || "$unlink_found" != '1' ]]; then
      echo "Missing compatible cache directory/unlink alias in $apk_path ($abi)" >&2
      exit 65
    fi
    echo "android_mpv_static_capability_smoke=$apk_path:$abi"
  done
done
