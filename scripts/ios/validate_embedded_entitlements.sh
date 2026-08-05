#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  echo "Usage: validate_embedded_entitlements.sh entitlement-dump.plist [...]" >&2
  exit 2
fi

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

for candidate in "$@"; do
  if [[ ! -f "$candidate" ]]; then
    echo "Missing embedded entitlement dump: $candidate" >&2
    exit 1
  fi
  plutil -lint "$candidate" >/dev/null
  keys="$(plist_keys "$candidate")"
  json="$(plutil -convert json -o - "$candidate" | tr -d '[:space:]')"
  if [[ "$json" != '{}' || -n "$keys" ]]; then
    echo "Embedded Mach-O contains application entitlement(s): $candidate (${keys:-non-empty entitlement dictionary})" >&2
    echo "Frameworks and dylibs must not carry Runner keychain-access-groups or private application entitlements" >&2
    exit 1
  fi
  echo "embedded_entitlement_clear=$candidate"
done
