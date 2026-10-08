#!/usr/bin/env python3
"""Cask input-boundary tests; fixtures do not constitute release qualification."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('homebrew_cask', Path(__file__).with_name('render-homebrew-cask.py'))
cask = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cask)

COMMIT = 'a' * 40
TEAM = 'TESTTEAM01'


def fixture(version='0.0.2'):
    return dict(schemaVersion=3, sourceDirty=False, sourceCommit=COMMIT,
                packageVersion=version, releaseTag='v' + version, platform='macos',
                architecture='arm64', minimumMacOSMajorVersion=26,
                applicationSigner=dict(teamIdentifier=TEAM), installerSigner=dict(teamIdentifier=TEAM),
                payloadFiles=[dict(path=path) for path in sorted(cask.REQUIRED_PAYLOAD)],
                package=dict(fileName=f'hostwright-{version}-macos-arm64-{COMMIT[:12]}.pkg',
                             sha256='b' * 64, sizeBytes=123))


def verification(manifest):
    return dict(schemaVersion=1, kind='trustedReleaseVerification', status='passed',
                sourceCommit=manifest['sourceCommit'], packageVersion=manifest['packageVersion'],
                releaseTag=manifest['releaseTag'], package=copy.deepcopy(manifest['package']),
                signerTeamIdentifier=TEAM, verificationCommandCount=10, cleanup=dict(status='succeeded'))


class HomebrewCaskTests(unittest.TestCase):
    def test_stable_and_explicit_rc_have_separate_submission_boundaries(self):
        manifest = fixture()
        self.assertEqual(cask.validate_manifest(manifest, COMMIT, '0.0.2', TEAM), manifest['package'])
        for version in ('0.0.2-rc.1', '0.0.2-rc.99'):
            with self.subTest(version=version):
                with self.assertRaises(ValueError):
                    cask.validate_manifest(fixture(version), COMMIT, version, TEAM)
                cask.validate_manifest(fixture(version), COMMIT, version, TEAM, True)
        for version in ('0.0.2-dev.12', '0.0.2-rc.0', '0.0.2-rc.100', '0.0.3', '#{system("id")}'):
            with self.subTest(version=version), self.assertRaises(ValueError):
                cask.validate_manifest(fixture(version), COMMIT, version, TEAM, True)

    def test_rejects_wrong_source_signer_platform_or_dirty_payload(self):
        original = fixture()
        changes = [('sourceCommit', 'c' * 40), ('releaseTag', 'v0.0.2-rc.6'),
                   ('sourceDirty', True), ('schemaVersion', 1), ('platform', 'linux'),
                   ('architecture', 'x86_64'), ('minimumMacOSMajorVersion', 25),
                   ('applicationSigner', dict(teamIdentifier='OTHERTEAM1')),
                   ('installerSigner', dict(teamIdentifier='OTHERTEAM1'))]
        for key, value in changes:
            with self.subTest(field=key), self.assertRaises(ValueError):
                cask.validate_manifest(dict(original, **{key: value}), COMMIT, '0.0.2', TEAM)
        for commit in ('0' * 40, 'a' * 39, 'a' * 39 + '"'):
            with self.subTest(commit=commit), self.assertRaises(ValueError):
                cask.validate_manifest(original, commit, '0.0.2', TEAM)

    def test_cli_only_archive_cannot_be_presented_as_native_app_cask(self):
        for path in cask.REQUIRED_PAYLOAD:
            manifest = fixture()
            manifest['payloadFiles'] = [item for item in manifest['payloadFiles'] if item['path'] != path]
            with self.subTest(path=path), self.assertRaises(ValueError):
                cask.validate_manifest(manifest, COMMIT, '0.0.2', TEAM)
        manifest = fixture()
        manifest['payloadFiles'].append(manifest['payloadFiles'][0])
        with self.assertRaises(ValueError):
            cask.validate_manifest(manifest, COMMIT, '0.0.2', TEAM)

    def test_rejects_filename_injection_unbound_digest_and_invalid_size(self):
        for key, value in [('fileName', '../hostwright.pkg'), ('fileName', '#{system("id")}.pkg'),
                           ('fileName', 'hostwright-0.0.2-macos-arm64-cccccccccccc.pkg'),
                           ('sha256', '0' * 64), ('sha256', ':no_check'),
                           ('sizeBytes', 0), ('sizeBytes', True)]:
            manifest = fixture()
            manifest['package'][key] = value
            with self.subTest(field=key, value=value), self.assertRaises(ValueError):
                cask.validate_manifest(manifest, COMMIT, '0.0.2', TEAM)

    def test_verification_requires_exact_release_signer_and_successful_cleanup(self):
        manifest = fixture()
        original = verification(manifest)
        cask.validate_verification(original, manifest, TEAM)
        for key, value in [('status', 'failed'), ('kind', 'developerDistribution'),
                           ('schemaVersion', 2), ('sourceCommit', 'c' * 40),
                           ('packageVersion', '0.0.2-rc.6'), ('releaseTag', 'v0.0.2-rc.6'),
                           ('signerTeamIdentifier', 'OTHERTEAM1'), ('verificationCommandCount', 0),
                           ('verificationCommandCount', True), ('cleanup', dict(status='failed')),
                           ('cleanup', dict(status='not-required')),
                           ('package', dict(manifest['package'], sha256='c' * 64))]:
            with self.subTest(field=key), self.assertRaises(ValueError):
                cask.validate_verification(dict(original, **{key: value}), manifest, TEAM)

    def test_generated_cask_is_valid_ruby(self):
        for version in ('0.0.2', '0.0.2-rc.6'):
            manifest = fixture(version)
            cask.validate_manifest(manifest, COMMIT, version, TEAM, True)
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'hostwright.rb'
                path.write_text(cask.render(manifest))
                result = subprocess.run(['/usr/bin/ruby', '-c', str(path)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_generation_preserves_existing_files_and_immutable_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            release = root / 'release'
            release.mkdir()
            verifier = Path('/usr/bin/false').resolve()
            existing = root / 'hostwright.rb'
            existing.write_text('retain this recipe')
            for output in (existing, release / 'hostwright.rb'):
                with self.subTest(output=output), self.assertRaises(ValueError):
                    cask.generate(release, verifier, COMMIT, '0.0.2', TEAM, output)
            self.assertEqual(existing.read_text(), 'retain this recipe')
            self.assertEqual(list(release.iterdir()), [])
            links = root / 'links'
            links.mkdir()
            linked_output = links / 'hostwright.rb'
            linked_output.symlink_to(root / 'missing.rb')
            with self.assertRaises(ValueError):
                cask.generate(release, verifier, COMMIT, '0.0.2', TEAM, linked_output)
            self.assertTrue(linked_output.is_symlink())
            self.assertFalse((root / 'missing.rb').exists())

    def test_verifier_failure_or_non_json_success_cannot_emit_recipe(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            release = root / 'release'
            release.mkdir()
            manifest = release / 'release-manifest.json'
            manifest.write_text(json.dumps(fixture()))
            original = manifest.read_bytes()
            output = root / 'hostwright.rb'
            for executable, error in (('/usr/bin/false', subprocess.CalledProcessError),
                                      ('/usr/bin/true', json.JSONDecodeError)):
                with self.subTest(executable=executable), self.assertRaises(error):
                    cask.generate(release, Path(executable).resolve(), COMMIT, '0.0.2', TEAM, output)
                self.assertFalse(output.exists())
                self.assertEqual(manifest.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
