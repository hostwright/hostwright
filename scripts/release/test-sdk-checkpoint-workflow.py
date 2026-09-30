#!/usr/bin/env python3
"""Checkpoint recipe boundaries and immutable producer selection regressions."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
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
