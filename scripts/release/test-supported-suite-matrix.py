#!/usr/bin/env python3
"""Exercise qualification coverage and integrity rejection boundaries."""
from pathlib import Path
import importlib.util
import unittest
import tempfile
import json
import subprocess

spec = importlib.util.spec_from_file_location('matrix', Path(__file__).with_name('verify-supported-suite-matrix.py'))
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)

class CoverageTests(unittest.TestCase):
    def test_complete_sanitizer_union(self):
        result = matrix.coverage({'M.C/a', 'M.C/b'}, {'M.S/c()'}, {'M.C/b'}, {'M.C/a': 'passed'}, {'M.S/c()'}, ['M.C/b'], 'address')
        self.assertEqual(result['passedCases'], 3)

    def test_source_skips_count_only_after_actual_execution(self):
        result = matrix.coverage({'M.C/a', 'M.C/b'}, {'M.S/c()'}, {'M.C/b'}, {'M.C/a': 'passed', 'M.C/b': 'skipped'}, {'M.S/c()'}, ['M.C/b'], 'source')
        self.assertEqual(result['skippedCases'], 0)

    def test_missing_attended_case_refused(self):
        with self.assertRaisesRegex(ValueError, 'missing required attended'):
            matrix.coverage({'M.C/a', 'M.C/b'}, {'M.S/c()'}, {'M.C/b'}, {'M.C/a': 'passed'}, {'M.S/c()'}, [], 'address')

    def test_duplicate_attended_case_refused(self):
        with self.assertRaisesRegex(ValueError, 'duplicate attended'):
            matrix.coverage({'M.C/a', 'M.C/b'}, {'M.S/c()'}, {'M.C/b'}, {'M.C/a': 'passed'}, {'M.S/c()'}, ['M.C/b', 'M.C/b'], 'address')

    def test_failed_and_unexpected_skipped_base_refused(self):
        for cases in [{'M.C/a': 'failed'}, {'M.C/a': 'skipped'}]:
            with self.subTest(cases=cases), self.assertRaises(ValueError):
                matrix.coverage({'M.C/a', 'M.C/b'}, {'M.S/c()'}, {'M.C/b'}, cases, {'M.S/c()'}, ['M.C/b'], 'thread')

    def test_missing_swift_testing_identity_refused(self):
        with self.assertRaisesRegex(ValueError, 'Swift Testing coverage'):
            matrix.coverage({'M.C/a', 'M.C/b'}, {'M.S/c()', 'M.S/d()'}, {'M.C/b'}, {'M.C/a': 'passed'}, {'M.S/c()'}, ['M.C/b'], 'address')

    def test_extra_identity_refused(self):
        with self.assertRaisesRegex(ValueError, 'unsupported base'):
            matrix.coverage({'M.C/a', 'M.C/b'}, {'M.S/c()'}, {'M.C/b'}, {'M.C/a': 'passed', 'Other.C/z': 'passed'}, {'M.S/c()'}, ['M.C/b'], 'address')

    def test_partial_base_inventory_refused(self):
        with self.assertRaisesRegex(ValueError, 'incomplete sanitizer base'):
            matrix.coverage({'M.C/a', 'M.C/b', 'M.C/c'}, {'M.S/d()'}, {'M.C/b'}, {'M.C/a': 'passed'}, {'M.S/d()'}, ['M.C/b'], 'address')

    def test_mixed_dirty_failed_and_simulated_binding_refused(self):
        valid = dict(sourceCommit='c', version='v', sourceCleanBefore=True, sourceCleanAfter=True, executionMode='real', exitCode=0, sanitizer='address')
        matrix.binding(valid, 'c', 'v', 'address')
        for key, value in [('sourceCommit', 'other'), ('version', 'old'), ('sourceCleanAfter', False), ('executionMode', 'mock'), ('exitCode', 1), ('sanitizer', 'thread')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                matrix.binding(dict(valid, **{key: value}), 'c', 'v', 'address')

    def test_empty_duplicate_and_single_framework_inventory_refused(self):
        for text in ['', 'M.C/a\nM.C/a\nM.S/b()\n', 'M.C/a\n']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                matrix.inventory(text)

    def test_duplicate_raw_native_results_refused(self):
        with self.assertRaisesRegex(ValueError, 'duplicate executed'):
            matrix.native_cases("Test Case '-[M.C a]' passed (0.1 seconds).\n" * 2)

    def test_failed_skipped_and_duplicate_swift_xml_refused(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'tests.xml'
            for body in ['<failure/>', '<skipped/>', '<error/>']:
                path.write_text('<testsuite><testcase classname="M.S" name="a()">' + body + '</testcase></testsuite>')
                with self.subTest(body=body), self.assertRaises(ValueError):
                    matrix.swift_cases(path)
            path.write_text('<testsuite>' + '<testcase classname="M.S" name="a()"/>' * 2 + '</testsuite>')
            with self.assertRaises(ValueError):
                matrix.swift_cases(path)

    def test_missing_tampered_and_changed_receipt_files_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            log = root / 'raw.log'
            log.write_text('actual raw data')
            receipt = root / 'record.json'
            receipt.write_text(json.dumps({'attachments': {'raw.log': matrix.sha(log)}}))
            descriptor = {'root': str(root), 'receipt': 'record.json', 'receiptSHA256': matrix.sha(receipt)}
            matrix.load_record(descriptor)
            log.write_text('tampered')
            with self.assertRaisesRegex(ValueError, 'raw attachment digest mismatch'):
                matrix.load_record(descriptor)
            log.unlink()
            with self.assertRaisesRegex(ValueError, 'missing or symlinked'):
                matrix.load_record(descriptor)
            receipt.write_text('{}')
            with self.assertRaisesRegex(ValueError, 'receipt digest mismatch'):
                matrix.load_record(descriptor)

    def test_escape_symlink_and_unbound_raw_file_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            log = root / 'raw.log'
            log.write_text('raw')
            (root / 'link.log').symlink_to(log)
            for relative in ['../raw.log', 'link.log']:
                with self.subTest(relative=relative), self.assertRaises(ValueError):
                    matrix.contained(root, relative)
            with self.assertRaisesRegex(ValueError, 'not bound'):
                matrix.bound_attachment(root, {'attachments': {}}, 'raw.log')

    def test_runtime_cleanup_missing_failed_and_unbound_proof_refused(self):
        valid = dict(selector='HostwrightRuntimeTests.LifecycleGate05LiveTests/testAppleCLIConfirmedCreateAndDeleteThroughSecureBoundary', cleanupStatus='passed', unmanagedPreservationStatus='passed', cleanupProofAttachments={'cleanup.json': 'a' * 64}, attachments={'cleanup.json': 'a' * 64})
        matrix.resource_proofs(valid)
        for key, value in [('cleanupStatus', 'failed'), ('unmanagedPreservationStatus', 'blocked'), ('cleanupProofAttachments', {}), ('attachments', {})]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                matrix.resource_proofs(dict(valid, **{key: value}))

    def test_similarly_named_runtime_test_does_not_bypass_cleanup(self):
        with self.assertRaisesRegex(ValueError, 'verified cleanup'):
            matrix.resource_proofs({'selector': 'Other.RegistryAuthenticationTests/runtimeMutation'})

    def test_duplicate_keys_and_nonfinite_json_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'record.json'
            for text in ['{"status":"failed","status":"passed"}', '{"duration":NaN}', '{"duration":Infinity}']:
                path.write_text(text)
                with self.subTest(text=text), self.assertRaises(ValueError):
                    matrix.load_json(path)


class MatrixVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'source'
        self.source.mkdir()
        versions = self.source / 'contracts/v0.0.2/versions.json'
        versions.parent.mkdir(parents=True)
        versions.write_text('{"productVersion":"0.0.2-rc.6"}')
        def git(*args):
            return subprocess.check_output(['git', *args], cwd=self.source, text=True, stderr=subprocess.DEVNULL).strip()
        git('init', '-b', 'fix/qualification-fixture')
        git('add', 'contracts')
        git('-c', 'user.name=Qualification fixtures', '-c', 'user.email=fixtures@example.test', 'commit', '-m', 'test fixture')
        commit = git('rev-parse', 'HEAD')
        self.binary = self.root / 'test-binary'
        self.binary.write_bytes(b'isolated unit fixture, never release evidence')
        compiled = self.root / 'inventory.log'
        compiled.write_text('M.C/a\nM.C/b\nM.S/c()\n')
        evidence = self.root / 'evidence'
        evidence.mkdir()
        (evidence / 'commands.log').write_text(
            "Test Case '-[M.C a]' passed (0.1 seconds).\n"
            "Test Case '-[M.C b]' skipped (0.0 seconds).\n"
            "Test Suite 'All tests' passed at fixture\n"
            "Executed 2 tests, with 1 test skipped and 0 failures\n"
            "Test run with 1 test in 1 suite passed after 0.1 seconds.\n"
        )
        (evidence / 'swift.xml').write_text('<testsuite><testcase classname="M.S" name="c()"/></testsuite>')
        binding = dict(sourceCommit=commit, version='0.0.2-rc.6', executionMode='real',
                       exitCode=0, sourceCleanBefore=True, sourceCleanAfter=True)
        base = dict(binding, status='incomplete', command=['scripts/test.sh', 'full'], failedCases=[],
                    attachments={name: matrix.sha(evidence / name) for name in ['commands.log', 'swift.xml']})
        (evidence / 'base.json').write_text(json.dumps(base))
        (evidence / 'attended.log').write_text("Test Case '-[M.C b]' passed (0.1 seconds).\n")
        (evidence / 'cleanup.json').write_text('{"unitFixture":true}')
        attended = dict(binding, status='passed', binarySHA256=matrix.sha(self.binary), selector='M.C/b',
                        cleanupStatus='passed', unmanagedPreservationStatus='passed',
                        cleanupProofAttachments={'cleanup.json': matrix.sha(evidence / 'cleanup.json')},
                        attachments={name: matrix.sha(evidence / name) for name in ['attended.log', 'cleanup.json']})
        (evidence / 'attended.json').write_text(json.dumps(attended))
        self.config = dict(sourceRoot=str(self.source), sourceCommit=commit, version='0.0.2-rc.6', lane='source',
                           compiledInventory=str(compiled), compiledInventorySHA256=matrix.sha(compiled),
                           binary=str(self.binary), binarySHA256=matrix.sha(self.binary), routedSelectors=['M.C/b'],
                           base={'root': str(evidence), 'receipt': 'base.json', 'receiptSHA256': matrix.sha(evidence / 'base.json')},
                           baseSwiftXML='swift.xml', attended=[{'root': str(evidence), 'receipt': 'attended.json',
                                                            'receiptSHA256': matrix.sha(evidence / 'attended.json'), 'log': 'attended.log'}])

    def test_complete_source_matrix_checks_raw_files_and_inventory(self):
        report = matrix.verify(self.config)
        self.assertEqual(report['counts']['passedCases'], 3)
        self.assertTrue(report['completeSupportedSuite'])
        self.assertFalse(report['protectedQualificationAccepted'])

    def test_complete_verification_refuses_missing_attended_execution(self):
        with self.assertRaisesRegex(ValueError, 'missing required attended'):
            matrix.verify(dict(self.config, attended=[]))

    def test_complete_verification_refuses_changed_executable(self):
        self.binary.write_bytes(b'changed fixture')
        with self.assertRaisesRegex(ValueError, 'executed binary changed'):
            matrix.verify(self.config)

    def test_complete_verification_refuses_dirty_source(self):
        (self.source / 'untracked.txt').write_text('dirty fixture')
        with self.assertRaisesRegex(ValueError, 'current source is dirty'):
            matrix.verify(self.config)

if __name__ == '__main__':
    unittest.main()
