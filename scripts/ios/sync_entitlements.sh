#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_FILE="${ENTITLEMENTS_SOURCE:-$ROOT_DIR/scripts/ios/trollstore-entitlements.plist}"
DEST_FILE="${1:-${RUNNER_TEMP:-$ROOT_DIR/build/ios}/resolved-entitlements.plist}"

if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "Missing entitlement source: $SOURCE_FILE" >&2
  exit 1
fi

plutil -lint "$SOURCE_FILE"
mkdir -p "$(dirname "$DEST_FILE")"
cp "$SOURCE_FILE" "$DEST_FILE"
plutil -lint "$DEST_FILE"
echo "entitlement_source=$SOURCE_FILE"
echo "resolved_entitlement=$DEST_FILE"
