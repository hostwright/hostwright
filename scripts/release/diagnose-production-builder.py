#!/usr/bin/env python3
"""Retain two unsigned outputs produced by the frozen distribution CLI itself."""
from pathlib import Path, PurePosixPath
import argparse
import datetime
from functools import partial
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tarfile

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('payload_diagnostic', HERE / 'diagnose-payload-reproducibility.py')
D = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(D)
SOURCE = 'aa8586a1ccc7887f7ae09dcccdc32bf13c27c705'
RUNTIME_RUN = 38697512336
RUNTIME_SHA256 = '00b2a8810840392cffee8a8e4da0a2be1ea870b3837c042b34502cf9ee940cda'
BLOCKED_STAGES = {'developer-id-signing', 'notarization-stapling-gatekeeper', 'installer-package', 'host-environment'}


def runtime_environment(base, parent):
    result = dict(base, PATH=parent['PATH'], PYTHONDONTWRITEBYTECODE='1')
    key = 'GH_TOKEN' if parent.get('GH_TOKEN') else 'GITHUB_TOKEN'
    if not parent.get(key):
        raise ValueError('Runtime attestation verification requires the read-only job token')
    result[key] = parent[key]
    return result


def clean_source(source, commit=SOURCE):
    D.clean_source(source, commit)
    ignored = subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain=v1',
                                       '--ignored', '--untracked-files=normal'], timeout=30)
    if ignored.strip():
        raise ValueError('Fresh diagnostic checkout contains ignored source entries: ' + ignored.decode(errors='replace'))


def regular(path, limit):
    if path.resolve() != path or not path.is_file() or path.is_symlink() or not 0 < path.stat().st_size <= limit:
        raise ValueError('Expected bounded canonical regular file: ' + str(path))


def read_generation(output, commit, products):
    for name in ['manifest.json', 'distribution-evidence.json']:
        regular(output / name, 2 * 1024**2)
    manifest = json.loads((output / 'manifest.json').read_text())
    report = json.loads((output / 'distribution-evidence.json').read_text())
    artifact_id = manifest['artifactID']
    if (manifest['sourceCommit'] != commit or manifest['sourceDirty'] is not False
            or report['manifest'] != manifest or not re.fullmatch(r'[A-Za-z0-9.-]{1,180}', artifact_id)):
        raise ValueError('Assembled output differs from exact clean source')
    stages = {row['identifier']: row['status'] for row in report['stages']}
    if (not all(stages.get(name) == 'passed' for name in ['release-build', 'archive', 'checksums', 'sbom', 'provenance'])
            or any(status not in {'passed', 'blocked'} or status == 'blocked' and name not in BLOCKED_STAGES
                   for name, status in stages.items()) or report['evidence']['failures']):
        raise ValueError('Actual clean builder did not complete artifact assembly')
    descriptor = report['archive']
    name = descriptor['fileName']
    if PurePosixPath(name).name != name:
        raise ValueError('Unsafe archive descriptor')
    archive = output / name
    regular(archive, 1024**3)
    if D.sha(archive) != descriptor['sha256'] or archive.stat().st_size != descriptor['sizeBytes']:
        raise ValueError('Assembled archive digest or size differs from report')
    paths = {name: ('libexec/hostwright/Hostwright.app/Contents/MacOS/hostwright-desktop'
                    if name == 'hostwright-desktop' else 'bin/' + name) for name in products}
    expected = {row['path']: row for row in manifest['files']}
    if len(expected) != len(manifest['files']) or not set(paths.values()) <= expected.keys():
        raise ValueError('Missing or duplicate manifest payload')
    retained = {}
    seen = set()
    total = 0
    with tarfile.open(archive, 'r|gz') as tar:
        for member in tar:
            parts = PurePosixPath(member.name)
            if parts.is_absolute() or '..' in parts.parts or parts.as_posix() != member.name.rstrip('/'):
                raise ValueError('Unsafe assembled archive member')
            if member.name in seen or len(seen) >= 500:
                raise ValueError('Duplicate or excessive assembled archive entries')
            seen.add(member.name)
            if member.isdir():
                continue
            if not member.isfile() or member.size > 128 * 1024**2:
                raise ValueError('Unsafe assembled archive file')
            total += member.size
            if total > 2 * 1024**3:
                raise ValueError('Expanded assembled archive exceeds budget')
            relative = member.name.removeprefix(artifact_id + '/')
            if relative not in paths.values():
                continue
            entry = expected[relative]
            data = tar.extractfile(member).read()
            import hashlib
            digest = hashlib.sha256(data).hexdigest()
            if digest != entry['sha256'] or len(data) != entry['sizeBytes'] or member.mode != entry['mode']:
                raise ValueError('Actual retained executable differs from its manifest')
            product = next(name for name, path in paths.items() if path == relative)
            destination = output / ('payload-' + product)
            with destination.open('xb') as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            retained[product] = dict(file=str(destination), sha256=digest, bytes=len(data))
    if set(retained) != set(products):
        raise ValueError('Incomplete actual executable retention')
    return dict(manifest=manifest, report=report, payloads=retained)


def diagnose(source, output, runtime_archive):
    clean_source(source)
    D.recipe(source)
    D.validate_output(source, output)
    regular(runtime_archive, 3 * 1024**3)
    if D.sha(runtime_archive) != RUNTIME_SHA256 or shutil.disk_usage(output.parent).free < 16 * 1024**3:
        raise ValueError('Require authenticated runtime archive and sixteen GiB initial disk budget')
    output.mkdir(mode=0o700)
    environment = dict(HOME=str(Path.home()), LANG='C', LC_ALL='C', PATH='/usr/bin:/bin:/usr/sbin:/sbin',
                       PYTHONDONTWRITEBYTECODE='1',
                       GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_PAGER='cat',
                       GIT_TERMINAL_PROMPT='0', PAGER='cat', TERM='dumb')
    record = dict(sourceCommit=SOURCE, runtimeProducerRun=RUNTIME_RUN, runtimeProducerAttempt=1,
                  runtimeArchiveSHA256=RUNTIME_SHA256, commands=[], builds=[], qualificationAccepted=False,
                  startedAt=datetime.datetime.now(datetime.UTC).isoformat(),
                  scope='Diagnostic only. Two actual CLI invocations create distinct compiler scratch paths; the original XCTest reused one builder/scratch. No original failure is superseded.')
    run = partial(D.run_command, source=source, working_directory=Path('/'), environment=environment,
                  output=output, record=record)

    def interrupted(signum, frame):
        raise InterruptedError('Production builder diagnostic signal ' + str(signum))

    for sig in [signal.SIGTERM, signal.SIGINT]:
        signal.signal(sig, interrupted)
    try:
        for label, command in [('os', ['/usr/bin/sw_vers']), ('xcode', ['/usr/bin/xcodebuild', '-version']),
                               ('swift', ['/usr/bin/swift', '--version'])]:
            run(command, label)
        assets = output / 'verified-runtime-assets'
        D.run_command([sys.executable, str(source / 'scripts/release/materialize-runtime-assets.py'), '--archive', str(runtime_archive),
             '--output', str(assets), '--source-commit', SOURCE, '--run-id', str(RUNTIME_RUN), '--attempt', '1'],
            'authenticate-runtime', source=source, working_directory=Path('/'),
                      environment=runtime_environment(environment, os.environ), output=output, record=record, timeout=1200)
        clean_source(source)
        scratch = output / 'driver-build'
        bootstrap_env = dict(environment, SWIFT_DETERMINISTIC_HASHING='1')
        D.run_command(['/usr/bin/swift', *D.arguments(source, scratch), '--product', 'hostwright-dist'],
                      'bootstrap-driver', source=source, working_directory=Path('/'), environment=bootstrap_env,
                      output=output, record=record, timeout=1200)
        driver = scratch / 'arm64-apple-macosx/release/hostwright-dist'
        regular(driver, 128 * 1024**2)
        products = D.release_products(source)
        for number in [1, 2]:
            clean_source(source)
            generation = output / ('generation-' + str(number))
            D.run_command([str(driver), 'build', '--source-root', str(source), '--output-dir', str(generation),
                           '--expected-commit', SOURCE], 'actual-builder-' + str(number), source=source,
                          working_directory=Path('/'), environment=dict(environment, HOSTWRIGHT_CONTAINERIZATION_ASSET_ROOT=str(assets)),
                          output=output, record=record, timeout=4500, accepted_exit_codes=(69,))
            record['builds'].append(read_generation(generation, SOURCE, products))
            clean_source(source)
        left, right = record['builds']
        record['payloadDifferences'] = {name: D.difference_summary(Path(left['payloads'][name]['file']), Path(right['payloads'][name]['file'])) for name in products}
        record['status'] = 'identical' if all(item['differentBytes'] == 0 for item in record['payloadDifferences'].values()) else 'different'
    except BaseException as error:
        record.update(status='diagnostic-failed', error=repr(error))
        raise
    finally:
        record['completedAt'] = datetime.datetime.now(datetime.UTC).isoformat()
        with (output / 'result.json').open('x') as stream:
            json.dump(record, stream, indent=2)
            stream.write('\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runtime-archive', type=Path, required=True)
    args = parser.parse_args()
    diagnose(args.source, args.output, args.runtime_archive)
