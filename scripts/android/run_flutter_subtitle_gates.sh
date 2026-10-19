#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 || ! -s "$1" || ! -s "$2" ]]; then
  echo 'Usage: run_flutter_subtitle_gates.sh texture.apk player-route.apk [hysteria2.apk]' >&2
  exit 64
fi
texture_apk="$1"
route_apk="$2"
hysteria_apk="${3:-}"
if [[ -n "$hysteria_apk" && ! -s "$hysteria_apk" ]]; then
  echo 'Hysteria2 smoke APK is missing' >&2
  exit 64
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:?}}"
export PATH="$sdk/platform-tools:$PATH"
export ANDROID_SERIAL=emulator-5558
if ! devices="$(timeout --kill-after=1s 5s adb devices)"; then
  echo 'Failed to query the dedicated subtitle emulator serial' >&2
  exit 1
fi
if awk '$1 == "emulator-5558" {found=1} END {exit !found}' <<< "$devices"; then
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
# Only this script's child is signalled; no shared adb server or other emulator
# is stopped. Do not wait on a live process after adb loses the device.
wait_for_emulator_exit() {
  for _ in $(seq 1 50); do
    if ! kill -0 "$emulator_pid" 2>/dev/null; then
      wait "$emulator_pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
  done
  return 1
}
cleanup() {
  local status=$?
  trap - EXIT
  echo "SUBTITLE_EMULATOR_CLEANUP=START status=$status"
  timeout --kill-after=1s 5s adb -s "$ANDROID_SERIAL" emu kill >/dev/null 2>&1 || true
  if ! wait_for_emulator_exit; then
    echo 'SUBTITLE_EMULATOR_CLEANUP=TERM'
    kill -TERM "$emulator_pid" 2>/dev/null || true
    if ! wait_for_emulator_exit; then
      echo 'SUBTITLE_EMULATOR_CLEANUP=KILL'
      kill -KILL "$emulator_pid" 2>/dev/null || true
      if ! wait_for_emulator_exit; then
        echo 'SUBTITLE_EMULATOR_CLEANUP=FAILED owned process did not exit' >&2
        [[ "$status" -ne 0 ]] || status=1
        exit "$status"
      fi
    fi
  fi
  echo "SUBTITLE_EMULATOR_CLEANUP=DONE status=$status"
  exit "$status"
}
trap cleanup EXIT
booted=''
boot_deadline=$((SECONDS + 360))
echo 'SUBTITLE_EMULATOR_BOOT=WAITING serial=emulator-5558'
for _ in $(seq 1 180); do
  if ! kill -0 "$emulator_pid" 2>/dev/null; then
    echo "Subtitle emulator log retained: $RUNNER_TEMP/subtitle-ui-emulator.log" >&2
    exit 1
  fi
  # Offline/not-yet-listed is expected during startup, not an errexit failure.
  if ! booted="$(timeout --kill-after=1s 5s adb -s "$ANDROID_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"; then
    booted=''
  fi
  [[ "$booted" == '1' ]] && break
  [[ "$SECONDS" -lt "$boot_deadline" ]] || break
  sleep 2
done
if [[ "$booted" != '1' ]]; then
  echo 'SUBTITLE_EMULATOR_BOOT=FAILED' >&2
  echo "Subtitle emulator log retained: $RUNNER_TEMP/subtitle-ui-emulator.log" >&2
  exit 1
fi
echo 'SUBTITLE_EMULATOR_BOOT=READY serial=emulator-5558'

python3 "$root/scripts/android/run_flutter_subtitle_texture.py" --serial "$ANDROID_SERIAL" \
  --apk "$texture_apk" --output "$root/build/android/artifacts/subtitle-texture"
python3 "$root/scripts/android/run_player_route_ui.py" --serial "$ANDROID_SERIAL" \
  --apk "$route_apk" --output "$root/build/android/artifacts/player-route"
if [[ -n "$hysteria_apk" ]]; then
  python3 "$root/scripts/android/run_hysteria2_smoke.py" --serial "$ANDROID_SERIAL" \
    --apk "$hysteria_apk" --evidence "$root/build/android/artifacts/hysteria2-smoke"
fi
