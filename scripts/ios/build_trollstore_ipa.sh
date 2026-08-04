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
if [[ ! -f "$SOURCE_ENTITLEMENTS" ]]; then
  echo "Missing entitlement source: $SOURCE_ENTITLEMENTS" >&2
  exit 1
fi
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
  ENTITLEMENTS_SOURCE="$SOURCE_ENTITLEMENTS" \
    "$ROOT_DIR/scripts/ios/sync_entitlements.sh" \
    "$work_dir/resolved-entitlements.plist"
  "$ROOT_DIR/scripts/ios/validate_entitlements.sh" \
    "$SOURCE_ENTITLEMENTS" "$work_dir/resolved-entitlements.plist"
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

appex_path="$(find "$staged_app" -type d -name '*.appex' -print -quit)"
if [[ -n "$appex_path" ]]; then
  echo "Unsupported App Extension found: $appex_path" >&2
  echo "No App Extension entitlement/signing policy is defined for this Core build" >&2
  exit 1
fi

collect_machos() {
  local app_dir="$1"
  local inventory_file="$2"
  local classification_file="$3"
  local paths_file="$4"
  local path
  local relative
  local depth
  local role
  local main_found=false

  : >"$inventory_file"
  : >"$classification_file"
  find "$app_dir" -type f -print0 >"$paths_file"
  while IFS= read -r -d '' path; do
    if [[ "$(file -b "$path")" != *Mach-O* ]]; then
      continue
    fi
    relative="${path#"$app_dir"/}"
    depth="$(printf '%s\n' "$path" | awk -F/ '{print NF}')"
    if [[ "$path" == "$app_dir/Runner" ]]; then
      role='main'
      main_found=true
    else
      role='embedded'
    fi
    printf '%08d\t%s\t%s\n' "$depth" "$role" "$path" >>"$inventory_file"
    printf '%s\t%s\n' "$role" "$relative" >>"$classification_file"
  done <"$paths_file"

  if [[ "$main_found" != true ]]; then
    echo "Runner.app/Runner is not a Mach-O executable" >&2
    exit 1
  fi
  sort -rn "$inventory_file" -o "$inventory_file"
}

inventory_file="$work_dir/machos-sorted.txt"
classification_file="$ARTIFACT_DIR/macho-classification.txt"
collect_machos "$staged_app" "$inventory_file" "$classification_file" \
  "$work_dir/all-paths"

embedded_entitlements="$work_dir/embedded-entitlements.plist"
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict/></plist>' >"$embedded_entitlements"

signing_order_file="$ARTIFACT_DIR/signing-order.txt"
: >"$signing_order_file"
while IFS=$'\t' read -r _ role path; do
  if [[ "$role" == 'main' ]]; then
    continue
  fi
  printf 'embedded\t%s\n' "${path#"$staged_app"/}" >>"$signing_order_file"
  ldid -S"$embedded_entitlements" "$path"
done <"$inventory_file"

printf 'main\tRunner\n' >>"$signing_order_file"
ldid -S"$work_dir/resolved-entitlements.plist" "$staged_app/Runner"

dump_entitlements() {
  local app_dir="$1"
  local destination_dir="$2"
  local list_file="$3"
  local paths_file="$4"
  local path
  local relative
  local safe_name
  local destination

  mkdir -p "$destination_dir/main" "$destination_dir/embedded"
  : >"$list_file"
  find "$app_dir" -type f -print0 >"$paths_file"
  while IFS= read -r -d '' path; do
    if [[ "$(file -b "$path")" != *Mach-O* ]]; then
      continue
    fi
    relative="${path#"$app_dir"/}"
    if [[ "$path" == "$app_dir/Runner" ]]; then
      destination="$destination_dir/main/Runner.plist"
    else
      safe_name="${relative//\//__}"
      destination="$destination_dir/embedded/${safe_name}.plist"
    fi
    ldid -e "$path" >"$destination"
    printf '%s\0' "$destination" >>"$list_file"
  done <"$paths_file"
}

validate_dumps() {
  local list_file="$1"
  local dump
  while IFS= read -r -d '' dump; do
    if [[ "$dump" == */main/* ]]; then
      "$ROOT_DIR/scripts/ios/validate_entitlements.sh" \
        "$SOURCE_ENTITLEMENTS" "$dump" >/dev/null
    else
      "$ROOT_DIR/scripts/ios/validate_embedded_entitlements.sh" "$dump" >/dev/null
    fi
  done <"$list_file"
}

fakesign_dump_dir="$ARTIFACT_DIR/entitlements-fakesign"
rm -rf "$fakesign_dump_dir"
mkdir -p "$fakesign_dump_dir"
dump_entitlements "$staged_app" "$fakesign_dump_dir" \
  "$work_dir/fakesign-dumps" "$work_dir/fakesign-paths"
validate_dumps "$work_dir/fakesign-dumps"

architecture_file="$ARTIFACT_DIR/architecture-fakesign.txt"
"$ROOT_DIR/scripts/ios/validate_macho_architectures.sh" \
  "$staged_app" "$architecture_file"

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
final_appex_path="$(find "$final_app" -type d -name '*.appex' -print -quit)"
if [[ -n "$final_appex_path" ]]; then
  echo "Unsupported App Extension found after IPA packaging: $final_appex_path" >&2
  exit 1
fi

final_classification_file="$ARTIFACT_DIR/macho-classification-final.txt"
collect_machos "$final_app" "$work_dir/final-machos-sorted.txt" \
  "$final_classification_file" "$work_dir/final-all-paths"
final_dump_dir="$ARTIFACT_DIR/entitlements-final"
rm -rf "$final_dump_dir"
mkdir -p "$final_dump_dir"
dump_entitlements "$final_app" "$final_dump_dir" \
  "$work_dir/final-dumps" "$work_dir/final-paths"
validate_dumps "$work_dir/final-dumps"
cp "$final_app/Info.plist" "$ARTIFACT_DIR/Info.plist"
final_architecture_file="$ARTIFACT_DIR/architecture-final-ipa.txt"
"$ROOT_DIR/scripts/ios/validate_macho_architectures.sh" \
  "$final_app" "$final_architecture_file"

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
cp "$ARTIFACT_DIR/macho-classification.txt" "$diagnostics_dir/"
cp "$ARTIFACT_DIR/macho-classification-final.txt" "$diagnostics_dir/"
cp "$ARTIFACT_DIR/signing-order.txt" "$diagnostics_dir/"
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
