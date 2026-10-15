#!/usr/bin/env python3
"""Check diagnostic source/output boundaries and exact byte comparison."""
from pathlib import Path
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('diagnostic', HERE / 'diagnose-payload-reproducibility.py')
DIAGNOSTIC = importlib.util.module_from_spec(spec)
spec.loader.exec_module(DIAGNOSTIC)


class DiagnosticBoundaries(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def test_output_cannot_overwrite_source_or_existing_files(self):
        source = self.root / 'source'
        source.mkdir()
        for output in [source, source / 'nested', self.root]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                DIAGNOSTIC.validate_output(source, output)
        DIAGNOSTIC.validate_output(source, self.root / 'new-output')

    def test_output_rejects_symlink_parent(self):
        (self.root / 'link').symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            DIAGNOSTIC.validate_output(self.root / 'source', self.root / 'link/output')

    def test_byte_differences_include_trailing_data_and_bound_offsets(self):
        left, right = self.root / 'left', self.root / 'right'
        left.write_bytes(b'a' * 100 + b'xyz')
        right.write_bytes(b'b' * 100)
        result = DIAGNOSTIC.difference_summary(left, right)
        self.assertEqual(result['differentBytes'], 103)
        self.assertEqual(result['firstDifferentOffsets'], list(range(64)))
        self.assertEqual(result['firstBytes'], 103)
        self.assertEqual(result['secondBytes'], 100)
        self.assertEqual(DIAGNOSTIC.difference_summary(left, left)['differentBytes'], 0)

    def test_changed_release_recipe_is_rejected(self):
        path = self.root / 'Sources/HostwrightDistribution/DistributionAssembler.swift'
        path.parent.mkdir(parents=True)
        path.write_text('    static func deterministicReleaseBuildArguments(\nchanged\n    static func evidenceCommand(')
        with self.assertRaisesRegex(ValueError, 'recipe changed'):
            DIAGNOSTIC.recipe(self.root)
        DIAGNOSTIC.recipe(HERE.parents[1])

    def test_release_order_is_bound_to_candidate_source(self):
        products = DIAGNOSTIC.release_products(HERE.parents[1])
        self.assertEqual(len(products), 9)
        self.assertEqual(products[4], DIAGNOSTIC.PRODUCT)
        path = self.root / 'Sources/HostwrightDistribution/DistributionModels.swift'
        path.parent.mkdir(parents=True)
        path.write_text('public static let shippedExecutableNames = [\n        "unreviewed"\n    ]')
        with self.assertRaisesRegex(ValueError, 'order changed'):
            DIAGNOSTIC.release_products(self.root)

    def test_dirty_and_wrong_source_are_rejected(self):
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        (self.root / 'input').write_text('source')
        subprocess.run(['git', '-C', str(self.root), 'add', 'input'], check=True)
        subprocess.run(['git', '-C', str(self.root), '-c', 'user.name=Hostwright Tests', '-c', 'user.email=tests@invalid', 'commit', '-qm', 'baseline'], check=True)
        commit = subprocess.check_output(['git', '-C', str(self.root), 'rev-parse', 'HEAD'], text=True).strip()
        subprocess.run(['git', '-C', str(self.root), 'update-ref', 'refs/remotes/origin/main', commit], check=True)
        DIAGNOSTIC.clean_source(self.root, commit)
        with self.assertRaises(ValueError):
            DIAGNOSTIC.clean_source(self.root, 'f' * 40)
        (self.root / 'input').write_text('dirty')
        with self.assertRaises(ValueError):
            DIAGNOSTIC.clean_source(self.root, commit)

    def run_command(self, code, timeout=5):
        record = dict(commands=[])
        self.record = record
        return DIAGNOSTIC.run_command([sys.executable, '-u', '-c', code], 'probe', source=self.root,
                                      environment=dict(os.environ), output=self.root, record=record, timeout=timeout)

    def test_command_captures_real_output_and_exit(self):
        self.assertEqual(self.run_command('print("captured")'), 'captured\n')
        self.assertEqual(self.record['commands'][0]['exitCode'], 0)
        self.assertFalse(self.record['commands'][0]['processGroupRemaining'])

    def test_command_uses_explicit_cwd_and_accepts_only_selected_exit(self):
        record = dict(commands=[])
        output = DIAGNOSTIC.run_command(
            [sys.executable, '-c', 'import os; print(os.getcwd()); raise SystemExit(69)'],
            'blocked', source=self.root, working_directory=Path('/'),
            accepted_exit_codes=(69,), environment=dict(os.environ), output=self.root, record=record)
        self.assertEqual(output, '/\n')
        self.assertEqual(record['commands'][0]['exitCode'], 69)
        self.assertEqual(record['commands'][0]['workingDirectory'], '/')
        self.assertFalse(record['commands'][0]['processGroupRemaining'])

    def test_command_failure_retains_raw_output(self):
        with self.assertRaisesRegex(RuntimeError, 'command failed'):
            self.run_command('print("before failure"); raise SystemExit(7)')
        self.assertEqual((self.root / 'probe.log').read_text(), 'before failure\n')
        self.assertEqual(self.record['commands'][0]['exitCode'], 7)

    def test_timeout_reaps_owned_process_and_retains_output(self):
        with self.assertRaisesRegex(RuntimeError, 'process-group cleanup'):
            self.run_command('import time; print("before timeout"); time.sleep(30)', timeout=0.2)
        self.assertEqual((self.root / 'probe.log').read_text(), 'before timeout\n')
        command = self.record['commands'][0]
        self.assertEqual(command['cleanupSignals'], ['SIGTERM'])
        self.assertFalse(command['processGroupRemaining'])


if __name__ == '__main__':
    unittest.main()
