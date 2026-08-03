#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_ENTITLEMENTS="${ENTITLEMENTS_SOURCE:-$ROOT_DIR/scripts/ios/trollstore-entitlements.plist}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/build/ios/artifacts}"
RUN_NUMBER="${RUN_NUMBER:-${GITHUB_RUN_NUMBER:-local}}"
COMMIT_SHA="${COMMIT_SHA:-${GITHUB_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD)}}"
SHORT_SHA="$(printf '%s' "$COMMIT_SHA" | cut -c1-12)"

if [[ -n "${APP_SOURCE:-}" ]]; then
  APP_PATH="$APP_SOURCE"
else
  APP_PATH=""
  for candidate in \
    "$ROOT_DIR/build/ios/iphoneos/Runner.app" \
    "$ROOT_DIR/build/ios/Release-iphoneos/Runner.app"; do
    if [[ -d "$candidate" ]]; then
      APP_PATH="$candidate"
      break
    fi
  done
fi

if [[ -n "${DSYM_SOURCE:-}" ]]; then
  DSYM_PATH="$DSYM_SOURCE"
else
  DSYM_PATH=""
  for candidate in \
    "$ROOT_DIR/build/ios/iphoneos/Runner.app.dSYM" \
    "$ROOT_DIR/build/ios/Release-iphoneos/Runner.app.dSYM"; do
    if [[ -d "$candidate" ]]; then
      DSYM_PATH="$candidate"
      break
    fi
  done
fi

for command_name in ditto file ldid lipo plutil shasum unzip zip; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is missing: $command_name" >&2
    exit 1
  fi
done
if [[ ! -d "$APP_PATH" || ! -d "$DSYM_PATH" ]]; then
  echo "A device Runner.app and dSYM are required" >&2
  echo "app=${APP_PATH:-<missing>}" >&2
  echo "dsym=${DSYM_PATH:-<missing>}" >&2
  exit 1
fi

mkdir -p "$ARTIFACT_DIR"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/emby-ios-core.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
staged_app="$work_dir/Runner.app"
ditto "$APP_PATH" "$staged_app"

preflight_file="$ARTIFACT_DIR/entitlements-preflight.txt"
{
  "$ROOT_DIR/scripts/ios/sync_entitlements.sh" "$work_dir/resolved-entitlements.plist"
  "$ROOT_DIR/scripts/ios/validate_entitlements.sh" "$SOURCE_ENTITLEMENTS"
} | tee "$preflight_file"

if [[ ! -f "$staged_app/Runner" ]]; then
  echo "Staged Runner executable is missing" >&2
  exit 1
fi
plutil -lint "$staged_app/Info.plist"
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$staged_app/Info.plist")"
if [[ "$bundle_id" != "com.jsdfhasuh.embyclient" ]]; then
  echo "Unexpected Bundle ID: $bundle_id" >&2
  exit 1
fi
short_version="$(plutil -extract CFBundleShortVersionString raw -o - "$staged_app/Info.plist")"
build_version="$(plutil -extract CFBundleVersion raw -o - "$staged_app/Info.plist")"
printf 'bundle_id=%s\nshort_version=%s\nbuild_version=%s\n' \
  "$bundle_id" "$short_version" "$build_version" >"$ARTIFACT_DIR/version.txt"

machos_file="$work_dir/machos.txt"
sorted_machos_file="$work_dir/machos-sorted.txt"
paths_file="$work_dir/all-paths"
find "$staged_app" -type f -print0 >"$paths_file"
while IFS= read -r -d '' path; do
  if [[ "$(file -b "$path")" == *Mach-O* ]]; then
    depth="$(printf '%s\n' "$path" | awk -F/ '{print NF}')"
    printf '%08d\t%s\n' "$depth" "$path" >>"$machos_file"
  fi
done <"$paths_file"
if [[ ! -s "$machos_file" ]]; then
  echo "No Mach-O files found in staged application" >&2
  exit 1
fi
sort -rn "$machos_file" >"$sorted_machos_file"

while IFS=$'\t' read -r _ path; do
  echo "fakesign=$path"
  ldid -S"$work_dir/resolved-entitlements.plist" "$path"
done <"$sorted_machos_file"

fakesign_dump_dir="$ARTIFACT_DIR/entitlements-fakesign"
rm -rf "$fakesign_dump_dir"
mkdir -p "$fakesign_dump_dir"
dump_entitlements() {
  local app_dir="$1"
  local destination_dir="$2"
  local list_file="$work_dir/dump-paths"
  local path
  local relative
  local safe_name
  find "$app_dir" -type f -print0 >"$list_file"
  while IFS= read -r -d '' path; do
    if [[ "$(file -b "$path")" == *Mach-O* ]]; then
      relative="${path#"$app_dir"/}"
      safe_name="${relative//\//__}.plist"
      mkdir -p "$destination_dir"
      ldid -e "$path" >"$destination_dir/$safe_name"
      echo "$destination_dir/$safe_name"
    fi
  done <"$list_file"
}

fakesign_dumps="$(dump_entitlements "$staged_app" "$fakesign_dump_dir")"
for dump in $fakesign_dumps; do
  "$ROOT_DIR/scripts/ios/validate_entitlements.sh" "$SOURCE_ENTITLEMENTS" "$dump" >/dev/null
done

architecture_file="$ARTIFACT_DIR/architecture-fakesign.txt"
"$ROOT_DIR/scripts/ios/validate_macho_architectures.sh" "$staged_app" "$architecture_file"

package_dir="$work_dir/package"
mkdir -p "$package_dir/Payload"
ditto "$staged_app" "$package_dir/Payload/Runner.app"
ipa_path="$ARTIFACT_DIR/emby-ios-core-${SHORT_SHA}-${RUN_NUMBER}.ipa"
(cd "$package_dir" && zip -qry "$ipa_path" Payload)
unzip -t "$ipa_path" >/dev/null

final_dir="$work_dir/final"
mkdir -p "$final_dir"
unzip -q "$ipa_path" -d "$final_dir"
final_app="$final_dir/Payload/Runner.app"
if [[ ! -d "$final_app" || ! -f "$final_app/Runner" ]]; then
  echo "IPA does not contain Payload/Runner.app/Runner" >&2
  exit 1
fi
final_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$final_app/Info.plist")"
if [[ "$final_bundle_id" != "$bundle_id" ]]; then
  echo "Bundle ID changed during IPA packaging: $final_bundle_id" >&2
  exit 1
fi

final_dump_dir="$ARTIFACT_DIR/entitlements-final"
rm -rf "$final_dump_dir"
mkdir -p "$final_dump_dir"
final_dumps="$(dump_entitlements "$final_app" "$final_dump_dir")"
for dump in $final_dumps; do
  "$ROOT_DIR/scripts/ios/validate_entitlements.sh" "$SOURCE_ENTITLEMENTS" "$dump" >/dev/null
done
cp "$final_app/Info.plist" "$ARTIFACT_DIR/Info.plist"
final_architecture_file="$ARTIFACT_DIR/architecture-final-ipa.txt"
"$ROOT_DIR/scripts/ios/validate_macho_architectures.sh" "$final_app" "$final_architecture_file"

ipa_sha256="$ipa_path.sha256"
shasum -a 256 "$ipa_path" >"$ipa_sha256"
shasum -a 256 "$SOURCE_ENTITLEMENTS" >"$ARTIFACT_DIR/trollstore-entitlements.plist.sha256"
{
  shasum -a 256 "$ROOT_DIR/pubspec.lock"
  shasum -a 256 "$ROOT_DIR/ios/Podfile.lock"
} >"$ARTIFACT_DIR/lockfiles-sha256.txt"
printf '%s\n' "$COMMIT_SHA" >"$ARTIFACT_DIR/commit-sha.txt"

dsym_zip="$ARTIFACT_DIR/emby-ios-core-${SHORT_SHA}-${RUN_NUMBER}.dSYM.zip"
ditto -c -k --keepParent "$DSYM_PATH" "$dsym_zip"

tool_versions_file="$ARTIFACT_DIR/tool-versions.txt"
{
  echo "flutter=$(flutter --version 2>&1 | head -n 1)"
  echo "flutter_revision=$(git -C "${FLUTTER_ROOT:-$ROOT_DIR}" rev-parse HEAD 2>/dev/null || true)"
  echo "dart=$(dart --version 2>&1)"
  echo "xcode=$(xcodebuild -version 2>&1 | tr '\n' ';')"
  echo "macos=$(sw_vers -productVersion 2>/dev/null || true)"
  echo "ruby=$(ruby --version 2>/dev/null || true)"
  echo "cocoapods=$(bundle exec pod --version 2>/dev/null || true)"
  echo "ldid=$(brew list --versions ldid 2>/dev/null || true)"
} >"$tool_versions_file"

diagnostics_dir="$work_dir/diagnostics"
mkdir -p "$diagnostics_dir/entitlements-fakesign" "$diagnostics_dir/entitlements-final"
ditto "$DSYM_PATH" "$diagnostics_dir/Runner.app.dSYM"
cp "$ARTIFACT_DIR/commit-sha.txt" "$diagnostics_dir/"
cp "$tool_versions_file" "$diagnostics_dir/"
cp "$ROOT_DIR/pubspec.lock" "$diagnostics_dir/"
cp "$ROOT_DIR/ios/Podfile.lock" "$diagnostics_dir/"
cp "$ARTIFACT_DIR/Info.plist" "$diagnostics_dir/"
cp "$SOURCE_ENTITLEMENTS" "$diagnostics_dir/trollstore-entitlements.plist"
cp "$ARTIFACT_DIR/trollstore-entitlements.plist.sha256" "$diagnostics_dir/"
cp "$work_dir/resolved-entitlements.plist" "$diagnostics_dir/"
cp "$preflight_file" "$diagnostics_dir/"
cp "$architecture_file" "$diagnostics_dir/"
cp "$final_architecture_file" "$diagnostics_dir/"
cp "$ipa_sha256" "$diagnostics_dir/"
cp "$ARTIFACT_DIR/lockfiles-sha256.txt" "$diagnostics_dir/"
cp -R "$fakesign_dump_dir/." "$diagnostics_dir/entitlements-fakesign/"
cp -R "$final_dump_dir/." "$diagnostics_dir/entitlements-final/"
diagnostics_zip="$ARTIFACT_DIR/emby-ios-core-diagnostics-${SHORT_SHA}-${RUN_NUMBER}.zip"
(cd "$diagnostics_dir" && zip -qry "$diagnostics_zip" .)

echo "ipa=$ipa_path"
echo "ipa_sha256=$ipa_sha256"
echo "dsym=$dsym_zip"
echo "diagnostics=$diagnostics_zip"
