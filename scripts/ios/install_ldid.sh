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
tap_name='local/ldid-lock'
tap_repo=''
cleanup() {
  rm -f "$formula_file"
  if [[ -n "$tap_repo" ]]; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew untap --force "$tap_name" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

curl --fail --location --silent --show-error "$FORMULA_URL" --output "$formula_file"
printf '%s  %s\n' "$FORMULA_SHA256" "$formula_file" | shasum --algorithm 256 --check --strict
grep -Fq "tag:      \"$SOURCE_TAG\"" "$formula_file"
grep -Fq "revision: \"$SOURCE_REVISION\"" "$formula_file"
grep -Fq "revision $FORMULA_REVISION" "$formula_file"

# Homebrew rejects a standalone .rb path, so install the already-verified
# Homebrew Core formula through an ephemeral local tap. No alternate ldid
# implementation is selected when this formula is unavailable.
HOMEBREW_NO_AUTO_UPDATE=1 brew tap-new --no-git "$tap_name"
tap_repo="$(brew --repository "$tap_name")"
mkdir -p "$tap_repo/Formula"
cp "$formula_file" "$tap_repo/Formula/ldid.rb"
HOMEBREW_NO_AUTO_UPDATE=1 brew install --formula "$tap_name/ldid"
"$ROOT_DIR/scripts/ios/verify_ldid.sh"
