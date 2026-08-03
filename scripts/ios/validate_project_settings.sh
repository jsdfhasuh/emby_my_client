#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_FILE="$ROOT_DIR/ios/Runner.xcodeproj"
INFO_PLIST="$ROOT_DIR/ios/Runner/Info.plist"
EXPECTED_BUNDLE_ID="com.jsdfhasuh.embyclient"
EXPECTED_DEPLOYMENT_TARGET="13.0"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required to validate iOS project settings" >&2
  exit 1
fi

if [[ ! -d "$PROJECT_FILE" || ! -f "$INFO_PLIST" ]]; then
  echo "iOS project or Info.plist is missing" >&2
  exit 1
fi

settings_file="$(mktemp "${TMPDIR:-/tmp}/runner-build-settings.XXXXXX")"
trap 'rm -f "$settings_file"' EXIT
xcodebuild \
  -project "$PROJECT_FILE" \
  -target Runner \
  -configuration Release \
  -sdk iphoneos \
  -showBuildSettings >"$settings_file"

setting() {
  local name="$1"
  awk -F ' = ' -v key="$name" '$1 == key { value = $2 } END { print value }' "$settings_file"
}

require_setting() {
  local name="$1"
  local expected="$2"
  local actual
  actual="$(setting "$name")"
  if [[ "$actual" != "$expected" ]]; then
    echo "$name expected '$expected', got '${actual:-<missing>}'" >&2
    exit 1
  fi
  echo "$name=$actual"
}

require_setting PRODUCT_BUNDLE_IDENTIFIER "$EXPECTED_BUNDLE_ID"
require_setting TARGETED_DEVICE_FAMILY 2
require_setting IPHONEOS_DEPLOYMENT_TARGET "$EXPECTED_DEPLOYMENT_TARGET"
require_setting SUPPORTED_PLATFORMS iphoneos
require_setting CODE_SIGN_ENTITLEMENTS Runner/Release.entitlements

plist_raw() {
  plutil -extract "$1" raw -o - "$INFO_PLIST"
}

if [[ "$(plist_raw UIRequiresFullScreen)" != "true" ]]; then
  echo "UIRequiresFullScreen must be true" >&2
  exit 1
fi
if [[ -z "$(plist_raw NSLocalNetworkUsageDescription)" ]]; then
  echo "NSLocalNetworkUsageDescription must be non-empty" >&2
  exit 1
fi
if [[ "$(plist_raw NSAppTransportSecurity.NSAllowsLocalNetworking)" != "true" ]]; then
  echo "NSAllowsLocalNetworking must be true" >&2
  exit 1
fi

ipad_orientations="$(plutil -extract 'UISupportedInterfaceOrientations~ipad' xml1 -o - "$INFO_PLIST")"
for orientation in \
  UIInterfaceOrientationPortrait \
  UIInterfaceOrientationPortraitUpsideDown \
  UIInterfaceOrientationLandscapeLeft \
  UIInterfaceOrientationLandscapeRight; do
  if ! printf '%s\n' "$ipad_orientations" | grep -Fq "<string>$orientation</string>"; then
    echo "Missing iPad orientation: $orientation" >&2
    exit 1
  fi
done

metadata="$ROOT_DIR/.metadata"
if ! grep -Fq 'revision: "67323de285b00232883f53b84095eb72be97d35c"' "$metadata"; then
  echo ".metadata does not record the fixed Flutter revision" >&2
  exit 1
fi
if ! awk '/^    - platform: ios$/ { found = 1 } END { exit(found ? 0 : 1) }' "$metadata"; then
  echo ".metadata does not register the iOS migration platform" >&2
  exit 1
fi

echo "Info.plist and .metadata checks passed"
