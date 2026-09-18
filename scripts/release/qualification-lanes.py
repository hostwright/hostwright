#!/usr/bin/env python3
"""Checkpoint actual sanitizer/fuzzer processes with immutable input and raw evidence."""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import time


def sha(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError('unsafe evidence file: ' + str(path))
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1048576), b''):
            result.update(chunk)
    return result.hexdigest()


def tree(root):
    return {str(p.relative_to(root)): sha(p) for p in sorted(root.rglob('*')) if p.is_file()}


def output(command):
    return subprocess.check_output(command, text=True).strip()

p = argparse.ArgumentParser()
p.add_argument('mode', choices=['sanitizers', 'fuzz'])
p.add_argument('--source', type=pathlib.Path, required=True)
p.add_argument('--evidence', type=pathlib.Path, required=True)
p.add_argument('--duration', type=int, default=300)
a = p.parse_args()
source = a.source.resolve()
if not a.evidence.is_absolute() or a.evidence.is_symlink():
    raise ValueError('evidence must be absolute and not a symlink')
root = a.evidence.resolve()
if root == source or source in root.parents:
    raise ValueError('evidence/cache must remain outside clean source checkout')
if a.mode == 'fuzz' and a.duration < 300:
    raise ValueError('qualification fuzz duration must be at least 300 seconds')
if a.mode == 'sanitizers' and os.environ.get('HOSTWRIGHT_SANITIZER_TEST_FILTER'):
    raise ValueError('qualification requires the full sanitizer test suite')
commit = output(['git', '-C', str(source), 'rev-parse', 'HEAD'])

def clean():
    if output(['git', '-C', str(source), 'rev-parse', 'HEAD']) != commit or output(['git', '-C', str(source), 'status', '--porcelain=v1', '--untracked-files=all']):
        raise ValueError('qualification source must remain exact and clean before/after every lane')
clean()
root.mkdir(parents=True, exist_ok=True)
(root / 'logs').mkdir(exist_ok=True)
(root / 'checkpoints').mkdir(exist_ok=True)
swift = output(['swift', '--version'])
version = json.loads((source / 'contracts/v0.0.2/versions.json').read_text())['productVersion']
inputs = dict(sourceCommit=commit, sourceRoot=str(source), swiftVersion=swift, mode=a.mode, durationSeconds=a.duration if a.mode == 'fuzz' else None)
if a.mode == 'fuzz':
    llvm = pathlib.Path(output(['brew', '--prefix', 'llvm']))
    clang = llvm / 'bin/clang'
    major = output([str(clang), '-dumpversion']).split('.')[0]
    runtime = llvm / f'lib/clang/{major}/lib/darwin/libclang_rt.fuzzer_no_main_osx.a'
    inputs.update(llvmVersion=output([str(clang), '--version']), fuzzerRuntimeSHA256=sha(runtime))
inputs_path = root / 'inputs.json'
if inputs_path.exists():
    if json.loads(inputs_path.read_text()) != inputs:
        raise ValueError('resume refused: source, toolchain, command inputs, or duration changed')
else:
    inputs_path.write_text(json.dumps(inputs, sort_keys=True) + '\n')


def lane(name, command, env=None, minimum=0):
    clean()
    if output(['swift', '--version']) != swift:
        raise ValueError('toolchain changed during qualification')
    receipt = root / 'checkpoints' / (name + '.json')
    log = root / 'logs' / (name + '.log')
    identity = dict(inputs=inputs, command=command, environment=env or {})
    if receipt.exists():
        old = json.loads(receipt.read_text())
        if old['identity'] != identity or old['status'] != 'passed' or old['logSHA256'] != sha(log) or old['elapsedSeconds'] < minimum:
            raise ValueError('resume refused: checkpoint inputs/evidence mismatch: ' + name)
        for relative, expected in old.get('retainedFiles', {}).items():
            if sha(root / relative) != expected:
                raise ValueError('resume refused: retained corpus/binary changed')
        return old
    started = time.time()
    started_monotonic = time.monotonic()
    with log.open('xb') as handle:
        process = subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT, env=dict(os.environ, **(env or {})))
        try:
            try:
                status = process.wait(timeout=(a.duration + 120) if name.startswith('fuzz-') else 7200)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                status = 124
        except BaseException:
            process.terminate()
            process.wait()
            raise
    ended = time.time()
    elapsed = time.monotonic() - started_monotonic
    try:
        clean()
        clean_after = True
    except ValueError:
        clean_after = False
    result = dict(identity=identity, startedAt=started, endedAt=ended, elapsedSeconds=elapsed,
                  exitStatus=status, status='passed' if status == 0 and elapsed >= minimum and clean_after else 'failed',
                  sourceCleanBefore=True, sourceCleanAfter=clean_after, sourceCommit=commit, logSHA256=sha(log))
    if a.mode == 'sanitizers':
        text = log.read_text(errors='replace')
        if "Test Suite 'All tests' passed" not in text and 'Test run with' not in text:
            result['status'] = 'failed'
    if a.mode == 'fuzz' and name not in {'build'}:
        text = log.read_text(errors='replace')
        if name.startswith('fuzz-') and ('DONE' not in text or 'stat::number_of_executed_units:' not in text):
            result['status'] = 'failed'
        target = name.removeprefix('final-replay-').removeprefix('replay-').removeprefix('fuzz-')
        directories = [('initial-corpora' if name.startswith('replay-') else 'final-corpora') + '/' + target]
        result['retainedFiles'] = {
            str(path.relative_to(root)): sha(path)
            for directory in directories
            for path in sorted((root / directory).rglob('*')) if path.is_file()
        }
        if name.startswith('fuzz-'):
            result['retainedFiles'].update({str(path.relative_to(root)): sha(path) for path in sorted((root / 'artifacts').glob(target + '-*')) if path.is_file()})
    if a.mode == 'fuzz' and name == 'build' and status == 0:
        binary = root / 'build/arm64-apple-macosx/debug/hostwright-critical-fuzzer'
        result['retainedFiles'] = {str(binary.relative_to(root)): sha(binary)}
    receipt.write_text(json.dumps(result, sort_keys=True) + '\n')
    if result['status'] != 'passed':
        raise ValueError('lane failed; retained raw log/checkpoint: ' + name)
    return result

lanes = []
if a.mode == 'sanitizers':
    for sanitizer in ('address', 'thread'):
        lanes.append(lane(sanitizer, ['swift', 'test', '--package-path', str(source), '--scratch-path', str(root / (sanitizer + '-build')), '--sanitize', sanitizer, '--jobs', '1']))
else:
    for directory in ('initial-corpora', 'final-corpora', 'artifacts'):
        (root / directory).mkdir(exist_ok=True)
    build = ['swift', 'build', '--package-path', str(source), '--scratch-path', str(root / 'build'), '--product', 'hostwright-critical-fuzzer', '--configuration', 'debug', '--jobs', '1', '--sanitize', 'address', '-Xswiftc', '-sanitize-coverage=edge,inline-8bit-counters,pc-table', '-Xlinker', '-force_load', '-Xlinker', str(runtime), '-Xlinker', '-lc++']
    lanes.append(lane('build', build))
    binary = root / 'build/arm64-apple-macosx/debug/hostwright-critical-fuzzer'
    binary_hash = sha(binary)
    targets = ('manifest-v3', 'compose-import', 'control-stream-v2.1', 'containerization-helper-v1', 'apple-container-json', 'release-qualification-json')
    for target in targets:
        initial = root / 'initial-corpora' / target
        corpus = root / 'final-corpora' / target
        if not initial.exists():
            shutil.copytree(source / 'Tests/HostwrightCriticalFuzzer/Corpus' / target, initial)
            shutil.copytree(initial, corpus)
        env = dict(HOSTWRIGHT_FUZZ_TARGET=target, HOSTWRIGHT_QUALIFICATION_BINARY_SHA256=binary_hash)
        lanes.append(lane('replay-' + target, [str(binary), '-runs=0', str(initial)], env))
        result = lane('fuzz-' + target, [str(binary), '-artifact_prefix=' + str(root / 'artifacts' / (target + '-')), '-max_len=1048576', '-max_total_time=' + str(a.duration), '-print_final_stats=1', str(corpus)], env, a.duration)
        result['target'] = target
        lanes.append(result)
        lanes.append(lane('final-replay-' + target, [str(binary), '-runs=0', str(corpus)], env))
clean()
receipt = dict(kind='hostwright.phase15.' + a.mode + '.v2', schemaVersion=2, status='passed', sourceCommit=commit,
               sourceCleanBefore=True, sourceCleanAfter=True, version=version, inputs=inputs, lanes=lanes,
               fullSuiteLanes=['address', 'thread'] if a.mode == 'sanitizers' else [],
               coverage=dict(instrumentation='edge,inline-8bit-counters,pc-table', statistics='logs/fuzz-<target>.log') if a.mode == 'fuzz' else None,
               crashArtifacts=tree(root / 'artifacts') if a.mode == 'fuzz' else {},
               targets=[dict(target=x['target'], elapsedSeconds=x['elapsedSeconds'], status=x['status']) for x in lanes if 'target' in x],
               attachments={str(path.relative_to(root)): sha(path) for directory in ('logs', 'checkpoints', 'initial-corpora', 'final-corpora', 'artifacts') for path in sorted((root / directory).rglob('*')) if path.is_file()})
(root / 'complete.json').write_text(json.dumps(receipt, sort_keys=True) + '\n')
print('qualification passed:', root)
