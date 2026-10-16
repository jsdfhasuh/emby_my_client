"""Header bootstrap tests use isolated generated packages; no Xcode or network."""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

import prepare_media_kit_headers as headers


class HeaderPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mpv-headers-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "locked package"
        self.cache = self.root / "common/darwin/.cache/headers"
        self.cache.mkdir(parents=True)
        self.generated = self.root / "ios/Headers/mpv"
        self.generated.mkdir(parents=True)
        self.config = self.base / "package_config.json"
        self.config.write_text(json.dumps({"packages": [{
            "name": headers.PACKAGE, "rootUri": self.root.as_uri()}]}), encoding="utf-8")
        self.evidence = self.base / "evidence"
        self.bodies = {name: f"// synthetic {name}\n".encode() for name in headers.HEADERS}
        self.bodies["client.h"] += b"typedef struct mpv_node_list mpv_node_list;\n"
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w:gz") as archive:
            for name, body in self.bodies.items():
                entry = tarfile.TarInfo(f"mpv-{headers.MPV_VERSION[1:]}/libmpv/{name}")
                entry.size = len(body)
                archive.addfile(entry, io.BytesIO(body))
        self.archive = data.getvalue()
        self.sha = hashlib.sha256(self.archive).hexdigest()
        patch = mock.patch.object(headers, "ARCHIVE_SHA256", self.sha)
        patch.start()
        self.addCleanup(patch.stop)
        self.pubspec = f"name: {headers.PACKAGE}\nversion: {headers.PACKAGE_VERSION}\n"
        (self.root / "pubspec.yaml").write_text(self.pubspec, encoding="utf-8")
        self.makefile = (f"MPV_HEADERS_VERSION={headers.MPV_VERSION}\n"
                         f"MPV_HEADERS_SHA256SUM={self.sha}\n")
        (self.root / "common/darwin/Makefile").write_text(self.makefile, encoding="utf-8")

    def materialize(self):
        (self.cache / f"mpv-{headers.MPV_VERSION}.tar.gz").write_bytes(self.archive)
        for name, body in self.bodies.items():
            (self.generated / name).write_bytes(body)

    def successful_make(self, root, log):
        self.assertEqual(root, self.root.resolve())
        log.write_bytes(b"upstream make completed\n")
        self.materialize()
        return 0

    def receipt(self):
        return json.loads((self.evidence / "receipt.json").read_text(encoding="utf-8"))

    def test_verified_original_make_outputs_leave_sources_unchanged(self):
        with mock.patch.object(headers, "run_make", side_effect=self.successful_make):
            result = headers.prepare(self.config, self.evidence)
        self.assertEqual(result["status"], "verified")
        self.assertEqual(set(result["headers"]), set(headers.HEADERS))
        self.assertTrue(result["attempts"][0]["headersVerified"])
        self.assertEqual((self.root / "pubspec.yaml").read_text(), self.pubspec)
        self.assertEqual((self.root / "common/darwin/Makefile").read_text(), self.makefile)

    def test_connection_failure_is_preserved_when_second_attempt_succeeds(self):
        def first(root, log):
            log.write_bytes(b"curl: (7) Failed to connect\nmake: Error 7\n")
            (self.cache / "mpv.tar.gz.tmp").write_bytes(b"partial response")
            return 2

        calls = iter((first, self.successful_make))
        with mock.patch.object(headers, "run_make", side_effect=lambda *args: next(calls)(*args)), \
                mock.patch.object(headers.time, "sleep"):
            result = headers.prepare(self.config, self.evidence)
        self.assertEqual([item["exitCode"] for item in result["attempts"]], [2, 0])
        self.assertIn(b"curl: (7)", (self.evidence / "attempt-1.log").read_bytes())
        self.assertEqual((self.evidence / "attempt-1-download.part").read_bytes(), b"partial response")
        self.assertEqual(result["attempts"][0]["partialBytes"], 16)

    def test_permanent_make_failure_stops_after_three_attempts(self):
        def fail(root, log):
            log.write_bytes(b"curl: (7) unavailable\n")
            return 2

        with mock.patch.object(headers, "run_make", side_effect=fail) as make, \
                mock.patch.object(headers.time, "sleep"), \
                self.assertRaisesRegex(RuntimeError, "bounded attempts"):
            headers.prepare(self.config, self.evidence)
        self.assertEqual(make.call_count, 3)
        self.assertEqual(self.receipt()["status"], "failed")
        self.assertEqual(len(list(self.evidence.glob("attempt-*.log"))), 3)
        self.assertFalse((self.generated / "client.h").exists())

    def test_silent_make_success_without_headers_is_rejected(self):
        with mock.patch.object(headers, "run_make", return_value=0) as make, \
                self.assertRaises(FileNotFoundError):
            headers.prepare(self.config, self.evidence)
        make.assert_called_once()
        self.assertEqual(self.receipt()["status"], "failed")

    def test_same_size_archive_corruption_is_not_accepted_or_retried(self):
        self.materialize()
        path = self.cache / f"mpv-{headers.MPV_VERSION}.tar.gz"
        path.write_bytes(b"XX" + self.archive[2:])
        with mock.patch.object(headers, "run_make", return_value=0) as make, \
                self.assertRaisesRegex(ValueError, "checksum mismatch"):
            headers.prepare(self.config, self.evidence)
        make.assert_called_once()
        self.assertEqual(self.receipt()["status"], "failed")

    def test_changed_or_missing_generated_header_is_rejected(self):
        self.materialize()
        (self.generated / "client.h").write_bytes(b"// missing mpv types\n")
        with self.assertRaisesRegex(ValueError, "differs from verified archive"):
            headers.verify_headers(self.root)
        (self.generated / "client.h").unlink()
        with self.assertRaises(FileNotFoundError):
            headers.verify_headers(self.root)

    def test_invalid_archive_is_rejected_even_with_matching_test_checksum(self):
        self.archive = b"not a tar archive"
        with mock.patch.object(headers, "ARCHIVE_SHA256", hashlib.sha256(self.archive).hexdigest()):
            self.materialize()
            with self.assertRaises(tarfile.ReadError):
                headers.verify_headers(self.root)

    def make_pods(self):
        pods = self.base / "Pods"
        public = pods / "Headers/Public/media_kit_video"
        public.mkdir(parents=True)
        for name, body in self.bodies.items():
            (public / name).write_bytes(body)
        umbrella = pods / "Target Support Files/media_kit_video/media_kit_video-umbrella.h"
        umbrella.parent.mkdir(parents=True)
        umbrella.write_text("\n".join(f'#import "{name}"' for name in headers.HEADERS), encoding="utf-8")
        return pods, public, umbrella

    def test_pod_verification_proves_headers_and_umbrella_without_download(self):
        self.materialize()
        pods, _, _ = self.make_pods()
        with mock.patch.object(headers, "run_make") as make:
            result = headers.prepare(self.config, self.evidence, pods=pods)
        make.assert_not_called()
        self.assertTrue(result["podHeadersVerified"])

    def test_pod_install_success_with_missing_public_header_is_rejected(self):
        self.materialize()
        pods, public, _ = self.make_pods()
        (public / "client.h").unlink()
        with self.assertRaises(FileNotFoundError):
            headers.prepare(self.config, self.evidence, pods=pods)
        self.assertEqual(self.receipt()["status"], "failed")

    def test_umbrella_omission_is_rejected_even_when_header_exists(self):
        self.materialize()
        pods, _, umbrella = self.make_pods()
        umbrella.write_text('#import "render.h"\n', encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "umbrella omits.*client.h"):
            headers.verify_pods(self.root, pods)

    def test_version_or_pin_drift_fails_before_running_make(self):
        (self.root / "pubspec.yaml").write_text("version: 2.0.2\n", encoding="utf-8")
        with mock.patch.object(headers, "run_make") as make, \
                self.assertRaisesRegex(ValueError, "fixed package version"):
            headers.prepare(self.config, self.evidence)
        make.assert_not_called()

    def test_previous_failure_receipt_cannot_be_overwritten(self):
        self.evidence.mkdir()
        receipt = self.evidence / "receipt.json"
        receipt.write_text("first failure", encoding="utf-8")
        with self.assertRaises(FileExistsError):
            headers.prepare(self.config, self.evidence)
        self.assertEqual(receipt.read_text(), "first failure")

    def test_make_timeout_terminates_its_owned_process_group(self):
        process = mock.Mock(pid=1234)
        process.wait.side_effect = [subprocess.TimeoutExpired("make", 60), -9]
        with mock.patch.object(headers.subprocess, "Popen", return_value=process), \
                mock.patch.object(headers.os, "name", "posix"), \
                mock.patch.object(headers.signal, "SIGKILL", 9, create=True), \
                mock.patch.object(headers.os, "killpg", create=True) as kill:
            code = headers.run_make(self.root, self.base / "timeout.log")
        self.assertEqual(code, 124)
        kill.assert_called_once_with(1234, 9)


if __name__ == "__main__":
    unittest.main()
