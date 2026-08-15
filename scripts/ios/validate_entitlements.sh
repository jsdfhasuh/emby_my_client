#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER_SOURCE="${RUNNER_ENTITLEMENTS_SOURCE:-$ROOT_DIR/scripts/ios/runner-entitlements.plist}"
TROLLSTORE_SOURCE="${TROLLSTORE_ENTITLEMENTS_SOURCE:-$ROOT_DIR/scripts/ios/trollstore-entitlements.plist}"
EXPECTED_APPLICATION_IDENTIFIER='TROLLTROLL.com.jsdfhasuh.embyclient'
EXPECTED_TEAM_IDENTIFIER='TROLLTROLL'

usage() {
  cat <<'USAGE'
Usage:
  validate_entitlements.sh --xcode [source] [candidate ...]
  validate_entitlements.sh --trollstore [source] [candidate ...]
  validate_entitlements.sh --trollstore-dump dump.plist [...]
USAGE
}

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

plist_entry() {
  local file="$1"
  local key="$2"
  local quoted_key="\"$key\""
  plutil -p "$file" | awk -v quoted_key="$quoted_key" '
    $1 == quoted_key && $2 == "=>" {
      value = $0
      sub(/^[^=]*=>[[:space:]]*/, "", value)
      print value
      found = 1
      exit
    }
    END {
      if (!found) exit 1
    }
  '
}

plist_scalar() {
  local file="$1"
  local key="$2"
  local value
  value="$(plist_entry "$file" "$key")"
  case "$value" in
    \"*\")
      printf '%s\n' "${value:1:${#value}-2}"
      ;;
    *)
      echo "$file: $key must be a string" >&2
      return 1
      ;;
  esac
}

require_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "Missing entitlement file: $file" >&2
    exit 1
  fi
  plutil -lint "$file" >/dev/null
}

require_key_type() {
  local file="$1"
  local key="$2"
  local expected_type="$3"
  local actual_type
  actual_type="$(plutil -type "$key" "$file" 2>/dev/null || printf '%s' unknown)"
  actual_type="$(printf '%s' "$actual_type" | tr '[:upper:]' '[:lower:]')"
  case "$actual_type" in
    bool|boolean) actual_type='boolean' ;;
    dict|dictionary) actual_type='dictionary' ;;
    array|string) ;;
    *) actual_type='unknown' ;;
  esac
  if [[ "$actual_type" != "$expected_type" ]]; then
    echo "$file: $key must be $expected_type, got $actual_type" >&2
    exit 1
  fi
}

plist_boolean() {
  local file="$1"
  local key="$2"
  local value
  value="$(plist_entry "$file" "$key")"
  case "$value" in
    true|1) printf '%s\n' true ;;
    false|0) printf '%s\n' false ;;
    *)
      echo "$file: $key must be a boolean" >&2
      return 1
      ;;
  esac
}

validate_xcode_file() {
  local file="$1"
  require_file "$file"
  if [[ "$(plist_keys "$file")" != $'com.apple.developer.networking.multicast\nkeychain-access-groups' ]]; then
    echo "Xcode entitlement has an unapproved key set: $file" >&2
    exit 1
  fi
  require_key_type "$file" com.apple.developer.networking.multicast boolean
  require_key_type "$file" keychain-access-groups array
  local multicast groups
  multicast="$(plist_boolean "$file" com.apple.developer.networking.multicast)"
  groups="$(plutil -extract keychain-access-groups json -o - "$file" | tr -d '[:space:]')"
  if [[ "$multicast" != 'true' ]]; then
    echo "Xcode Runner multicast entitlement must be true: $file" >&2
    exit 1
  fi
  if [[ "$groups" != '[]' ]]; then
    echo "Xcode Runner entitlement must contain an empty keychain group array: $file" >&2
    exit 1
  fi
}

validate_trollstore_file() {
  local file="$1"
  require_file "$file"
  local keys
  keys="$(plist_keys "$file")"
  if [[ "$keys" != $'application-identifier\ncom.apple.developer.networking.multicast\ncom.apple.developer.team-identifier\nkeychain-access-groups' ]]; then
    echo "TrollStore entitlement has an unapproved key set: $file ($keys)" >&2
    exit 1
  fi
  require_key_type "$file" application-identifier string
  require_key_type "$file" com.apple.developer.networking.multicast boolean
  require_key_type "$file" com.apple.developer.team-identifier string
  require_key_type "$file" keychain-access-groups array

  local application_identifier multicast team_identifier groups
  application_identifier="$(plist_scalar "$file" application-identifier)"
  multicast="$(plist_boolean "$file" com.apple.developer.networking.multicast)"
  team_identifier="$(plist_scalar "$file" com.apple.developer.team-identifier)"
  groups="$(plutil -extract keychain-access-groups json -o - "$file" | tr -d '[:space:]')"
  if [[ "$application_identifier" != "$EXPECTED_APPLICATION_IDENTIFIER" ]]; then
    echo "Unexpected application-identifier in $file" >&2
    exit 1
  fi
  if [[ "$multicast" != 'true' ]]; then
    echo "TrollStore multicast entitlement must be true: $file" >&2
    exit 1
  fi
  if [[ "$team_identifier" != "$EXPECTED_TEAM_IDENTIFIER" ]]; then
    echo "Unexpected team identifier in $file" >&2
    exit 1
  fi
  if [[ "$groups" != '["TROLLTROLL.com.jsdfhasuh.embyclient"]' ]]; then
    echo "TrollStore entitlement must contain exactly one approved keychain group: $file" >&2
    exit 1
  fi
}

validate_candidates_against_source() {
  local mode="$1"
  local source="$2"
  shift 2
  local candidate

  compare_plist_values() {
    local expected="$1"
    local actual="$2"
    if [[ "$(plutil -p "$expected")" != "$(plutil -p "$actual")" ]]; then
      echo "Entitlement values differ between source and candidate: $expected $actual" >&2
      exit 1
    fi
  }

  if [[ "$mode" == 'xcode' ]]; then
    validate_xcode_file "$source"
  else
    validate_trollstore_file "$source"
  fi

  for candidate in "$@"; do
    if [[ "$mode" == 'xcode' ]]; then
      validate_xcode_file "$candidate"
    else
      validate_trollstore_file "$candidate"
    fi
    compare_plist_values "$source" "$candidate"
    echo "${mode}_entitlement_match=$candidate"
  done

  echo "${mode}_entitlement_source=$source"
  echo "${mode}_entitlement_source_sha256=$(shasum -a 256 "$source" | awk '{print $1}')"
}

if [[ "$#" -lt 1 ]]; then
  usage >&2
  exit 2
fi

mode="$1"
shift
case "$mode" in
  --xcode)
    source="${1:-$RUNNER_SOURCE}"
    if [[ "$#" -gt 0 ]]; then
      shift
    fi
    if [[ "$#" -eq 0 ]]; then
      set -- \
        "$ROOT_DIR/ios/Runner/DebugProfile.entitlements" \
        "$ROOT_DIR/ios/Runner/Release.entitlements"
    fi
    validate_candidates_against_source xcode "$source" "$@"
    ;;
  --trollstore)
    source="${1:-$TROLLSTORE_SOURCE}"
    if [[ "$#" -gt 0 ]]; then
      shift
    fi
    if [[ "$#" -eq 0 ]]; then
      echo "--trollstore requires at least one resolved entitlement candidate" >&2
      exit 2
    fi
    validate_candidates_against_source trollstore "$source" "$@"
    ;;
  --trollstore-dump)
    if [[ "$#" -eq 0 ]]; then
      echo "--trollstore-dump requires at least one entitlement dump" >&2
      exit 2
    fi
    for dump in "$@"; do
      validate_trollstore_file "$dump"
      echo "trollstore_dump_match=$dump"
    done
    ;;
  -h|--help)
    if [[ "$#" -ne 0 ]]; then
      usage >&2
      exit 2
    fi
    usage
    ;;
  *)
    echo "An explicit entitlement validation mode is required" >&2
    usage >&2
    exit 2
    ;;
esac
