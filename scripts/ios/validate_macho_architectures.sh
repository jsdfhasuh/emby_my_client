#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:?Usage: validate_macho_architectures.sh Runner.app [output-file]}"
OUTPUT_FILE="${2:-}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Application bundle not found: $APP_PATH" >&2
  exit 1
fi
if [[ ! -f "$APP_PATH/Runner" ]]; then
  echo "Main Runner executable is missing: $APP_PATH/Runner" >&2
  exit 1
fi
if ! command -v file >/dev/null 2>&1 || ! command -v lipo >/dev/null 2>&1; then
  echo "file and lipo are required for architecture validation" >&2
  exit 1
fi

paths_file="$(mktemp "${TMPDIR:-/tmp}/macho-paths.XXXXXX")"
trap 'rm -f "$paths_file"' EXIT
find "$APP_PATH" -type f -print0 >"$paths_file"

output=""
failed=0
found=0
while IFS= read -r -d '' path; do
  description="$(file -b "$path")"
  case "$description" in
    *Mach-O*)
      found=$((found + 1))
      info="$(lipo -info "$path")" || {
        echo "Unable to inspect Mach-O: $path" >&2
        failed=1
        continue
      }
      output="$output$path: $info\n"
      if ! lipo -verify_arch arm64 "$path" >/dev/null 2>&1; then
        echo "Mach-O is not arm64: $path ($info)" >&2
        failed=1
      fi
      for forbidden in x86_64 i386 armv7 armv7s arm64e; do
        case "$info" in
          *"$forbidden"*)
            echo "Simulator or unsupported architecture '$forbidden' found: $path ($info)" >&2
            failed=1
            ;;
        esac
      done
      ;;
  esac
done <"$paths_file"

if [[ "$found" -eq 0 ]]; then
  echo "No Mach-O files found in $APP_PATH" >&2
  exit 1
fi
if [[ -n "$OUTPUT_FILE" ]]; then
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  printf '%b' "$output" >"$OUTPUT_FILE"
fi
printf '%b' "$output"
if [[ "$failed" -ne 0 ]]; then
  exit 1
fi
echo "Mach-O architecture check passed: $found file(s), arm64 only"
