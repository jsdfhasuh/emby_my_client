#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_FILE="${1:-$ROOT_DIR/scripts/ios/trollstore-entitlements.plist}"
shift || true

if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "Missing entitlement source: $SOURCE_FILE" >&2
  exit 1
fi

if [[ "$#" -eq 0 ]]; then
  set -- \
    "$ROOT_DIR/ios/Runner/DebugProfile.entitlements" \
    "$ROOT_DIR/ios/Runner/Release.entitlements"
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/entitlements.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

plist_keys() {
  local file="$1"
  plutil -p "$file" | awk '
    /^[[:space:]]*"[^"]+" =>/ {
      key = $1
      sub(/^"/, "", key)
      sub(/"$/, "", key)
      print key
    }
  ' | sort
}

canonicalize() {
  local input="$1"
  local output="$2"
  plutil -lint "$input" >/dev/null
  plutil -convert binary1 -o "$output" "$input"
}

source_keys="$(plist_keys "$SOURCE_FILE")"
if [[ "$source_keys" != "keychain-access-groups" ]]; then
  echo "Entitlement source contains an unapproved key set: $source_keys" >&2
  exit 1
fi

source_binary="$temp_dir/source.plist"
canonicalize "$SOURCE_FILE" "$source_binary"

for candidate in "$@"; do
  if [[ ! -f "$candidate" ]]; then
    echo "Missing entitlement candidate: $candidate" >&2
    exit 1
  fi
  candidate_keys="$(plist_keys "$candidate")"
  if [[ "$candidate_keys" != "keychain-access-groups" ]]; then
    echo "Entitlement candidate contains an unapproved key set: $candidate ($candidate_keys)" >&2
    exit 1
  fi
  candidate_binary="$temp_dir/$(printf '%s' "$candidate" | shasum -a 256 | cut -c1-16).plist"
  canonicalize "$candidate" "$candidate_binary"
  if ! cmp -s "$source_binary" "$candidate_binary"; then
    echo "Entitlements differ from the approved source: $candidate" >&2
    exit 1
  fi
  echo "entitlement_match=$candidate"
done

echo "entitlement_source=$SOURCE_FILE"
echo "entitlement_source_sha256=$(shasum -a 256 "$SOURCE_FILE" | awk '{print $1}')"
