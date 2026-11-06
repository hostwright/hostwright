#!/usr/bin/env python3
"""Checkpoint recipe boundaries and immutable producer selection regressions."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), HERE / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RECIPE = load('sdk-build-recipe')
RESOLVE = load('resolve-sdk-checkpoint')


class SDKInputRoutingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.records = self.root / 'swift-sdk-records'
        self.records.mkdir()
        for name in ('recovery.json', 'swift-static-sdk.tar.gz', 'sdk-reuse.json'):
            (self.records / name).write_text(name + '\n')
        self.original = b'{"commit":"original-sdk-producer"}\n'
        (self.records / 'sdk-producer.json').write_bytes(self.original)
        import hashlib
        (self.records / 'checksums.sha256').write_text(''.join(
            hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n'
            for path in sorted(self.records.iterdir())))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        logger = self.bin / 'python3'
        logger.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$SDK_TEST_CALLS"\n')
        logger.chmod(0o755)
        if not shutil.which('sha256sum'):
            shasum = shutil.which('shasum')
            if not shasum:
                self.skipTest('a real SHA-256 checker is required')
            checker = self.bin / 'sha256sum'
            checker.write_text('#!/bin/sh\nexec "' + shasum + '" -a 256 "$@"\n')
            checker.chmod(0o755)
        workflow = (ROOT / RECIPE.WORKFLOW).read_text()
        step = workflow.split('      - name: Verify the source-built SDK attestation\n', 1)[1]
        self.script = textwrap.dedent(step.split('        run: |\n', 1)[1].split('\n      - name:', 1)[0])

    def run_step(self, kind='native-sdk-subset', issuer=None):
        import os
        source = 'a' * 40
        env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                   SDK_TEST_CALLS=str(self.root / 'calls'), RUNNER_TEMP=str(self.root),
                   GITHUB_WORKSPACE=str(ROOT), GITHUB_SHA=source,
                   SDK_INPUT_KIND=kind, SDK_PRODUCER_COMMIT=issuer or source,
                   SDK_PRODUCER_RUN='123', SDK_PRODUCER_ATTEMPT='2')
        return subprocess.run(['bash', '-c', self.script], env=env, capture_output=True, text=True)

    def test_partial_sdk_authenticates_exact_issuer_and_preserves_original_metadata(self):
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / 'calls').read_text().splitlines()
        self.assertEqual(len(calls), 4)
        for row in calls[:3]:
            self.assertIn('authenticate-runtime-subject.py', row)
            self.assertIn('--source-commit ' + 'a' * 40 + ' --run-id 123 --attempt 2', row)
        self.assertIn('prepare-sdk-native-carrier.py --verify ', calls[3])
        self.assertNotIn('verify-sdk-reuse.py', '\n'.join(calls))
        self.assertEqual((self.root / 'sdk-producer.json').read_bytes(), self.original)

    def test_partial_sdk_rejects_changed_transport_bytes(self):
        (self.records / 'recovery.json').write_text('changed\n')
        result = self.run_step()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('--verify ', (self.root / 'calls').read_text())

    def test_partial_sdk_rejects_wrong_current_issuer_and_unknown_kind(self):
        for kind, issuer in [('native-sdk-subset', 'b' * 40), ('unknown', None)]:
            with self.subTest(kind=kind):
                self.assertNotEqual(self.run_step(kind, issuer).returncode, 0)
                self.assertFalse((self.root / 'calls').exists())


class BuildRecipeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in (*RECIPE.FILES, RECIPE.WORKFLOW):
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, destination)
        shutil.copytree(ROOT / 'scripts/release/patches/swift-sdk',
                        self.root / 'scripts/release/patches/swift-sdk')
        self.before = RECIPE.fingerprint(self.root)

    def test_evidence_only_changes_keep_the_build_recipe(self):
        workflow = self.root / RECIPE.WORKFLOW
        text = workflow.read_text().replace('Collect and verify SDK source evidence without recompiling',
                                             'Collect repaired SDK source evidence')
        workflow.write_text(text)
        (self.root / 'scripts/release/capture-sdk-object-sources.py').write_text('changed evidence reader\n')
        self.assertEqual(RECIPE.fingerprint(self.root), self.before)

    def test_bootstrap_checkpoint_evidence_stays_after_the_compilation_boundary(self):
        workflow = self.root / RECIPE.WORKFLOW
        text = workflow.read_text()
        before, after = text.split(RECIPE.CHECKPOINT_STEP, 1)
        self.assertNotIn("--bootstrap-headers", before)
        self.assertIn("--bootstrap-headers \\\n", after)
        self.assertIn("--bootstrap-headers /workspace/bootstrap", after)
        self.assertIn("checkpoint-index.json\" /workspace/records/checkpoint-index.json", after)
        workflow.write_text(before + RECIPE.CHECKPOINT_STEP + after.replace("--bootstrap-headers", "--future-header-evidence"))
        self.assertEqual(RECIPE.fingerprint(self.root), self.before)

    def test_actual_build_inputs_invalidate_reuse(self):
        paths = list(RECIPE.FILES)
        paths.append(next((self.root / 'scripts/release/patches/swift-sdk').glob('*.patch')).relative_to(self.root).as_posix())
        for name in paths:
            with self.subTest(input=name):
                path = self.root / name
                original = path.read_bytes()
                path.write_bytes(original + b'\nchanged input\n')
                self.assertNotEqual(RECIPE.fingerprint(self.root), self.before)
                path.write_bytes(original)
        workflow = self.root / RECIPE.WORKFLOW
        original = workflow.read_text()
        for previous, replacement in [('swiftly install --assume-yes 6.3.0', 'swiftly install --assume-yes 6.4.0'),
                                      ('runs-on: ubuntu-24.04-arm', 'runs-on: ubuntu-26.04-arm'),
                                      ('permissions: {}', 'permissions: {contents: read}')]:
            with self.subTest(input=previous):
                self.assertIn(previous, original)
                workflow.write_text(original.replace(previous, replacement, 1))
                self.assertNotEqual(RECIPE.fingerprint(self.root), self.before)
        workflow.write_text(original)

    def test_missing_boundary_and_symlink_inputs_are_refused(self):
        path = self.root / RECIPE.WORKFLOW
        original = path.read_text()
        path.write_text(original.replace(RECIPE.CHECKPOINT_STEP, ''))
        with self.assertRaisesRegex(ValueError, 'boundary'):
            RECIPE.fingerprint(self.root)
        path.write_text(original)
        script = self.root / RECIPE.FILES[0]
        script.unlink()
        script.symlink_to(ROOT / RECIPE.FILES[0])
        with self.assertRaisesRegex(ValueError, 'unsafe'):
            RECIPE.fingerprint(self.root)


class ProducerSelectionTests(unittest.TestCase):
    def setUp(self):
        self.source = 'a' * 40
        self.env = dict(GITHUB_REPOSITORY='hostwright/hostwright', GITHUB_RUN_ID='123',
                        GITHUB_RUN_ATTEMPT='2', GITHUB_SHA=self.source, BUILT_ATTEMPT='1')
        self.run = dict(id=100, repository={'full_name': 'hostwright/hostwright'},
                        path='.github/workflows/runtime-ingredients.yml', head_branch='main',
                        event='workflow_dispatch', run_attempt=3, head_sha='b' * 40)

    def test_failed_job_retry_uses_successful_original_build_attempt(self):
        with mock.patch.object(RESOLVE.subprocess, 'run') as api:
            result = RESOLVE.resolve(self.env)
        api.assert_not_called()
        self.assertEqual(result['producer-attempt'], '1')
        self.assertEqual(result['artifact-name'], f'runtime-swift-sdk-checkpoint-{self.source}-123-1')

    def resolve_reuse(self, run=None, artifacts=None):
        env = dict(self.env, REUSE_RUN='100', REUSE_ATTEMPT='1')
        if artifacts is None:
            artifacts = [{'name': 'runtime-swift-sdk-' + 'b' * 40 + '-100-1', 'expired': False}]
        responses = [subprocess.CompletedProcess([], 0, stdout=json.dumps(self.run if run is None else run)),
                     subprocess.CompletedProcess([], 0, stdout=json.dumps([{'artifacts': artifacts}]))]
        with mock.patch.object(RESOLVE.subprocess, 'run', side_effect=responses) as api:
            result = RESOLVE.resolve(env)
        self.assertEqual(api.call_args_list[0].args[0], ['gh', 'api', 'repos/hostwright/hostwright/actions/runs/100'])
        return result

    def test_existing_sdk_is_preferred_and_checkpoint_is_the_fallback(self):
        self.assertEqual(self.resolve_reuse()['artifact-kind'], 'sdk')
        checkpoint = {'name': 'runtime-swift-sdk-checkpoint-' + 'b' * 40 + '-100-1', 'expired': False}
        self.assertEqual(self.resolve_reuse(artifacts=[checkpoint])['artifact-kind'], 'checkpoint')
        for artifacts in [[], [dict(checkpoint, expired=True)], [checkpoint, checkpoint],
                          [dict(checkpoint, name=checkpoint['name'].replace('-100-1', '-100-2'))]]:
            with self.subTest(artifacts=artifacts), self.assertRaises(ValueError):
                self.resolve_reuse(artifacts=artifacts)

    def test_explicit_reuse_preserves_old_producer_identity(self):
        result = self.resolve_reuse()
        self.assertEqual(result['source-commit'], 'b' * 40)
        self.assertEqual(result['producer-attempt'], '1')
        self.assertEqual(result['run-id'], '100')

    def test_wrong_workflow_identity_or_attempt_refused(self):
        for key, value in [('id', 101), ('repository', {'full_name': 'elsewhere/hostwright'}),
                           ('path', '.github/workflows/ci.yml'), ('head_branch', 'feature'),
                           ('event', 'pull_request'), ('run_attempt', 0), ('head_sha', 'bad')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.resolve_reuse(dict(self.run, **{key: value}))
        for values in [dict(REUSE_RUN='100'), dict(REUSE_ATTEMPT='1'),
                       dict(REUSE_RUN='100;echo bad', REUSE_ATTEMPT='1'),
                       dict(BUILT_ATTEMPT='0'), dict(GITHUB_REPOSITORY='elsewhere/hostwright')]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                RESOLVE.resolve(dict(self.env, **values))


if __name__ == '__main__':
    unittest.main()
