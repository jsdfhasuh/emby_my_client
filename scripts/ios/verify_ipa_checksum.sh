#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  echo "Usage: $0 <ipa-path> [checksum-path]" >&2
  exit 2
fi

ipa_path="$1"
ipa_dir="$(cd "$(dirname "$ipa_path")" && pwd)"
ipa_basename="$(basename "$ipa_path")"
checksum_path="${2:-$ipa_path.sha256}"
checksum_dir="$(cd "$(dirname "$checksum_path")" && pwd)"
checksum_basename="$(basename "$checksum_path")"

if [[ ! -f "$ipa_path" ]]; then
  echo "IPA is missing: $ipa_path" >&2
  exit 1
fi
if [[ ! -f "$checksum_path" ]]; then
  echo "IPA checksum is missing: $checksum_path" >&2
  exit 1
fi
if [[ "$ipa_dir" != "$checksum_dir" ]]; then
  echo "IPA and checksum must be in the same Artifact directory" >&2
  exit 1
fi

checksum_line="$(awk 'NF { print; count += 1 } END { if (count != 1) exit 1 }' "$checksum_path")" || {
  echo "IPA checksum must contain exactly one record" >&2
  exit 1
}
checksum_reference="$(printf '%s\n' "$checksum_line" | awk '{ print $2 }')"
checksum_reference="${checksum_reference#\*}"
if [[ "$checksum_reference" != "$ipa_basename" ]]; then
  echo "IPA checksum must reference basename $ipa_basename, got: $checksum_reference" >&2
  exit 1
fi
if [[ "$checksum_line" == *"/"* || "$checksum_line" == *"\\"* ]]; then
  echo "IPA checksum must not contain a path: $checksum_line" >&2
  exit 1
fi
if [[ "$checksum_line" == *"/Users/runner"* || "$checksum_line" == *"/home/runner"* ]]; then
  echo "IPA checksum contains a GitHub Runner path" >&2
  exit 1
fi

(
  cd "$ipa_dir"
  shasum -a 256 -c "$checksum_basename"
)
