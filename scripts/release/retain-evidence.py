#!/usr/bin/env python3
"""Copy an exact task-owned export into the protected workflow artifact directory."""
import argparse
import importlib.util
import json
import pathlib
import re
import shutil

spec = importlib.util.spec_from_file_location('staged', pathlib.Path(__file__).with_name('staged-release.py'))
staged = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staged)

def retain(root, output, expected, commit, version):
    if not re.fullmatch(r'[a-f0-9]{64}', expected) or not re.fullmatch(r'[a-f0-9]{40}', commit):
        raise ValueError('exact export and source digests required')
    staged.version(version)
    inventory_path = root / 'evidence-inventory.json'
    if staged.contained_digest(root, 'evidence-inventory.json') != expected:
        raise ValueError('export inventory digest mismatch')
    inventory = staged.load(inventory_path)
    if set(inventory) != {'kind', 'sourceCommit', 'version', 'files'} or inventory['kind'] != 'hostwright.qualification-export.v1' or inventory['sourceCommit'] != commit or inventory['version'] != version:
        raise ValueError('export source/version mismatch')
    files = inventory['files']
    if not isinstance(files, dict) or not files or not {name + '.json' for name in staged.REQUIRED_GATES}.issubset(files):
        raise ValueError('export requires every gate receipt and raw evidence')
    actual = set()
    for path in root.rglob('*'):
        if path.is_symlink() or (not path.is_file() and not path.is_dir()):
            raise ValueError('unsafe export entry')
        if path.is_file() and path != inventory_path:
            actual.add(path.relative_to(root).as_posix())
    if actual != set(files):
        raise ValueError('export inventory is incomplete')
    for relative, digest in files.items():
        if staged.contained_digest(root, relative) != digest:
            raise ValueError('export file digest mismatch')
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    for relative, digest in files.items():
        target = output / relative
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copyfile(root / relative, target, follow_symlinks=False)
        if staged.contained_digest(output, relative) != digest:
            raise ValueError('export changed while being retained')
    shutil.copyfile(inventory_path, output / 'evidence-inventory.json', follow_symlinks=False)
    if staged.digest(output / 'evidence-inventory.json') != expected:
        raise ValueError('export inventory changed while being retained')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ('sha256', 'commit', 'version'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    root = pathlib.Path('/Volumes/T9/hostwright/v002/qualification-export') / args.sha256
    retain(root, args.output, args.sha256, args.commit, args.version)
