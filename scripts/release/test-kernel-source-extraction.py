#!/usr/bin/env python3
"""Preserve authenticated source links without relaxing archive containment."""

import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('kernel_candidate', HERE / 'qualify-kernel-candidate.py')
K = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(K)


class KernelSourceExtractionTests(unittest.TestCase):
    def test_preserves_literal_source_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = '../.././../../../../arch/powerpc/include/asm/asm-compat.h'
            name = 'linux-test/tools/testing/selftests/powerpc/primitives/asm/asm-compat.h'
            member = tarfile.TarInfo(name)
            member.type, member.linkname = tarfile.SYMTYPE, target
            with tarfile.open(root / 'source.tar.xz', 'w:xz') as archive:
                archive.addfile(member)
            K.extract_source(root / 'source.tar.xz', root / 'out', 'linux-test')
            self.assertEqual(os.readlink(root / 'out' / name), target)

    def test_rejects_unsafe_members_and_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'out'
            root.mkdir()
            (root / 'nested').mkdir()
            (root / 'jump').symlink_to('nested')
            cases = [
                ('../escape', tarfile.REGTYPE, ''),
                ('absolute', tarfile.SYMTYPE, '/etc/passwd'),
                ('relative', tarfile.SYMTYPE, '../escape'),
                ('indirect', tarfile.SYMTYPE, 'jump/../../escape'),
                ('hardlink', tarfile.LNKTYPE, '../escape'),
                ('device', tarfile.CHRTYPE, ''),
            ]
            for name, kind, target in cases:
                with self.subTest(name=name):
                    member = tarfile.TarInfo(name)
                    member.type, member.linkname = kind, target
                    with self.assertRaises(tarfile.FilterError):
                        K.source_data_filter(member, root)

    def test_rejects_write_through_escaping_existing_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'out'
            root.mkdir()
            (root / 'jump').symlink_to('..')
            with self.assertRaises(tarfile.OutsideDestinationError):
                K.source_data_filter(tarfile.TarInfo('jump/escape'), root)

    def test_checks_literal_target_when_normalized_target_is_inside(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / 'out'
            root.mkdir()
            (base / 'elsewhere' / 'nested').mkdir(parents=True)
            (root / 'jump').symlink_to('../elsewhere/nested')
            member = tarfile.TarInfo('source-link')
            member.type, member.linkname = tarfile.SYMTYPE, 'jump/../leaf'
            with self.assertRaises(tarfile.LinkOutsideDestinationError):
                K.source_data_filter(member, root)
            # Also cover Python versions that check the normalized target first.
            with mock.patch.object(tarfile, 'data_filter', return_value=member.replace(linkname='leaf')):
                with self.assertRaises(tarfile.LinkOutsideDestinationError):
                    K.source_data_filter(member, root)

    def test_retains_data_filter_permission_and_ownership_guards(self):
        member = tarfile.TarInfo('source')
        member.mode, member.uid, member.gid = 0o6777, 1000, 1000
        with tempfile.TemporaryDirectory() as temporary:
            filtered = K.source_data_filter(member, temporary)
        self.assertEqual(filtered.mode, 0o755)
        self.assertIsNone(filtered.uid)
        self.assertIsNone(filtered.gid)

    def test_checks_version_root_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with tarfile.open(root / 'source.tar.xz', 'w:xz') as archive:
                archive.addfile(tarfile.TarInfo('linux-test/first'), io.BytesIO())
                archive.addfile(tarfile.TarInfo('other/second'), io.BytesIO())
            with self.assertRaisesRegex(ValueError, 'version root'):
                K.extract_source(root / 'source.tar.xz', root / 'out', 'linux-test')
            self.assertFalse((root / 'out').exists())


def verify_pinned_archive(source_archive):
    profile = json.loads(K.PROFILE.read_text())
    pin = next(row for row in profile['downloads'] if row['name'].endswith('.tar.xz'))
    if K.sha(source_archive) != pin['sha256']:
        raise ValueError('Source archive differs from reviewed pin')
    count = links = 0
    with tempfile.TemporaryDirectory(prefix='kernel-source-extraction-') as temporary:
        root = Path(temporary)
        K.extract_source(source_archive, root, 'linux-' + profile['version'])
        with tarfile.open(source_archive, 'r|xz') as archive:
            for member in archive:
                path = root / member.name
                if member.issym():
                    if not path.is_symlink() or os.readlink(path) != member.linkname:
                        raise ValueError('Source symlink changed: ' + member.name)
                    links += 1
                elif member.isfile():
                    if path.is_symlink() or K.sha(path) != hashlib.file_digest(archive.extractfile(member), 'sha256').hexdigest():
                        raise ValueError('Source content changed: ' + member.name)
                    if bool(path.stat().st_mode & 0o111) != bool(member.mode & 0o111):
                        raise ValueError('Source executable mode changed: ' + member.name)
                    count += 1
                elif not member.isdir():
                    raise ValueError('Unexpected source type: ' + member.name)
    print(json.dumps({'sourceSHA256': pin['sha256'], 'regularFilesVerified': count,
                      'literalSymlinksVerified': links}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-archive', type=Path)
    args = parser.parse_args()
    result = unittest.main(argv=[__file__], exit=False).result
    if not result.wasSuccessful():
        raise SystemExit(1)
    if args.source_archive:
        verify_pinned_archive(args.source_archive)
