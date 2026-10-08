"""Validate complete Hostwright XCTest and Swift Testing output."""
import re


def _suite_results(text, expected_suite):
    summaries = re.findall(
        r"Test Suite '(All tests|Selected tests)' (passed|failed)[^\n]*\n[ \t]*"
        r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?",
        text,
    )
    swift = re.findall(r"Test run with (\d+) tests? in \d+ suites? (passed|failed) after", text)
    if len(summaries) != 1 or summaries[0][0] != expected_suite or len(swift) != 1:
        raise ValueError('one complete XCTest and Swift Testing suite result required')
    _, outcome, reported, skipped, failures = summaries[0]
    cases = re.findall(r"^Test Case '[^\n]+' (passed|failed|skipped) \(", text, re.M)
    counts = {status: cases.count(status) for status in ('passed', 'failed', 'skipped')}
    if (int(reported) != len(cases) or int(skipped or 0) != counts['skipped']
            or int(failures) != counts['failed']):
        raise ValueError('XCTest summary and actual case outcomes disagree')
    if outcome != 'passed' or swift[0][1] != 'passed' or counts['failed'] or counts['skipped']:
        raise ValueError('required full suites contain failed or skipped tests')
    if not cases or int(swift[0][0]) <= 0:
        raise ValueError('required full suites contain no executed tests')
    return {'xctestCases': len(cases), 'swiftTestingCases': int(swift[0][0]),
            'passedCases': len(cases) + int(swift[0][0]), 'failedCases': 0, 'skippedCases': 0}


def full_suite_results(text):
    return _suite_results(text, 'All tests')


def sanitizer_base_results(text):
    """Count a selected base; callers must still verify its compiled inventory coverage."""
    return _suite_results(text, 'Selected tests')


def verify_checkpoint_results(checkpoint, text):
    actual = full_suite_results(text)
    if checkpoint.get('fullSuiteResults') != actual:
        raise ValueError('resume refused: incomplete sanitizer suite accounting')
    return actual
