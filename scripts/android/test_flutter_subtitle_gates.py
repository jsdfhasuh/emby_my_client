"""Exercise the real shell wrapper using only an isolated fake Android SDK."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"),
                     "The Linux CI wrapper requires POSIX process signals and bash")
class FlutterSubtitleGateShellTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="subtitle-gates-shell-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        # Normalize checkout line endings, preserving every shell statement.
        self.wrapper = self.root / "repo/scripts/android/run_flutter_subtitle_gates.sh"
        self.wrapper.parent.mkdir(parents=True)
        self.wrapper.write_text(Path(__file__).with_name(
            "run_flutter_subtitle_gates.sh").read_text())
        self.sdk = self.root / "sdk"
        self.trace = self.root / "trace.jsonl"
        self.pid_file = self.root / "emulator.pid"
        self.apk = self.root / "fixture.apk"
        self.apk.write_text("fake APK: never installed or opened")
        self._script(self.sdk / "platform-tools/adb", r'''
import json, os, signal, sys, time
from pathlib import Path
args = sys.argv[1:]
trace = Path(os.environ["FAKE_TRACE"])
with trace.open("a") as output:
    output.write(json.dumps({"kind": "adb", "args": args}) + "\n")
scenario = os.environ["FAKE_SCENARIO"]
if args == ["devices"]:
    print("List of devices attached")
    if scenario == "occupied":
        print("emulator-5558\toffline")
    sys.exit(0)
if args[-3:] == ["shell", "getprop", "sys.boot_completed"]:
    count_file = trace.with_name("probes")
    count = int(count_file.read_text()) + 1 if count_file.exists() else 1
    count_file.write_text(str(count))
    if scenario == "probe-hang" and count == 1:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True:
            time.sleep(1)
    if scenario == "offline" or (scenario == "recovery" and count == 1):
        print("error: device offline", file=sys.stderr)
        sys.exit(1)
    print("1")
    sys.exit(0)
if args[-2:] == ["emu", "kill"]:
    if scenario == "gate-failure-kill-failure":
        sys.exit(1)
    pid_file = Path(os.environ["FAKE_EMULATOR_PID"])
    for _ in range(100):
        if pid_file.exists():
            try:
                os.kill(int(pid_file.read_text()), signal.SIGTERM)
            except ProcessLookupError:
                pass
            sys.exit(0)
        time.sleep(.005)
    sys.exit(2)
sys.exit(97)
''')
        self._script(self.sdk / "emulator/emulator", r'''
import os, signal, time
from pathlib import Path
if os.environ["FAKE_SCENARIO"] == "gate-failure-kill-failure":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(os.environ["FAKE_EMULATOR_PID"]).write_text(str(os.getpid()))
while True:
    time.sleep(1)
''')
        for name in ("sdkmanager", "avdmanager"):
            self._shell(self.sdk / "cmdline-tools/latest/bin" / name, "exit 0\n")
        # Accelerate polling only; GNU timeout and process signals stay real.
        self.bin = self.root / "bin"
        self._shell(self.bin / "sleep", "/bin/sleep 0.001\n")
        self._script(self.bin / "python3", r'''
import json, os, sys
from pathlib import Path
name = Path(sys.argv[1]).name
with open(os.environ["FAKE_TRACE"], "a") as output:
    output.write(json.dumps({"kind": "gate", "name": name}) + "\n")
if os.environ["FAKE_SCENARIO"] == "gate-failure-kill-failure":
    sys.exit(37)
sys.exit(0)
''')

    def _script(self, path, source):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!{sys.executable}\n" + source)
        path.chmod(0o755)

    def _shell(self, path, source):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n" + source)
        path.chmod(0o755)

    @staticmethod
    def _running(pid):
        # A killed orphan can briefly remain a zombie before init reaps it.
        stat = Path(f"/proc/{pid}/stat")
        if stat.exists() and stat.read_text().split()[2] == "Z":
            return False
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    def run_wrapper(self, scenario):
        env = os.environ.copy()
        env.update(ANDROID_SDK_ROOT=str(self.sdk), RUNNER_TEMP=str(self.root),
                   FAKE_TRACE=str(self.trace), FAKE_SCENARIO=scenario,
                   FAKE_EMULATOR_PID=str(self.pid_file),
                   PATH=str(self.bin) + os.pathsep + env["PATH"])
        process = subprocess.Popen(
            ["bash", str(self.wrapper), str(self.apk), str(self.apk)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env=env, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate(timeout=2)
            self.fail(f"Wrapper failed to finish bounded cleanup: {stdout}\n{stderr}")
        finally:
            if self.pid_file.exists():
                pid = int(self.pid_file.read_text())
                if self._running(pid):
                    os.kill(pid, signal.SIGKILL)
                    self.fail("Wrapper left its owned emulator running")
        events = [json.loads(line) for line in self.trace.read_text().splitlines()]
        gates = [event["name"] for event in events if event["kind"] == "gate"]
        probes = sum(event.get("args", [])[-3:] ==
                     ["shell", "getprop", "sys.boot_completed"] for event in events)
        return process.returncode, gates, probes, stderr

    def test_initial_offline_then_ready_runs_both_gates(self):
        code, gates, probes, stderr = self.run_wrapper("recovery")
        self.assertEqual(code, 0, stderr)
        self.assertEqual(probes, 2)
        self.assertEqual(gates, ["run_flutter_subtitle_texture.py", "run_player_route_ui.py"])

    def test_unresponsive_boot_probe_is_killed_and_next_probe_can_boot(self):
        code, gates, probes, stderr = self.run_wrapper("probe-hang")
        self.assertEqual(code, 0, stderr)
        self.assertEqual(probes, 2)
        self.assertEqual(gates, ["run_flutter_subtitle_texture.py", "run_player_route_ui.py"])

    def test_always_offline_exhausts_boot_polling_and_fails(self):
        code, gates, probes, _ = self.run_wrapper("offline")
        self.assertNotEqual(code, 0)
        self.assertGreater(probes, 1, "An offline probe must not trigger errexit")
        self.assertEqual(gates, [])

    def test_failed_adb_kill_reaps_owned_pid_and_keeps_gate_failure(self):
        code, gates, probes, _ = self.run_wrapper("gate-failure-kill-failure")
        self.assertEqual(code, 37, "Cleanup must preserve the first gate's exit status")
        self.assertEqual(probes, 1)
        self.assertEqual(gates, ["run_flutter_subtitle_texture.py"])

    def test_occupied_serial_is_rejected_before_launch(self):
        code, gates, probes, stderr = self.run_wrapper("occupied")
        self.assertEqual(code, 65, stderr)
        self.assertEqual(gates, [])
        self.assertEqual(probes, 0)
        self.assertFalse(self.pid_file.exists())


if __name__ == "__main__":
    unittest.main()
