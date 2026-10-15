#!/usr/bin/env python3
"""Validate retained unsigned-builder reports and archive boundaries."""
from pathlib import Path
import hashlib
import importlib.util
import io
import json
import tarfile
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('production_diagnostic', HERE / 'diagnose-production-builder.py')
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class RetainedBuilderOutputs(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.products = M.D.release_products(HERE.parents[1])

    def fixture(self, *, malicious=None, omit=False, tamper=False):
        artifact = 'hostwright-test-arm64'
        data = b'actual-test-fixture-bytes'
        files = [{'path': ('libexec/hostwright/Hostwright.app/Contents/MacOS/hostwright-desktop'
                           if p == 'hostwright-desktop' else 'bin/' + p),
                  'sha256': hashlib.sha256(data).hexdigest(), 'sizeBytes': len(data), 'mode': 0o755}
                 for p in self.products]
        manifest = dict(artifactID=artifact, sourceCommit=M.SOURCE, sourceDirty=False, files=files)
        archive = self.root / 'test.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            for item in files[:-1] if omit else files:
                value = b'x' * len(data) if tamper else data
                member = tarfile.TarInfo(artifact + '/' + item['path'])
                member.size = len(value)
                member.mode = item['mode']
                tar.addfile(member, io.BytesIO(value))
            if malicious:
                member = tarfile.TarInfo(malicious)
                member.size = 1
                tar.addfile(member, io.BytesIO(b'x'))
        report = dict(manifest=manifest, stages=[dict(identifier=n, status='passed') for n in
                      ['release-build', 'archive', 'checksums', 'sbom', 'provenance']],
                      archive=dict(fileName=archive.name, sha256=M.D.sha(archive), sizeBytes=archive.stat().st_size),
                      evidence=dict(failures=[]))
        report['stages'].extend(dict(identifier=n, status='blocked') for n in M.BLOCKED_STAGES)
        (self.root / 'manifest.json').write_text(json.dumps(manifest))
        self.save_report(report)
        return report

    def save_report(self, report):
        (self.root / 'distribution-evidence.json').write_text(json.dumps(report))

    def test_runtime_token_is_scoped_to_authentication_environment(self):
        base = dict(PATH='/usr/bin', LANG='C')
        parent = dict(PATH='/tools:/usr/bin', GH_TOKEN='unit-test-sentinel', SDKROOT='untrusted')
        authenticated = M.runtime_environment(base, parent)
        self.assertEqual(authenticated['GH_TOKEN'], 'unit-test-sentinel')
        self.assertEqual(authenticated['PATH'], parent['PATH'])
        self.assertNotIn('SDKROOT', authenticated)
        self.assertNotIn('GH_TOKEN', base)
        self.assertNotIn('GITHUB_TOKEN', base)

    def test_missing_runtime_token_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'job token'):
            M.runtime_environment(dict(PATH='/usr/bin'), dict(PATH='/tools'))

    def test_all_nine_actual_payloads_are_read_and_hashed(self):
        self.fixture()
        result = M.read_generation(self.root, M.SOURCE, self.products)
        self.assertEqual(set(result['payloads']), set(self.products))
        for item in result['payloads'].values():
            self.assertEqual(M.D.sha(Path(item['file'])), item['sha256'])

    def test_failed_build_stage_is_rejected(self):
        report = self.fixture()
        report['stages'][0]['status'] = 'failed'
        self.save_report(report)
        with self.assertRaisesRegex(ValueError, 'assembly'):
            M.read_generation(self.root, M.SOURCE, self.products)

    def test_changed_embedded_manifest_is_rejected(self):
        report = self.fixture()
        report['manifest']['sourceCommit'] = 'f' * 40
        self.save_report(report)
        with self.assertRaisesRegex(ValueError, 'source'):
            M.read_generation(self.root, M.SOURCE, self.products)

    def test_tampered_archive_is_rejected_before_readback(self):
        self.fixture()
        with (self.root / 'test.tar.gz').open('ab') as stream:
            stream.write(b'tamper')
        with self.assertRaisesRegex(ValueError, 'digest'):
            M.read_generation(self.root, M.SOURCE, self.products)

    def test_native_payload_must_match_manifest_bytes(self):
        self.fixture(tamper=True)
        with self.assertRaisesRegex(ValueError, 'executable differs'):
            M.read_generation(self.root, M.SOURCE, self.products)

    def test_missing_native_payload_is_rejected(self):
        self.fixture(omit=True)
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            M.read_generation(self.root, M.SOURCE, self.products)

    def test_archive_traversal_is_rejected_without_writing_outside_output(self):
        self.fixture(malicious='hostwright-test-arm64/../../outside')
        with self.assertRaisesRegex(ValueError, 'Unsafe assembled archive member'):
            M.read_generation(self.root, M.SOURCE, self.products)
        self.assertFalse((self.root.parent / 'outside').exists())

    def test_archive_descriptor_cannot_escape_output(self):
        report = self.fixture()
        report['archive']['fileName'] = '../test.tar.gz'
        self.save_report(report)
        with self.assertRaisesRegex(ValueError, 'Unsafe archive descriptor'):
            M.read_generation(self.root, M.SOURCE, self.products)


if __name__ == '__main__':
    unittest.main()
