#!/usr/bin/env python3
"""Regression coverage for incomplete sanitizer execution evidence."""
import unittest
from swift_test_results import full_suite_results, verify_checkpoint_results


PASSED = """Test Case '-[CoreTests testOne]' passed (0.001 seconds).
Test Suite 'All tests' passed at 2026-10-05 16:45:56.290.
    Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds
✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.
"""


class FullSuiteResultsTests(unittest.TestCase):
    def testAccountsForBothFrameworks(self):
        result = full_suite_results(PASSED)
        self.assertEqual(result['passedCases'], 3)
        self.assertEqual(result['skippedCases'], 0)

    def testUnaccountedLegacyCheckpointCannotResume(self):
        with self.assertRaisesRegex(ValueError, 'resume refused'):
            verify_checkpoint_results({'status': 'passed'}, PASSED)

    def testChangedCheckpointCountsCannotResume(self):
        result = full_suite_results(PASSED)
        result['passedCases'] += 1
        with self.assertRaisesRegex(ValueError, 'resume refused'):
            verify_checkpoint_results({'fullSuiteResults': result}, PASSED)

    def testExactAccountedCheckpointCanResume(self):
        result = full_suite_results(PASSED)
        self.assertEqual(verify_checkpoint_results({'fullSuiteResults': result}, PASSED), result)

    def testPassingSwiftTestingDoesNotHideSkippedXCTest(self):
        raw = PASSED.replace("testOne]' passed", "testOne]' skipped").replace(
            'with 0 failures', 'with 1 test skipped and 0 failures')
        with self.assertRaisesRegex(ValueError, 'failed or skipped'):
            full_suite_results(raw)

    def testPassingSwiftTestingDoesNotHideFailedXCTest(self):
        raw = PASSED.replace("testOne]' passed", "testOne]' failed").replace(
            "'All tests' passed", "'All tests' failed").replace('with 0 failures', 'with 1 failure')
        with self.assertRaisesRegex(ValueError, 'failed or skipped'):
            full_suite_results(raw)

    def testPassingSwiftTestingDoesNotHideMissingXCTest(self):
        with self.assertRaisesRegex(ValueError, 'one complete'):
            full_suite_results(PASSED.split('✔')[1])

    def testMissingSwiftTestingCannotPass(self):
        with self.assertRaisesRegex(ValueError, 'one complete'):
            full_suite_results(PASSED.split('✔')[0])

    def testChangedCaseCountsCannotPass(self):
        with self.assertRaisesRegex(ValueError, 'outcomes disagree'):
            full_suite_results(PASSED.replace('Executed 1 test', 'Executed 2 tests'))

    def testMixedSuiteRunsCannotPass(self):
        with self.assertRaisesRegex(ValueError, 'one complete'):
            full_suite_results(PASSED + PASSED)

    def testEmptySuccessfulSuitesCannotPass(self):
        raw = PASSED.split('\n', 1)[1].replace('Executed 1 test', 'Executed 0 tests').replace(
            'with 2 tests', 'with 0 tests')
        with self.assertRaisesRegex(ValueError, 'no executed tests'):
            full_suite_results(raw)

    def testFailedSwiftTestingCannotPass(self):
        with self.assertRaisesRegex(ValueError, 'failed or skipped'):
            full_suite_results(PASSED.replace('suite passed after', 'suite failed after'))


if __name__ == '__main__':
    unittest.main()
