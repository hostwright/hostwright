#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('scope', Path(__file__).with_name('ci-check-scope.py'))
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)


class CheckScopeTests(unittest.TestCase):
    def test_native_reuse_and_documentation_changes_use_targeted_regressions(self):
        self.assertEqual(scope.choose(sorted(scope.NATIVE_REUSE)), 'native-reuse')
        self.assertEqual(scope.choose(['docs/reference/install.md', *scope.NATIVE_REUSE]), 'native-reuse')
        self.assertEqual(scope.choose(['README.md', 'docs/design/policy.md']), 'docs')

    def test_any_product_dependency_or_unknown_input_keeps_full_regressions(self):
        for path in ('Sources/HostwrightCLI/main.swift', 'Tests/HostwrightCoreTests/test.swift',
                     'Package.swift', 'Package.resolved', 'Guest/HostwrightNetfilter/main.go',
                     'scripts/release/build-runtime-ingredients.sh', 'scripts/test.sh',
                     '.github/workflows/security.yml', 'unknown', ''):
            with self.subTest(path=path):
                self.assertEqual(scope.choose(['scripts/release/native-reuse-inputs.py', path]), 'full')
        self.assertEqual(scope.choose([]), 'full')

    def test_missing_or_unavailable_git_context_runs_full_gate(self):
        for event, base, head in (('schedule', 'a'*40, 'b'*40), ('push', '', 'b'*40),
                                  ('pull_request', '0'*40, 'b'*40), ('push', 'bad', 'b'*40)):
            self.assertEqual(scope.git_scope(event, base, head), 'full')
        with mock.patch.object(scope.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'git')):
            self.assertEqual(scope.git_scope('pull_request', 'a'*40, 'b'*40), 'full')

    def test_codeql_swift_path_selection(self):
        for path in ('Tests/Example.swift', 'fixture.c', 'fixture.h', 'fixture.m', 'fixture.mm',
                     'fixture.modulemap', 'Package.swift', 'Package.resolved', 'Sources/data.json',
                     '.github/workflows/security.yml'):
            with self.subTest(path=path), mock.patch.object(scope, 'changed_paths', return_value=[path]):
                self.assertTrue(scope.codeql_swift('pull_request', '', ''))
        with mock.patch.object(scope, 'changed_paths', return_value=['docs/guide.md', 'Guest/main.go']):
            self.assertFalse(scope.codeql_swift('pull_request', '', ''))

    def test_codeql_swift_runs_outside_prs_and_for_uncertain_diffs(self):
        for event in ('push', 'schedule', 'workflow_dispatch', 'pull_request'):
            self.assertTrue(scope.codeql_swift(event, '', ''))
        with mock.patch.object(scope.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'git')):
            self.assertTrue(scope.codeql_swift('pull_request', 'a'*40, 'b'*40))


if __name__ == '__main__':
    unittest.main()
