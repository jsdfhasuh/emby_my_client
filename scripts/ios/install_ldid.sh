#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/ios/ldid.lock"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required to install Homebrew Core ldid $LDID_VERSION" >&2
  exit 1
fi

formula_file="$(mktemp "${TMPDIR:-/tmp}/ldid-formula.XXXXXX.rb")"
trap 'rm -f "$formula_file"' EXIT

curl --fail --location --silent --show-error "$FORMULA_URL" --output "$formula_file"
printf '%s  %s\n' "$FORMULA_SHA256" "$formula_file" | shasum --algorithm 256 --check --strict
grep -Fq "tag:      \"$SOURCE_TAG\"" "$formula_file"
grep -Fq "revision: \"$SOURCE_REVISION\"" "$formula_file"

# The formula URL is pinned to a Homebrew Core commit. No alternate ldid
# implementation is selected when this formula is unavailable.
HOMEBREW_NO_AUTO_UPDATE=1 brew install --formula "$formula_file"
"$ROOT_DIR/scripts/ios/verify_ldid.sh"
