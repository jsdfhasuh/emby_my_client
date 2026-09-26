#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/emby-ldid-install.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/repo/scripts/ios" "$TEMP_DIR/prefix/bin"
cp "$ROOT_DIR/scripts/ios/"{install_ldid.sh,verify_ldid.sh} "$TEMP_DIR/repo/scripts/ios/"

# A synthetic, hash-locked formula keeps this lifecycle regression offline.
# The production lock and its verification code are not altered.
cat >"$TEMP_DIR/formula.rb" <<'FORMULA'
tag:      "v2.1.5"
revision: "fixture-source"
revision 1
FORMULA
formula_sha="$(shasum -a 256 "$TEMP_DIR/formula.rb" | awk '{print $1}')"
cat >"$TEMP_DIR/repo/scripts/ios/ldid.lock" <<LOCK
LDID_VERSION='2.1.5'
HOMEBREW_CORE_COMMIT='fixture-core'
FORMULA_URL='https://fixture.invalid/ldid.rb'
FORMULA_SHA256='$formula_sha'
FORMULA_REVISION='1'
SOURCE_TAG='v2.1.5'
SOURCE_REVISION='fixture-source'
LOCK

cat >"$TEMP_DIR/prefix/bin/brew" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'tap-new --no-git local/ldid-lock') mkdir -p "$FIXTURE/tap" ;;
  '--repository local/ldid-lock') printf '%s\n' "$FIXTURE/tap" ;;
  'install --formula local/ldid-lock/ldid') touch "$FIXTURE/installed" ;;
  'list --versions ldid')
    [[ -f "$FIXTURE/installed" && -f "$FIXTURE/tap/Formula/ldid.rb" ]] || exit 1
    printf 'ldid %s\n' "${MOCK_LDID_VERSION:-2.1.5_1}"
    ;;
  '--prefix'|'--prefix ldid') printf '%s\n' "$FIXTURE/prefix" ;;
  'untap --force local/ldid-lock') rm -f "$FIXTURE/tap/Formula/ldid.rb" ;;
  *) printf 'Unexpected brew call: %s\n' "$*" >&2; exit 1 ;;
esac
MOCK
cat >"$TEMP_DIR/prefix/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 7 && "$5" == 'https://fixture.invalid/ldid.rb' && "$6" == '--output' ]]
cp "$FIXTURE/formula.rb" "$7"
MOCK
printf '#!/usr/bin/env bash\nexit 0\n' >"$TEMP_DIR/prefix/bin/ldid"
chmod +x "$TEMP_DIR/prefix/bin/"* "$TEMP_DIR/repo/scripts/ios/"*.sh
export FIXTURE="$TEMP_DIR"
export PATH="$TEMP_DIR/prefix/bin:$PATH"

"$TEMP_DIR/repo/scripts/ios/install_ldid.sh" >/dev/null
# This second invocation reproduces the separate workflow step that failed
# after the old installer's EXIT trap removed the owning tap.
"$TEMP_DIR/repo/scripts/ios/verify_ldid.sh" >/dev/null
[[ -f "$TEMP_DIR/tap/Formula/ldid.rb" ]]

if MOCK_LDID_VERSION=9.9.9 "$TEMP_DIR/repo/scripts/ios/verify_ldid.sh" >/dev/null 2>&1; then
  echo 'Wrong ldid version was accepted' >&2
  exit 1
fi
if MOCK_LDID_VERSION=9.9.9 "$TEMP_DIR/repo/scripts/ios/install_ldid.sh" >/dev/null 2>&1; then
  echo 'Invalid installation was accepted' >&2
  exit 1
fi
[[ ! -f "$TEMP_DIR/tap/Formula/ldid.rb" ]]
printf '\nchanged\n' >>"$TEMP_DIR/formula.rb"
if "$TEMP_DIR/repo/scripts/ios/install_ldid.sh" >/dev/null 2>&1; then
  echo 'Changed formula hash was accepted' >&2
  exit 1
fi
echo 'ldid installation lifecycle and rejection gates passed'
