import unittest
from build_version import build_version


class BuildVersionTest(unittest.TestCase):
    def test_first_version_after_legacy_builds(self):
        values = build_version(179)
        self.assertEqual(values["APP_VERSION_NAME"], "1.0.179")
        self.assertEqual(values["ANDROID_VERSION_CODE"], "1790000")
        self.assertEqual(values["IOS_BUILD_NUMBER"], "179")
        self.assertGreater(int(values["ANDROID_VERSION_CODE"]), 4001)

    def test_next_universal_exceeds_every_previous_abi(self):
        for run in (1, 179, 9999, 209998):
            for offset in (0, 1000, 2000, 4000):
                self.assertGreater(int(build_version(run + 1)["ANDROID_VERSION_CODE"]),
                                   int(build_version(run)["ANDROID_VERSION_CODE"]) + offset)

    def test_bounds(self):
        self.assertLess(int(build_version(209999)["ANDROID_VERSION_CODE"]) + 4000, 2100000000)
        for invalid in (0, -1, 210000):
            with self.assertRaises(ValueError):
                build_version(invalid)


if __name__ == "__main__":
    unittest.main()
