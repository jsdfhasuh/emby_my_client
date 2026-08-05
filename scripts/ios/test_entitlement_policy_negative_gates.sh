#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATE="$ROOT_DIR/scripts/ios/validate_entitlements.sh"
SYNC="$ROOT_DIR/scripts/ios/sync_entitlements.sh"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/emby-ios-entitlement-policy.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    echo "Expected command to fail: $*" >&2
    exit 1
  fi
}

assert_passes() {
  if ! "$@" >/dev/null; then
    echo "Expected command to pass: $*" >&2
    exit 1
  fi
}

write_plist() {
  local file="$1"
  local body="$2"
  printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0">' \
    "$body" \
    '</plist>' >"$file"
}

assert_passes "$VALIDATE" --xcode \
  "$ROOT_DIR/scripts/ios/runner-entitlements.plist" \
  "$ROOT_DIR/ios/Runner/DebugProfile.entitlements" \
  "$ROOT_DIR/ios/Runner/Release.entitlements"
assert_fails "$SYNC" "$TEMP_DIR/ambiguous.plist"

write_plist "$TEMP_DIR/xcode-nonempty.plist" '<dict><key>keychain-access-groups</key><array><string>unexpected</string></array></dict>'
write_plist "$TEMP_DIR/xcode-missing.plist" '<dict/>'
write_plist "$TEMP_DIR/xcode-wrong-type.plist" '<dict><key>keychain-access-groups</key><string>empty</string></dict>'
write_plist "$TEMP_DIR/xcode-extra-key.plist" '<dict><key>keychain-access-groups</key><array/><key>get-task-allow</key><true/></dict>'
assert_fails "$VALIDATE" --xcode "$ROOT_DIR/scripts/ios/runner-entitlements.plist" "$TEMP_DIR/xcode-nonempty.plist"
assert_fails "$VALIDATE" --xcode "$TEMP_DIR/xcode-missing.plist"
assert_fails "$VALIDATE" --xcode "$TEMP_DIR/xcode-wrong-type.plist"
assert_fails "$VALIDATE" --xcode "$TEMP_DIR/xcode-extra-key.plist"

write_plist "$TEMP_DIR/trollstore-valid.plist" '<dict><key>application-identifier</key><string>TROLLTROLL.com.jsdfhasuh.embyclient</string><key>com.apple.developer.team-identifier</key><string>TROLLTROLL</string><key>keychain-access-groups</key><array><string>TROLLTROLL.com.jsdfhasuh.embyclient</string></array></dict>'
resolved="$TEMP_DIR/resolved-entitlements.plist"
assert_passes "$SYNC" --trollstore "$resolved"
assert_passes "$VALIDATE" --trollstore \
  "$ROOT_DIR/scripts/ios/trollstore-entitlements.plist" "$resolved"
assert_passes "$VALIDATE" --trollstore-dump "$resolved"

write_plist "$TEMP_DIR/trollstore-empty-group.plist" '<dict><key>application-identifier</key><string>TROLLTROLL.com.jsdfhasuh.embyclient</string><key>com.apple.developer.team-identifier</key><string>TROLLTROLL</string><key>keychain-access-groups</key><array/></dict>'
write_plist "$TEMP_DIR/trollstore-missing-app.plist" '<dict><key>com.apple.developer.team-identifier</key><string>TROLLTROLL</string><key>keychain-access-groups</key><array><string>TROLLTROLL.com.jsdfhasuh.embyclient</string></array></dict>'
write_plist "$TEMP_DIR/trollstore-missing-team.plist" '<dict><key>application-identifier</key><string>TROLLTROLL.com.jsdfhasuh.embyclient</string><key>keychain-access-groups</key><array><string>TROLLTROLL.com.jsdfhasuh.embyclient</string></array></dict>'
write_plist "$TEMP_DIR/trollstore-mismatch.plist" '<dict><key>application-identifier</key><string>TROLLTROLL.com.jsdfhasuh.embyclient</string><key>com.apple.developer.team-identifier</key><string>TROLLTROLL</string><key>keychain-access-groups</key><array><string>TROLLTROLL.other</string></array></dict>'
write_plist "$TEMP_DIR/trollstore-wildcard.plist" '<dict><key>application-identifier</key><string>TROLLTROLL.com.jsdfhasuh.embyclient</string><key>com.apple.developer.team-identifier</key><string>TROLLTROLL</string><key>keychain-access-groups</key><array><string>TROLLTROLL.*</string></array></dict>'
write_plist "$TEMP_DIR/trollstore-token.plist" '<dict><key>application-identifier</key><string>TROLLTROLL.com.jsdfhasuh.embyclient</string><key>com.apple.developer.team-identifier</key><string>TROLLTROLL</string><key>keychain-access-groups</key><array><string>TROLLTROLL.com.jsdfhasuh.embyclient</string></array><key>com.apple.token</key><true/></dict>'
write_plist "$TEMP_DIR/trollstore-get-task.plist" '<dict><key>application-identifier</key><string>TROLLTROLL.com.jsdfhasuh.embyclient</string><key>com.apple.developer.team-identifier</key><string>TROLLTROLL</string><key>keychain-access-groups</key><array><string>TROLLTROLL.com.jsdfhasuh.embyclient</string></array><key>get-task-allow</key><true/></dict>'
write_plist "$TEMP_DIR/trollstore-group-string.plist" '<dict><key>application-identifier</key><string>TROLLTROLL.com.jsdfhasuh.embyclient</string><key>com.apple.developer.team-identifier</key><string>TROLLTROLL</string><key>keychain-access-groups</key><string>TROLLTROLL.com.jsdfhasuh.embyclient</string></dict>'
write_plist "$TEMP_DIR/trollstore-two-groups.plist" '<dict><key>application-identifier</key><string>TROLLTROLL.com.jsdfhasuh.embyclient</string><key>com.apple.developer.team-identifier</key><string>TROLLTROLL</string><key>keychain-access-groups</key><array><string>TROLLTROLL.com.jsdfhasuh.embyclient</string><string>extra</string></array></dict>'
for invalid in \
  "$TEMP_DIR/trollstore-empty-group.plist" \
  "$TEMP_DIR/trollstore-missing-app.plist" \
  "$TEMP_DIR/trollstore-missing-team.plist" \
  "$TEMP_DIR/trollstore-mismatch.plist" \
  "$TEMP_DIR/trollstore-wildcard.plist" \
  "$TEMP_DIR/trollstore-token.plist" \
  "$TEMP_DIR/trollstore-get-task.plist" \
  "$TEMP_DIR/trollstore-group-string.plist" \
  "$TEMP_DIR/trollstore-two-groups.plist"; do
  assert_fails "$VALIDATE" --trollstore "$invalid" "$resolved"
  assert_fails "$VALIDATE" --trollstore-dump "$invalid"
done

write_plist "$TEMP_DIR/tampered.plist" '<dict><key>application-identifier</key><string>TROLLTROLL.com.jsdfhasuh.other</string><key>com.apple.developer.team-identifier</key><string>TROLLTROLL</string><key>keychain-access-groups</key><array><string>TROLLTROLL.com.jsdfhasuh.other</string></array></dict>'
assert_fails "$VALIDATE" --trollstore \
  "$ROOT_DIR/scripts/ios/trollstore-entitlements.plist" "$TEMP_DIR/tampered.plist"

write_plist "$TEMP_DIR/embedded-empty.plist" '<dict/>'
write_plist "$TEMP_DIR/embedded-runner.plist" '<dict><key>keychain-access-groups</key><array><string>TROLLTROLL.com.jsdfhasuh.embyclient</string></array></dict>'
assert_passes "$ROOT_DIR/scripts/ios/validate_embedded_entitlements.sh" "$TEMP_DIR/embedded-empty.plist"
assert_fails "$ROOT_DIR/scripts/ios/validate_embedded_entitlements.sh" "$TEMP_DIR/embedded-runner.plist"

echo 'Entitlement policy negative gates passed'
