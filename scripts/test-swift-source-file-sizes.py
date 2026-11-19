#!/usr/bin/env python3
import pathlib
import subprocess
import sys
import tempfile
import unittest

CHECK = pathlib.Path(__file__).resolve().with_name('check-swift-source-file-sizes.py')


class SwiftSourceFileSizeTests(unittest.TestCase):
    def setUp(self):
        repo = tempfile.TemporaryDirectory()
        self.addCleanup(repo.cleanup)
        self.root = pathlib.Path(repo.name)
        (self.root / 'Sources').mkdir()
        (self.root / 'scripts').mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.test')
        self.source('Existing.swift', 810)
        self.git('add', 'Sources')
        self.git('commit', '-qm', 'Base sources')

    def git(self, *args):
        subprocess.run(['git', *args], cwd=self.root, check=True)

    def source(self, name, lines):
        (self.root / 'Sources' / name).write_text('\n'.join(['// line'] * lines), encoding='utf-8')

    def check(self, *args, require_success=False):
        return subprocess.run([sys.executable, str(CHECK), *args], cwd=self.root,
                              text=True, capture_output=True, check=require_success)

    def test_new_file_over_limit_fails_even_with_refreshed_baseline(self):
        self.source('New.swift', 801)
        self.check('--write-baseline', require_success=True)
        result = self.check('--base', 'HEAD')
        self.assertEqual(result.returncode, 1)
        self.assertIn('Sources/New.swift: 801 lines, maximum 800', result.stdout)

    def test_existing_exception_cannot_grow_even_with_refreshed_baseline(self):
        self.source('Existing.swift', 811)
        self.check('--write-baseline', require_success=True)
        result = self.check('--base', 'HEAD')
        self.assertEqual(result.returncode, 1)
        self.assertIn('Sources/Existing.swift: 811 lines, maximum 810', result.stdout)

    def test_reduction_and_file_at_limit_pass_with_current_baseline(self):
        self.check('--write-baseline', require_success=True)
        self.source('Existing.swift', 809)
        self.source('New.swift', 800)
        self.check('--base', 'HEAD', require_success=True)
        self.source('Existing.swift', 800)
        result = self.check('--base', 'HEAD')
        self.assertEqual(result.returncode, 1)
        self.assertIn('Refresh', result.stdout)
        self.check('--write-baseline', require_success=True)
        self.check('--base', 'HEAD', require_success=True)


if __name__ == '__main__':
    unittest.main()
