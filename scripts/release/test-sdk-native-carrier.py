#!/usr/bin/env python3
import copy
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("sdk_native_carrier", HERE / "prepare-sdk-native-carrier.py")
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)


class SDKNativeCarrierTests(unittest.TestCase):
    def transport_fixture(self):
        (self.root/'one').write_bytes(b'first exact input')
        (self.root/'two').write_bytes(b'second exact input')
        proof = dict(files={name: M.N.file_digest(self.root/name) for name in ('two', 'one')})
        (self.root/'sdk.tar.gz').unlink()
        (self.root/'recovery.json').write_bytes(M.V.canonical(proof))
        (self.root/'checksums.sha256').write_bytes(M.transport_checksums(self.root, proof))
        return proof

    def test_transport_has_exact_sorted_coverage_and_no_self_entry(self):
        proof = self.transport_fixture()
        rows = (self.root/'checksums.sha256').read_text().splitlines()
        self.assertEqual([row.split('  ')[1] for row in rows], ['one', 'recovery.json', 'two'])
        M.verify_transport(self.root, proof)

    def test_transport_rejects_extra_missing_altered_and_noncanonical_files(self):
        proof = self.transport_fixture()
        original = (self.root/'checksums.sha256').read_bytes()
        for mutation in ('extra', 'missing', 'altered', 'reversed', 'duplicate', 'self'):
            with self.subTest(mutation=mutation):
                if mutation == 'extra': (self.root/'unexpected').write_bytes(b'extra')
                elif mutation == 'missing': (self.root/'checksums.sha256').unlink()
                elif mutation == 'altered': (self.root/'one').write_bytes(b'changed')
                elif mutation == 'reversed': (self.root/'checksums.sha256').write_bytes(b'\n'.join(reversed(original.splitlines()))+b'\n')
                elif mutation == 'duplicate': (self.root/'checksums.sha256').write_bytes(original+original.splitlines()[0]+b'\n')
                else: (self.root/'checksums.sha256').write_bytes(original+b'0'*64+b'  checksums.sha256\n')
                with self.assertRaises(ValueError): M.verify_transport(self.root, proof)
                if (self.root/'unexpected').exists(): (self.root/'unexpected').unlink()
                (self.root/'one').write_bytes(b'first exact input')
                (self.root/'checksums.sha256').write_bytes(original)

    def test_resolver_native_carrier_is_explicit_and_requires_successful_original_job(self):
        spec = importlib.util.spec_from_file_location("sdk_resolution", HERE / "resolve-sdk-checkpoint.py")
        resolver = importlib.util.module_from_spec(spec); spec.loader.exec_module(resolver)
        commit = 'a' * 40
        run = dict(id=42, run_attempt=1, repository=dict(full_name=M.N.R.REPO), path=M.N.R.WORKFLOW,
                   head_branch='main', event='workflow_dispatch', head_sha=commit, status='completed', conclusion='success')
        artifact = dict(id=71, name=f'runtime-build-ingredients-{commit}-42-1', expired=False,
                        size_in_bytes=1024, digest='sha256:' + 'b' * 64, workflow_run=dict(id=42, head_sha=commit))
        job = dict(id=81, run_id=42, run_attempt=1, name=M.N.R.JOB, status='completed', conclusion='success')
        def api(argv, **kwargs):
            endpoint = argv[-1]
            if '/artifacts?' in endpoint: value = [dict(artifacts=[artifact])]
            elif '/jobs?' in endpoint: value = [dict(jobs=[job])]
            else: value = run
            raw = json.dumps(value)
            return subprocess.CompletedProcess(argv, 0, raw if kwargs.get('text') else raw.encode(), b'')
        env = dict(REUSE_RUN='42', REUSE_ATTEMPT='1', GITHUB_REPOSITORY=M.N.R.REPO)
        with patch.object(subprocess, 'run', side_effect=api):
            with self.assertRaises(ValueError): resolver.resolve(env)
            env['SDK_CARRIER_RESOLUTION'] = str(self.root / 'resolution.json')
            resolved = resolver.resolve(env)
            self.assertEqual(resolved['artifact-kind'], 'native-sdk-carrier')
            self.assertEqual(resolved['artifact-id'], '71')
            env['SDK_CARRIER_RESOLUTION'] = str(self.root / 'failed.json')
            job['conclusion'] = 'failure'
            with self.assertRaises(ValueError): resolver.resolve(env)
            self.assertFalse((self.root/'failed.json').exists())

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.archive = self.root / "sdk.tar.gz"
        self.member = "sdk.artifactbundle/target/crt1.o"
        self.obj = bytearray(64)
        self.obj[:7] = b'\x7fELF\x02\x01\x01'
        struct.pack_into('<HH', self.obj, 16, 1, 183)
        self.obj = bytes(self.obj)
        self.write_archive([(self.member, self.obj)])
        self.row = dict(objectSHA256=M.V.digest(self.obj), sourceFiles=[dict(project="swift-sdk/musl",
            path="crt/crt1.c", sha256="a" * 64)])
        self.actual = dict(self.row, mapInput=M.ORIGINAL_SDK_ROOT + self.member,
                          file=dict(path="object.o", sha256=M.V.digest(self.obj), sizeBytes=len(self.obj)))
        self.native = dict(oci=dict(links=[dict(selectedInputs=[self.actual])]))

    def write_archive(self, files):
        with tarfile.open(self.archive, 'w:gz') as bundle:
            for name, data in files:
                item = tarfile.TarInfo(name)
                item.size = len(data)
                bundle.addfile(item, io.BytesIO(data))

    def select(self, rows=None):
        return M.select_rows(self.native, rows or [self.row], self.archive, lambda name: (_ for _ in ()).throw(AssertionError(name)))

    def test_recovers_only_real_sdk_member_not_native_header_user(self):
        native = dict(objectSHA256="c" * 64, sourceFiles=[dict(project="containerization", path="main.c", sha256="d" * 64),
                                                        self.row['sourceFiles'][0]])
        self.native['oci']['links'][0]['selectedInputs'].append(dict(native, mapInput="/build/main.o", file={}))
        rows, headers, members = self.select([self.row, native])
        self.assertEqual(rows, [self.row])
        self.assertEqual(headers, [native])
        self.assertEqual(members, [dict(identity=self.member, objectSHA256=self.row['objectSHA256'])])

    def test_rejects_actual_member_hash_and_identity_mismatch(self):
        for change in ('hash', 'identity'):
            with self.subTest(change=change):
                actual = copy.deepcopy(self.actual)
                if change == 'hash':
                    self.write_archive([(self.member, self.obj + b'changed')])
                else:
                    self.native['oci']['links'][0]['selectedInputs'][0]['mapInput'] += 'missing.o'
                with self.assertRaises((ValueError, AssertionError)):
                    self.select()
                self.write_archive([(self.member, self.obj)])
                self.native['oci']['links'][0]['selectedInputs'][0] = actual

    def test_rejects_duplicate_or_symlink_selected_member(self):
        self.write_archive([(self.member, self.obj), (self.member, self.obj)])
        with self.assertRaises((ValueError, AssertionError)):
            self.select()

    def test_exact_archive_internal_alias_resolves_without_host_filesystem(self):
        with tarfile.open(self.archive, 'w:gz') as bundle:
            actual = tarfile.TarInfo('sdk.artifactbundle/actual/crt1.o'); actual.size = len(self.obj)
            bundle.addfile(actual, io.BytesIO(self.obj))
            alias = tarfile.TarInfo('sdk.artifactbundle/target'); alias.type = tarfile.SYMTYPE; alias.linkname = 'actual'
            bundle.addfile(alias)
        self.assertEqual(self.select()[2], [dict(identity=self.member, objectSHA256=M.V.digest(self.obj))])
        for target in ('../../outside', 'target'):
            with self.subTest(target=target):
                with tarfile.open(self.archive, 'w:gz') as bundle:
                    alias = tarfile.TarInfo('sdk.artifactbundle/target'); alias.type = tarfile.SYMTYPE; alias.linkname = target
                    bundle.addfile(alias)
                with self.assertRaises((ValueError, AssertionError)):
                    self.select()
        with tarfile.open(self.archive, 'w:gz') as bundle:
            item = tarfile.TarInfo(self.member); item.type = tarfile.SYMTYPE; item.linkname = '/outside'
            bundle.addfile(item)
        with self.assertRaises((ValueError, AssertionError)):
            self.select()

    def test_rejects_unattributed_or_non_sdk_object(self):
        for change in ('digest', 'source'):
            with self.subTest(change=change):
                row = copy.deepcopy(self.row)
                if change == 'digest': row['objectSHA256'] = '0' * 64
                else: row['sourceFiles'][0]['project'] = 'containerization'
                with self.assertRaises((ValueError, AssertionError)):
                    self.select([row])

    def test_sdk_chain_keeps_original_producer_and_compile_fingerprint(self):
        producer = dict(commit='a' * 40, runID=123, attempt=1)
        carrier = dict(commit='b' * 40, runID=456, attempt=1)
        compile_inputs = dict(sha256='c' * 64, files={'exact': 'd' * 64})
        reuse = dict(kind=M.S.KIND, status='compatible-not-release-qualified', producer=dict(commit=producer['commit']),
                     sourceCommit=carrier['commit'], sourceInventory=dict(projectCount=34, sdkArchiveSHA256='e' * 64),
                     compileInputs=compile_inputs)
        M.validate_sdk_chain(producer, reuse, carrier, 'e' * 64, dict(compileInputs=compile_inputs))
        for field in ('producer', 'sourceCommit', 'compileInputs', 'sourceInventory'):
            changed = copy.deepcopy(reuse)
            changed[field] = {} if field != 'sourceCommit' else 'f' * 40
            with self.subTest(field=field), self.assertRaises((ValueError, AssertionError, KeyError)):
                M.validate_sdk_chain(producer, changed, carrier, 'e' * 64, dict(compileInputs=compile_inputs))

    def test_verification_rejects_wrong_current_source_before_authentication(self):
        (self.root/'recovery.json').write_text(json.dumps(dict(kind=M.KIND,
            status='authenticated-selected-sdk-not-release-qualified', preparedForSource='a' * 40)))
        with patch.object(M.N, 'verify_attestation') as authenticate, self.assertRaises((ValueError, AssertionError)):
            M.verify(self.root, self.root, 'b' * 40)
        authenticate.assert_not_called()


if __name__ == '__main__':
    unittest.main()
