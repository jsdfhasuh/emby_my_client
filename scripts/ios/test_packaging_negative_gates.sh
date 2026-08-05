#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/scripts/ios/build_trollstore_ipa.sh"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/emby-ios-negative-gates.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    echo "Expected command to fail: $*" >&2
    exit 1
  fi
}

write_app() {
  local destination="$1"
  local bundle_id="$2"
  mkdir -p "$destination"
  cat >"$destination/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>negative</string>
</dict>
</plist>
PLIST
  touch "$destination/Runner"
}

write_app "$TEMP_DIR/wrong-bundle.app" 'com.example.wrong'
mkdir -p "$TEMP_DIR/appex.app/PlugIns/Unknown.appex"
write_app "$TEMP_DIR/appex.app" 'com.jsdfhasuh.embyclient'
mkdir -p "$TEMP_DIR/Runner.app.dSYM"

run_build_fixture() {
  local app_path="$1"
  local artifact_dir="$2"
  mkdir -p "$artifact_dir"
  APP_SOURCE="$app_path" \
    DSYM_SOURCE="$TEMP_DIR/Runner.app.dSYM" \
    ARTIFACT_DIR="$artifact_dir" \
    RUN_NUMBER='negative' \
    COMMIT_SHA='negative' \
    "$BUILD_SCRIPT"
}

assert_fails run_build_fixture \
  "$TEMP_DIR/wrong-bundle.app" "$TEMP_DIR/wrong-bundle-artifacts"
assert_fails run_build_fixture \
  "$TEMP_DIR/appex.app" "$TEMP_DIR/appex-artifacts"

cat >"$TEMP_DIR/empty-entitlements.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict/></plist>
PLIST
cat >"$TEMP_DIR/application-entitlements.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>keychain-access-groups</key><array/></dict></plist>
PLIST
assert_fails "$ROOT_DIR/scripts/ios/validate_embedded_entitlements.sh" \
  "$TEMP_DIR/application-entitlements.plist"
"$ROOT_DIR/scripts/ios/validate_embedded_entitlements.sh" \
  "$TEMP_DIR/empty-entitlements.plist" >/dev/null

printf '%s\n' \
  $'embedded\tFrameworks/App.framework/App' \
  $'main\tRunner' >"$TEMP_DIR/signing-order-valid.txt"
"$ROOT_DIR/scripts/ios/validate_signing_order.sh" \
  "$TEMP_DIR/signing-order-valid.txt" >/dev/null
printf '%s\n' \
  $'main\tRunner' \
  $'embedded\tFrameworks/App.framework/App' >"$TEMP_DIR/signing-order-swapped.txt"
assert_fails "$ROOT_DIR/scripts/ios/validate_signing_order.sh" \
  "$TEMP_DIR/signing-order-swapped.txt"
printf '%s\n' \
  $'embedded\tFrameworks/App.framework/App' \
  $'main\tRunner' \
  $'embedded\tFrameworks/Other.framework/Other' >"$TEMP_DIR/signing-order-not-last.txt"
assert_fails "$ROOT_DIR/scripts/ios/validate_signing_order.sh" \
  "$TEMP_DIR/signing-order-not-last.txt"

mkdir -p "$TEMP_DIR/fake-bin" "$TEMP_DIR/non-arm64.app"
touch "$TEMP_DIR/non-arm64.app/Runner"
cat >"$TEMP_DIR/fake-bin/file" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *Runner) printf '%s\n' 'Mach-O 64-bit executable' ;;
  *) printf '%s\n' 'ASCII text' ;;
esac
SCRIPT
cat >"$TEMP_DIR/fake-bin/lipo" <<'SCRIPT'
#!/usr/bin/env bash
printf 'Non-fat file: %s is architecture: x86_64\n' "$2"
SCRIPT
chmod +x "$TEMP_DIR/fake-bin/file" "$TEMP_DIR/fake-bin/lipo"
assert_fails env PATH="$TEMP_DIR/fake-bin:$PATH" \
  "$ROOT_DIR/scripts/ios/validate_macho_architectures.sh" \
  "$TEMP_DIR/non-arm64.app"

mkdir -p "$TEMP_DIR/lock-repo"
git -C "$TEMP_DIR/lock-repo" init --quiet
printf '%s\n' locked >"$TEMP_DIR/lock-repo/pubspec.lock"
git -C "$TEMP_DIR/lock-repo" add pubspec.lock
git -C "$TEMP_DIR/lock-repo" \
  -c user.name='negative-gates' \
  -c user.email='negative-gates@example.invalid' \
  commit --quiet --message baseline
printf '%s\n' drifted >"$TEMP_DIR/lock-repo/pubspec.lock"
assert_fails git -C "$TEMP_DIR/lock-repo" diff --exit-code -- pubspec.lock

cat >"$TEMP_DIR/fake-bin/brew" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$1" == 'list' && "$2" == '--versions' && "$3" == 'ldid' ]]; then
  printf '%s\n' 'ldid 9.9.9'
  exit 0
fi
exit 1
SCRIPT
chmod +x "$TEMP_DIR/fake-bin/brew"
assert_fails env PATH="$TEMP_DIR/fake-bin:$PATH" \
  "$ROOT_DIR/scripts/ios/verify_ldid.sh"

checksum_artifacts="$TEMP_DIR/checksum-artifacts"
mkdir -p "$checksum_artifacts"
printf '%s\n' 'fake ipa payload' >"$checksum_artifacts/example.ipa"
(
  cd "$checksum_artifacts"
  shasum -a 256 example.ipa >example.ipa.sha256
)
"$ROOT_DIR/scripts/ios/verify_ipa_checksum.sh" \
  "$checksum_artifacts/example.ipa" \
  "$checksum_artifacts/example.ipa.sha256" >/dev/null

printf '%s\n' \
  "$(shasum -a 256 "$checksum_artifacts/example.ipa" | awk '{print $1}')  $checksum_artifacts/example.ipa" \
  >"$checksum_artifacts/absolute.ipa.sha256"
assert_fails "$ROOT_DIR/scripts/ios/verify_ipa_checksum.sh" \
  "$checksum_artifacts/example.ipa" \
  "$checksum_artifacts/absolute.ipa.sha256"

printf '%s\n' \
  "$(shasum -a 256 "$checksum_artifacts/example.ipa" | awk '{print $1}')  wrong.ipa" \
  >"$checksum_artifacts/wrong-reference.ipa.sha256"
assert_fails "$ROOT_DIR/scripts/ios/verify_ipa_checksum.sh" \
  "$checksum_artifacts/example.ipa" \
  "$checksum_artifacts/wrong-reference.ipa.sha256"

echo 'Packaging negative gates passed'
