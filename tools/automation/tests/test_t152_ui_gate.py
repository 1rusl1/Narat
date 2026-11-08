"""Fixture verification of the acceptance counter; no Simulator invocation."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from t152_ui_gate import ui_summary_ok


class T152UIGateTests(unittest.TestCase):
    def test_requires_all_four_cases_without_failure_or_skip(self):
        good = dict(result='Passed', totalTestCount=4, passedTests=4, failedTests=0, skippedTests=0)
        self.assertTrue(ui_summary_ok(good))
        for key, value in [('result', 'Failed'), ('totalTestCount', 0), ('totalTestCount', 3),
                           ('totalTestCount', 5), ('passedTests', 3), ('failedTests', 1), ('skippedTests', 1)]:
            with self.subTest(key=key, value=value):
                self.assertFalse(ui_summary_ok({**good, key: value}))
        self.assertFalse(ui_summary_ok({}))


if __name__ == '__main__':
    unittest.main()
