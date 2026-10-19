import unittest
from run_hysteria2_smoke import CHECKS, validate_report


class Hysteria2SmokeTest(unittest.TestCase):
    def test_all_checks_are_required(self):
        report = dict.fromkeys(CHECKS, True)
        validate_report(report)
        for key in CHECKS:
            invalid = {k: v for k, v in report.items() if k != key}
            with self.assertRaises(ValueError):
                validate_report(invalid)

    def test_no_truthy_substitutes_or_extra_fields(self):
        for value in (False, 'true', 1, None):
            invalid = dict.fromkeys(CHECKS, True)
            invalid['jniCore'] = value
            with self.assertRaises(ValueError):
                validate_report(invalid)
        with self.assertRaises(ValueError):
            validate_report(dict(dict.fromkeys(CHECKS, True), unexpected='value'))


if __name__ == '__main__':
    unittest.main()
