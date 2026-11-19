#!/usr/bin/env python3
"""Exact staged inventory and aggregate receipt boundary (authentication is external)."""
import argparse
import importlib.util
import sys
import hashlib
import json
import pathlib
import re

source_spec=importlib.util.spec_from_file_location('hostwright_source_stage',pathlib.Path(__file__).with_name('stage-corresponding-source.py'))
source_stage=sys.modules.get('hostwright_source_stage')
if source_stage is None:
    source_stage=importlib.util.module_from_spec(source_spec)
    sys.modules['hostwright_source_stage']=source_stage
    source_spec.loader.exec_module(source_stage)

QUALIFICATION_POLICY = 'hostwright.v0.0.2.focused.v1'
REQUIRED_GATES = {'source', 'artifact-integrity', 'installation', 'working-product', 'documentation'}

def digest(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'unsafe input: {path}')
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1048576), b''):
            result.update(chunk)
    return result.hexdigest()

def contained_digest(root, relative):
    relative = pathlib.PurePosixPath(relative)
    if relative.is_absolute() or not relative.parts or '..' in relative.parts:
        raise ValueError('attachment must remain inside evidence directory')
    path = root
    if root.is_symlink() or not root.is_dir():
        raise ValueError('unsafe evidence directory')
    for part in relative.parts:
        path = path / part
        if path.is_symlink():
            raise ValueError('symlink in evidence attachment path')
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError('attachment escapes evidence directory')
    return digest(path)

def load(path, expected_sha256=None):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError(f'duplicate JSON key: {key}')
            result[key] = value
        return result
    digest(path)
    data = path.read_bytes()
    if expected_sha256 is not None and hashlib.sha256(data).hexdigest() != expected_sha256:
        raise ValueError('JSON changed between binding and parsing')
    def invalid_constant(value):
        raise ValueError('non-finite JSON value: ' + value)
    return json.loads(data.decode('utf-8'), object_pairs_hook=pairs, parse_constant=invalid_constant)

def version(value):
    if value == '0.0.2':
        return value
    match = re.fullmatch(r'0\.0\.2-(dev|rc)\.([1-9][0-9]*)', value)
    if not match or not (1 <= int(match[2]) <= (999 if match[1] == 'dev' else 99)):
        raise ValueError('release version must be dev.1..999, rc.1..99, or stable 0.0.2')
    return value

def inventory(root, commit, release_version, run, attempt):
    if not re.fullmatch('[a-f0-9]{40}', commit) or commit == '0' * 40:
        raise ValueError('invalid source commit')
    version(release_version)
    if not re.fullmatch('[1-9][0-9]*', run) or not re.fullmatch('[1-9][0-9]*', attempt):
        raise ValueError('invalid build run identity')
    manifest = load(root / 'release/release-manifest.json')
    if (manifest['sourceCommit'], manifest['packageVersion'], manifest['releaseTag']) != (commit, release_version, 'v' + release_version):
        raise ValueError('staged manifest source/version/tag mismatch')
    files = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError('symlink in staged inventory')
        if path.is_dir() and str(path.relative_to(root)) not in {'release', 'Formula', 'source'}:
            raise ValueError('unexpected directory in staged inventory')
        if path.is_file() and path != root / 'stage-inventory.json':
            files[str(path.relative_to(root))] = digest(path)
        elif not path.is_dir() and not path.is_file():
            raise ValueError('special file in staged inventory')
    expected = {'release/' + name for name in (
        'release-manifest.json', 'release-manifest.json.cms', 'SHA256SUMS', 'SHA256SUMS.cms',
        'provenance.intoto.json', 'provenance.intoto.json.cms', 'release-evidence.json',
        'release-evidence.json.cms',
    )} | {'release/' + manifest[key]['fileName'] for key in ('archive', 'package', 'archiveSBOM', 'packageSBOM')} | {'Formula/hostwright.rb'}
    source=source_stage.descriptor(root,commit,release_version)
    expected|={'source/'+source[key]['fileName'] for key in ('archive','manifest','checksums')}
    if set(files) != expected:
        raise ValueError('unexpected staged asset inventory')
    for key in ('archive', 'package', 'archiveSBOM', 'packageSBOM'):
        item = manifest[key]
        if files['release/' + item['fileName']] != item['sha256']:
            raise ValueError('manifest asset digest mismatch')
    return dict(kind='hostwright.stage-inventory.v2', sourceCommit=commit, version=release_version,
                buildRunID=run, buildRunAttempt=attempt, files=files, correspondingSource=source)

def verify_published(receipt, release, tag_ref, tag_object, commit, release_version, qualification_run):
    tag = 'v' + version(release_version)
    if not re.fullmatch('[a-f0-9]{40}', commit) or commit == '0' * 40:
        raise ValueError('invalid source commit')
    if not re.fullmatch('[1-9][0-9]*', qualification_run):
        raise ValueError('invalid qualification run ID')
    binding = dict(kind='hostwright.promotion-receipt.v3', qualificationPolicy=QUALIFICATION_POLICY,
                   acceptanceRunID=qualification_run, sourceCommit=commit, version=release_version)
    if any(receipt.get(key) != value for key, value in binding.items()):
        raise ValueError('accepted inventory does not match the selected release')

    ref = tag_ref['object']
    target = tag_object['object']
    if (tag_ref['ref'] != 'refs/tags/' + tag or ref['type'] != 'tag'
            or ref['sha'] != tag_object['sha'] or tag_object['tag'] != tag
            or target['type'] != 'commit' or target['sha'] != commit):
        raise ValueError('annotated version tag does not resolve to the accepted source')
    if (release['tag_name'] != tag or release['target_commitish'] != commit
            or release['draft'] is not False or not release['published_at']
            or release['prerelease'] is not (release_version != '0.0.2')):
        raise ValueError('public release identity or channel differs')

    expected = {}
    for relative, sha256 in receipt['files'].items():
        if (not re.fullmatch(r'(?:release|Formula|source)/[A-Za-z0-9_.-]+', relative)
                or not re.fullmatch('[a-f0-9]{64}', sha256)):
            raise ValueError('invalid file in accepted inventory')
        name = pathlib.PurePosixPath(relative).name
        if name in expected:
            raise ValueError(f'duplicate public asset name in accepted inventory: {name}')
        expected[name] = 'sha256:' + sha256
    assets = release['assets']
    actual = {asset['name']: asset['digest'] for asset in assets if asset['state'] == 'uploaded'}
    if len(expected) != 16 or len(assets) != len(actual) or actual != expected:
        raise ValueError('public asset list or digests differ from the accepted inventory')
    return len(actual)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['version', 'stage', 'verify', 'receipt', 'published'])
    parser.add_argument('--root', type=pathlib.Path)
    parser.add_argument('--commit')
    parser.add_argument('--version', required=True)
    parser.add_argument('--run')
    parser.add_argument('--attempt')
    parser.add_argument('--receipt', type=pathlib.Path)
    parser.add_argument('--qualification-run')
    parser.add_argument('--release', type=pathlib.Path)
    parser.add_argument('--tag-ref', type=pathlib.Path)
    parser.add_argument('--tag-object', type=pathlib.Path)
    args = parser.parse_args()
    version(args.version)
    if args.mode == 'version':
        return
    if args.mode == 'published':
        if not all((args.commit, args.qualification_run, args.receipt, args.release, args.tag_ref, args.tag_object)):
            parser.error('published verification requires source, qualification run, receipt, release, and both tag objects')
        count = verify_published(load(args.receipt), load(args.release), load(args.tag_ref), load(args.tag_object),
                                 args.commit, args.version, args.qualification_run)
        print(f'v{args.version} is published with {count} asset digests matching acceptance run {args.qualification_run}.')
        return
    actual = inventory(args.root, args.commit, args.version, args.run, args.attempt)
    inventory_path = args.root / 'stage-inventory.json'
    if args.mode == 'stage':
        with inventory_path.open('x') as handle:
            json.dump(actual, handle, sort_keys=True, separators=(',', ':'))
            handle.write('\n')
        return
    if load(inventory_path) != actual:
        raise ValueError('retained staged bytes differ from immutable inventory')
    if args.mode == 'receipt':
        receipt = load(args.receipt)
        expected = dict(kind='hostwright.promotion-receipt.v3', qualificationPolicy=QUALIFICATION_POLICY, sourceCommit=args.commit,
                        version=args.version, buildRunID=args.run, buildRunAttempt=args.attempt,
                        inventorySHA256=digest(inventory_path), files=actual['files'], correspondingSource=actual['correspondingSource'])
        if any(receipt.get(key) != value for key, value in expected.items()):
            raise ValueError('aggregate receipt binding mismatch')
        gates = receipt.get('gates', {})
        if set(gates) != REQUIRED_GATES:
            raise ValueError('aggregate receipt has missing or unexpected gates')
        for key, gate in gates.items():
            if (gate.get('status') != 'passed' or gate.get('sourceCommit') != args.commit
                    or gate.get('version') != args.version
                    or not re.fullmatch('[a-f0-9]{64}', gate.get('receiptSHA256', ''))):
                raise ValueError(f'invalid gate binding: {key}')

if __name__ == '__main__':
    main()
