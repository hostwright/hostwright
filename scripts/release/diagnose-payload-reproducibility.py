#!/usr/bin/env python3
"""Retain two isolated builds of the smallest payload that differed on macOS 26."""
from pathlib import Path
import argparse
import datetime
import hashlib
from functools import partial
import json
import os
import re
import shutil
import signal
import subprocess
import tarfile
import time

PRODUCT = 'hostwright-network-provider-worker'
RECIPE_SHA256 = 'b2384391b2e91ceba6db9868973d0ff01d9f562527ce4d33ea6239ca82b7ed6e'


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def clean_source(source, commit):
    if not re.fullmatch('[a-f0-9]{40}', commit):
        raise ValueError('Expected a full source commit')
    if source.resolve() != source or not source.is_dir():
        raise ValueError('Source must be a canonical directory')
    actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True, timeout=30).strip()
    dirty = subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain=v1', '--untracked-files=all'], timeout=30)
    if actual != commit or dirty:
        raise ValueError('Source is dirty or does not match the requested commit')
    subprocess.run(['git', '-C', str(source), 'merge-base', '--is-ancestor', commit, 'origin/main'], check=True, timeout=30)


def recipe(source):
    text = (source / 'Sources/HostwrightDistribution/DistributionAssembler.swift').read_text()
    body = text[text.index('    static func deterministicReleaseBuildArguments('):text.index('    static func evidenceCommand(')]
    if hashlib.sha256(body.encode()).hexdigest() != RECIPE_SHA256:
        raise ValueError('Release build recipe changed; review diagnostic arguments before using it')


def arguments(source, scratch):
    mapping = f'{scratch}=/hostwright-build'
    return ['build', '--build-system', 'native', '--package-path', str(source), '--scratch-path', str(scratch),
            '-c', 'release', '--jobs', '1', '-debug-info-format', 'none', '-Xlinker', '-reproducible',
            '-Xswiftc', '-num-threads', '-Xswiftc', '1', '-Xswiftc', '-no-whole-module-optimization',
            '-Xswiftc', '-disable-cmo', '-Xswiftc', '-file-prefix-map', '-Xswiftc', mapping,
            '-Xcc', f'-ffile-prefix-map={mapping}', '-Xcc', f'-fmacro-prefix-map={mapping}',
            '-Xcxx', f'-ffile-prefix-map={mapping}', '-Xcxx', f'-fmacro-prefix-map={mapping}']


def difference_summary(first, second):
    different, offsets, offset = 0, [], 0
    with first.open('rb') as left, second.open('rb') as right:
        while True:
            a, b = left.read(1024 * 1024), right.read(1024 * 1024)
            if not a and not b:
                break
            if a != b:
                for index in range(max(len(a), len(b))):
                    if index >= len(a) or index >= len(b) or a[index] != b[index]:
                        different += 1
                        if len(offsets) < 64:
                            offsets.append(offset + index)
            offset += len(a) if len(a) >= len(b) else len(b)
    return dict(firstBytes=first.stat().st_size, secondBytes=second.stat().st_size,
                differentBytes=different, firstDifferentOffsets=offsets)


def validate_output(source, output):
    if not output.is_absolute() or output.resolve() != output or output.exists() or source == output or source in output.parents:
        raise ValueError('Output must be a fresh canonical directory outside source')


def run_command(command, label, *, source, environment, output, record, timeout=60):
    log = output / (label + '.log')
    child = None
    started = time.monotonic()
    try:
        with log.open('xb') as stream:
            child = subprocess.Popen(command, cwd=source, env=environment, stdout=stream,
                                     stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
            while child.poll() is None:
                if time.monotonic() - started > timeout or log.stat().st_size > 32 * 1024**2 or shutil.disk_usage(output).free < 1024**3:
                    raise RuntimeError('Diagnostic command exceeded its time, output or disk budget')
                time.sleep(0.2)
            if child.returncode != 0:
                raise RuntimeError('Diagnostic command failed: ' + label)
    finally:
        if child is not None:
            def alive():
                child.poll()
                try:
                    os.killpg(child.pid, 0)
                    return True
                except ProcessLookupError:
                    return False
                except PermissionError:
                    child.wait(timeout=1)
                    try:
                        os.killpg(child.pid, 0)
                        return True
                    except ProcessLookupError:
                        return False
            cleanup_signals = []
            remaining, cleanup_error = None, None
            try:
                for sig in [signal.SIGTERM, signal.SIGKILL]:
                    if not alive():
                        break
                    cleanup_signals.append(signal.Signals(sig).name)
                    os.killpg(child.pid, sig)
                    end = time.monotonic() + 5
                    while alive() and time.monotonic() < end:
                        time.sleep(0.1)
                child.wait(timeout=5)
                remaining = alive()
            except BaseException as error:
                cleanup_error = repr(error)
            finally:
                record['commands'].append(dict(command=command, log=log.name, pid=child.pid, processGroup=child.pid,
                                                exitCode=child.poll(), logSHA256=sha(log), cleanupError=cleanup_error,
                                                cleanupSignals=cleanup_signals, processGroupRemaining=remaining))
            if remaining is not False or cleanup_signals or cleanup_error:
                raise RuntimeError('Diagnostic command required process-group cleanup; do not accept its comparison')
    return log.read_text()


def diagnose(source, commit, output):
    clean_source(source, commit)
    recipe(source)
    validate_output(source, output)
    if shutil.disk_usage(output.parent).free < 6 * 1024**3:
        raise ValueError('Diagnostic requires six GiB of free space')
    output.mkdir(mode=0o700)
    scratch = output / 'scratch'
    environment = dict(HOME=str(Path.home()), LANG='C', LC_ALL='C', PATH='/usr/bin:/bin:/usr/sbin:/sbin',
                       GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_PAGER='cat',
                       GIT_TERMINAL_PROMPT='0', PAGER='cat', TERM='dumb', SWIFT_DETERMINISTIC_HASHING='1')
    record = dict(sourceCommit=commit, product=PRODUCT, recipeSHA256=RECIPE_SHA256,
                  startedAt=datetime.datetime.now(datetime.UTC).isoformat(), environment=environment,
                  commands=[], builds=[], qualificationAccepted=False,
                  scope='Diagnostic comparison only; does not replace or accept any qualification gate.')

    run = partial(run_command, source=source, environment=environment, output=output, record=record)

    def interrupted(signum, frame):
        raise InterruptedError('Diagnostic interrupted by signal ' + str(signum))

    for sig in [signal.SIGTERM, signal.SIGINT]:
        signal.signal(sig, interrupted)
    try:
        for label, command in [('os', ['/usr/bin/sw_vers']), ('xcode', ['/usr/bin/xcodebuild', '-version']),
                               ('swift', ['/usr/bin/swift', '--version'])]:
            run(command, label)
        for number in [1, 2]:
            clean_source(source, commit)
            assert not scratch.exists()
            scratch.mkdir(mode=0o700)
            run(['/usr/bin/swift', *arguments(source, scratch), '--product', PRODUCT], f'build-{number}', timeout=1200)
            bin_path = Path(run(['/usr/bin/swift', *arguments(source, scratch), '--show-bin-path'], f'bin-path-{number}').strip())
            assert bin_path.resolve() == bin_path and scratch in bin_path.parents
            binary = bin_path / PRODUCT
            assert binary.is_file() and not binary.is_symlink()
            retained = output / f'{PRODUCT}-{number}'
            shutil.copyfile(binary, retained)
            retained.chmod(0o600)
            assert sha(binary) == sha(retained)
            for label, command in [('load-commands', ['/usr/bin/otool', '-l']), ('symbols', ['/usr/bin/nm', '-nm']),
                                   ('signature', ['/usr/bin/codesign', '-dvvv'])]:
                run([*command, str(binary)], f'{label}-{number}')
            objects = sorted(bin_path.rglob('*.o'))
            total = sum(path.stat().st_size for path in objects)
            assert objects and total < 1024**3 and all(path.is_file() and not path.is_symlink() for path in objects)
            inventory = {str(path.relative_to(scratch)): dict(sha256=sha(path), bytes=path.stat().st_size) for path in objects}
            archive = output / f'objects-{number}.tar.gz'
            with tarfile.open(archive, 'x:gz') as tar:
                for path in objects:
                    tar.add(path, arcname=str(path.relative_to(scratch)), recursive=False)
            record['builds'].append(dict(binary=retained.name, binarySHA256=sha(retained), objects=inventory,
                                         objectArchive=archive.name, objectArchiveSHA256=sha(archive)))
            clean_source(source, commit)
            shutil.rmtree(scratch)
        left, right = record['builds']
        record['status'] = 'identical' if left['binarySHA256'] == right['binarySHA256'] else 'different'
        record['binaryDifference'] = difference_summary(output / left['binary'], output / right['binary'])
        record['differentObjects'] = sorted(name for name in set(left['objects']) | set(right['objects'])
                                           if left['objects'].get(name) != right['objects'].get(name))
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
    parser.add_argument('--commit', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    diagnose(args.source, args.commit, args.output)
