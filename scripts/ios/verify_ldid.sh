#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/ios/ldid.lock"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required to verify ldid" >&2
  exit 1
fi

installed="$(brew list --versions ldid 2>/dev/null || true)"
installed_version="${installed#ldid }"
if [[ "$installed_version" != "$LDID_VERSION" &&
  "$installed_version" != "${LDID_VERSION}_${FORMULA_REVISION}" ]]; then
  echo "Expected Homebrew Core ldid $LDID_VERSION (formula revision $FORMULA_REVISION), got: ${installed:-not installed}" >&2
  exit 1
fi

ldid_path="$(command -v ldid || true)"
if [[ -z "$ldid_path" ]]; then
  echo "ldid is not on PATH" >&2
  exit 1
fi
case "$ldid_path" in
  *procursus*)
    echo "ldid-procursus is forbidden: $ldid_path" >&2
    exit 1
    ;;
esac

brew_prefix="$(brew --prefix)"
ldid_prefix="$(brew --prefix ldid)"
case "$ldid_path" in
  "$brew_prefix"/*|"$ldid_prefix"/*) ;;
  *)
    echo "ldid is not provided by Homebrew Core: $ldid_path" >&2
    exit 1
    ;;
esac

formula_file="$(mktemp "${TMPDIR:-/tmp}/ldid-formula.XXXXXX")"
trap 'rm -f "$formula_file"' EXIT
curl --fail --location --silent --show-error "$FORMULA_URL" --output "$formula_file"
printf '%s  %s\n' "$FORMULA_SHA256" "$formula_file" | shasum --algorithm 256 --check --strict
grep -Fq "tag:      \"$SOURCE_TAG\"" "$formula_file"
grep -Fq "revision: \"$SOURCE_REVISION\"" "$formula_file"
grep -Fq "revision $FORMULA_REVISION" "$formula_file"

echo "ldid_path=$ldid_path"
echo "ldid_version=$LDID_VERSION"
echo "ldid_formula_version=$installed_version"
echo "ldid_formula_revision=$FORMULA_REVISION"
echo "homebrew_core_commit=$HOMEBREW_CORE_COMMIT"
echo "formula_url=$FORMULA_URL"
echo "formula_sha256=$FORMULA_SHA256"
echo "source_tag=$SOURCE_TAG"
echo "source_revision=$SOURCE_REVISION"
