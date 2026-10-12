#!/usr/bin/env python3
"""Build the pinned kernel remediation candidate without changing shipped assets."""

import argparse
import datetime
import difflib
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
PROFILE = Path(__file__).with_name('kernel-security-candidate.json')


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def check_config(text, profile):
    lines = text.splitlines()
    for key, enabled in [('requiredDisabled', False), ('requiredEnabled', True)]:
        for name in profile[key]:
            values = [line for line in lines if line.startswith(name + '=') or line == f'# {name} is not set']
            if values != ([name + '=y'] if enabled else [f'# {name} is not set']):
                raise ValueError(f'Kernel configuration requirement changed: {name}')


def check_objects(objects, profile):
    for name in objects:
        if any(name.startswith(prefix) for prefix in profile['excludedObjectDirectories']):
            raise ValueError(f'Excluded kernel subsystem produced an object: {name}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != 'Linux' or platform.machine() != 'aarch64':
        raise ValueError('Kernel candidate builds require Linux arm64')
    for path in [args.output, args.work]:
        if not path.is_absolute() or path.resolve() != path or path.exists():
            raise ValueError('Use new absolute output and work directories')
    if args.output.is_relative_to(args.work) or args.work.is_relative_to(args.output):
        raise ValueError('Output and work directories must not overlap')
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    status = subprocess.check_output(['git', 'status', '--porcelain=v1', '--untracked-files=all'], cwd=ROOT)
    if status:
        raise ValueError('Kernel producer requires a clean source checkout')
    profile = json.loads(PROFILE.read_text())
    args.output.mkdir(mode=0o700)
    args.work.mkdir(mode=0o700)
    inputs = args.work / 'inputs'
    inputs.mkdir()
    commands = []
    environment = dict(os.environ, KBUILD_BUILD_TIMESTAMP='2026-01-01T00:00:00Z',
                       KBUILD_BUILD_USER='hostwright', KBUILD_BUILD_HOST='github-arm64',
                       KBUILD_BUILD_VERSION='1', SOURCE_DATE_EPOCH='1767225600',
                       RUSTC='/bin/false', PAHOLE='/dev/null',
                       KCFLAGS=f'-fdebug-prefix-map={args.work}=/hostwright-kernel-build',
                       KAFLAGS=f'-fdebug-prefix-map={args.work}=/hostwright-kernel-build')
    for name in ['MAKEFLAGS', 'MFLAGS', 'KCONFIG_CONFIG', 'KCONFIG_ALLCONFIG', 'CROSS_COMPILE', 'CC', 'LD']:
        environment.pop(name, None)
    environment['MAKEFLAGS'] = 'RUSTC=/bin/false PAHOLE=/dev/null'

    def run(name, command, cwd=ROOT):
        with (args.output / (name + '.log')).open('xb') as log:
            result = subprocess.run(command, cwd=cwd, env=environment, stdout=log,
                                    stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        commands.append({'command': command, 'cwd': str(cwd), 'exitCode': result.returncode})
        (args.output / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        if result.returncode:
            raise RuntimeError(f'{name} failed; retained log and work tree')

    for item in profile['downloads']:
        path = inputs / item['name']
        with urllib.request.urlopen(item['url'], timeout=120) as response, path.open('xb') as output:
            shutil.copyfileobj(response, output)
        if sha(path) != item['sha256']:
            raise ValueError(f'Upstream input digest mismatch: {item["name"]}')
    key = ROOT / 'scripts/release/keys/gregkh-pinned-public-key.asc'
    if sha(key) != profile['publicKeySHA256']:
        raise ValueError('Pinned kernel signing key changed')
    shutil.copyfile(key, inputs / key.name)
    run('signature', [sys.executable, str(ROOT / 'scripts/release/verify-kernel-source-signature.py'),
                     '--kernel-version', profile['version'], '--inputs', str(inputs),
                     '--output', str(args.output / 'signature.json')])
    prefix = 'linux-' + profile['version']
    run('patch-source-contract', [sys.executable, str(ROOT / 'scripts/release/test-kernel-patch-replay.py'),
                                 '--source-archive', str(inputs / (prefix + '.tar.xz'))])
    with tarfile.open(inputs / (prefix + '.tar.xz'), 'r:xz') as archive:
        for member in archive:
            if member.name != prefix and not member.name.startswith(prefix + '/'):
                raise ValueError('Kernel source member escapes version root')
        archive.extractall(args.work, filter='data')
    tree = args.work / prefix
    for name, expected in profile['sourceChecks'].items():
        if sha(tree / name) != expected:
            raise ValueError(f'Required upstream source changed: {name}')
    for index, item in enumerate(profile['patches']):
        patch = ROOT / item['path']
        if sha(patch) != item['sha256']:
            raise ValueError('Reviewed kernel patch digest changed')
        run(f'patch-{index}-check', ['git', 'apply', '--check', str(patch)], cwd=tree)
        run(f'patch-{index}', ['git', 'apply', str(patch)], cwd=tree)
    config = ROOT / profile['seedConfig']
    if sha(config) != profile['seedConfigSHA256']:
        raise ValueError('Kernel configuration seed changed')
    shutil.copyfile(config, tree / '.config')
    run('olddefconfig', ['make', 'ARCH=arm64', 'olddefconfig'], cwd=tree)
    check_config((tree / '.config').read_text(), profile)
    shutil.copyfile(tree / '.config', args.output / 'kernel.config')
    (args.output / 'config.diff').write_text(''.join(difflib.unified_diff(
        config.read_text().splitlines(True), (tree / '.config').read_text().splitlines(True),
        fromfile='retained-seed', tofile='candidate-config')))
    run('build', ['make', '-j', str(os.cpu_count() or 2), 'ARCH=arm64', 'Image'], cwd=tree)
    objects = sorted(str(p.relative_to(tree)) for p in tree.rglob('*') if p.suffix in {'.o', '.ko'})
    (args.output / 'objects.json').write_text(json.dumps(objects, indent=2) + '\n')
    check_objects(objects, profile)
    shutil.copyfile(tree / 'arch/arm64/boot/Image', args.output / 'Image')
    shutil.copyfile(PROFILE, args.output / 'profile.json')
    run('compiler', ['gcc', '--version'])
    run('environment', ['uname', '-a'])
    if subprocess.check_output(['git', 'status', '--porcelain=v1', '--untracked-files=all'], cwd=ROOT):
        raise ValueError('Producer source changed during build')
    result = dict(status='built-candidate-only', sourceCommit=commit, kernelVersion=profile['version'],
                  kernelCommit=profile['commit'], profileSHA256=sha(PROFILE),
                  completedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  gccSHA256=sha(Path(shutil.which('gcc')).resolve()),
                  attachments={p.name: sha(p) for p in args.output.iterdir() if p.is_file()},
                  qualificationAccepted=False, shippedPinsChanged=False,
                  scope='Patched candidate build only; requires independent rebuild equality, boot/lifecycle checks and final runtime provenance.')
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'status': result['status'], 'imageSHA256': result['attachments']['Image']}))


if __name__ == '__main__':
    main()
