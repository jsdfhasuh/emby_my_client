#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 2 || ! -s "$1" || ! -s "$2" ]]; then
  echo 'Usage: run_flutter_subtitle_gates.sh texture.apk player-route.apk' >&2
  exit 64
fi
texture_apk="$1"
route_apk="$2"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:?}}"
export PATH="$sdk/platform-tools:$PATH"
export ANDROID_SERIAL=emulator-5558
if adb devices | awk '$1 == "emulator-5558" {found=1} END {exit !found}'; then
  echo 'Dedicated subtitle emulator serial is already occupied' >&2
  exit 65
fi
"$sdk/cmdline-tools/latest/bin/sdkmanager" --install 'system-images;android-33;google_apis;x86_64'
export ANDROID_AVD_HOME="${RUNNER_TEMP:?}/subtitle-ui-avd"
mkdir -p "$ANDROID_AVD_HOME"
echo no | "$sdk/cmdline-tools/latest/bin/avdmanager" create avd --force \
  --name emby-subtitle-ui --package 'system-images;android-33;google_apis;x86_64'
"$sdk/emulator/emulator" -avd emby-subtitle-ui -port 5558 \
  -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect \
  >"$RUNNER_TEMP/subtitle-ui-emulator.log" 2>&1 &
emulator_pid=$!
cleanup() {
  adb -s "$ANDROID_SERIAL" emu kill >/dev/null 2>&1 || true
  wait "$emulator_pid" 2>/dev/null || true
}
trap cleanup EXIT
booted=''
for _ in $(seq 1 180); do
  if ! kill -0 "$emulator_pid" 2>/dev/null; then
    cat "$RUNNER_TEMP/subtitle-ui-emulator.log" >&2
    exit 1
  fi
  booted="$(adb -s "$ANDROID_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
  [[ "$booted" == '1' ]] && break
  sleep 2
done
[[ "$booted" == '1' ]] || { cat "$RUNNER_TEMP/subtitle-ui-emulator.log" >&2; exit 1; }
python3 "$root/scripts/android/run_flutter_subtitle_texture.py" --serial "$ANDROID_SERIAL" \
  --apk "$texture_apk" --output "$root/build/android/artifacts/subtitle-texture"
python3 "$root/scripts/android/run_player_route_ui.py" --serial "$ANDROID_SERIAL" \
  --apk "$route_apk" --output "$root/build/android/artifacts/player-route"
