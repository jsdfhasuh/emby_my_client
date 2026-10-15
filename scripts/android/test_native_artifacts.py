import hashlib
import tempfile
import unittest
import zipfile
from pathlib import Path
from verify_native_artifacts import verify


class NativeProvenanceTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.apk = Path(self.directory.name) / 'test.apk'
        self.entries = {'lib/x86_64/libmpv.so': b'verified-mpv',
                        'lib/x86_64/libmediakitandroidhelper.so': b'verified-helper'}
        self.expected = {key: hashlib.sha256(value).hexdigest()
                         for key, value in self.entries.items()}

    def write(self, entries):
        with zipfile.ZipFile(self.apk, 'w') as archive:
            for name, data in entries.items():
                archive.writestr(name, data)

    def test_accepts_exact_pair(self):
        self.write(self.entries)
        self.assertEqual(verify(self.apk, self.expected), 2)

    def test_rejects_changed_library(self):
        self.entries['lib/x86_64/libmpv.so'] = b'changed'
        self.write(self.entries)
        with self.assertRaisesRegex(ValueError, 'mismatch'):
            verify(self.apk, self.expected)

    def test_rejects_missing_helper(self):
        del self.entries['lib/x86_64/libmediakitandroidhelper.so']
        self.write(self.entries)
        with self.assertRaisesRegex(ValueError, 'paired'):
            verify(self.apk, self.expected)

    def test_rejects_unrecognized_abi(self):
        self.write({key.replace('x86_64', 'unknown'): value
                    for key, value in self.entries.items()})
        with self.assertRaisesRegex(ValueError, 'mismatch'):
            verify(self.apk, self.expected)

    def test_rejects_empty_apk(self):
        self.write({})
        with self.assertRaisesRegex(ValueError, 'Missing'):
            verify(self.apk, self.expected)


if __name__ == '__main__':
    unittest.main()
