"""Run the synthetic Flutter/JNI/background-engine smoke test on an emulator."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

PACKAGE = 'com.jsdfhasuh.emoemby'
ACTIVITY = PACKAGE + '/com.example.emby_my_client.MainActivity'
CHECKS = {'secureStorage', 'backgroundEngine', 'exclusiveGate', 'jniCore', 'released', 'success'}


def validate_report(report):
    if set(report) != CHECKS or any(report[key] is not True for key in CHECKS):
        raise ValueError('Hysteria2 emulator smoke checks failed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--serial', required=True)
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    parser.add_argument('--adb', default=str(Path(sdk) / 'platform-tools' /
                        ('adb.exe' if os.name == 'nt' else 'adb')) if sdk else 'adb')
    parser.add_argument('--evidence', type=Path, default=Path('build/android/artifacts/hysteria2-smoke'))
    args = parser.parse_args()
    if not args.serial.startswith('emulator-'):
        raise ValueError('This synthetic test only installs on an explicitly selected emulator')
    if not args.apk.is_file():
        raise ValueError('Build the synthetic Hysteria2 harness APK first')

    def adb(*command, binary=False):
        return subprocess.run([args.adb, '-s', args.serial, *command], check=True,
                              capture_output=True, timeout=40, text=not binary,
                              **({} if binary else {'encoding': 'utf-8', 'errors': 'replace'})).stdout

    args.evidence.mkdir(parents=True, exist_ok=True)
    adb('install', '-r', '-t', str(args.apk.resolve()))
    try:
        if int(adb('shell', 'getprop', 'ro.build.version.sdk').strip()) >= 33:
            adb('shell', 'pm', 'grant', PACKAGE, 'android.permission.POST_NOTIFICATIONS')
        adb('shell', 'am', 'force-stop', PACKAGE)
        adb('logcat', '-c')
        adb('shell', 'am', 'start', '-W', '-n', ACTIVITY)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            output = adb('logcat', '-d', '-s', 'flutter:I')
            for line in output.splitlines():
                if 'HY2_SMOKE ' not in line:
                    continue
                report = json.loads(line.split('HY2_SMOKE ', 1)[1])
                # Store only the fixed synthetic checks, not arbitrary device logs.
                (args.evidence / 'report.json').write_text(json.dumps(report, sort_keys=True) + '\n', encoding='utf-8')
                validate_report(report)
                time.sleep(2.2)  # Allow the settings page's status poll to repaint idle.
                (args.evidence / 'settings.png').write_bytes(adb('exec-out', 'screencap', '-p', binary=True))
                print('hysteria2_android_smoke=PASSED ' + json.dumps(report, sort_keys=True))
                return
            time.sleep(1)
        raise RuntimeError('Timed out waiting for synthetic Hysteria2 Android checks')
    finally:
        adb('shell', 'am', 'force-stop', PACKAGE)


if __name__ == '__main__':
    main()
