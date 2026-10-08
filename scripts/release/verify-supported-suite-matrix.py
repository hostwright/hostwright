#!/usr/bin/env python3
"""Verify complete compiled test coverage from bound base and attended receipts."""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import re
import subprocess
import xml.etree.ElementTree as ET

IDENTITY = re.compile(r'[A-Za-z0-9_.]+/[A-Za-z0-9_]+(?:\([^\n]*\))?')
CASE = re.compile(r"^Test Case '-\[([A-Za-z0-9_.]+) ([A-Za-z0-9_]+)\]' (passed|failed|skipped) \(", re.M)

def load_json(path):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate JSON key: ' + key)
            result[key] = value
        return result
    def invalid_constant(value):
        raise ValueError('non-finite JSON value: ' + value)
    return json.loads(Path(path).read_text(), object_pairs_hook=pairs, parse_constant=invalid_constant)

def require(condition, message):
    if not condition:
        raise ValueError(message)

def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1048576), b''):
            h.update(chunk)
    return h.hexdigest()

def contained(root, relative):
    root = Path(root)
    value = Path(relative)
    require(root.is_absolute() and root.resolve() == root, 'noncanonical evidence root')
    require(not value.is_absolute() and '..' not in value.parts, 'unsafe evidence path')
    path = root / value
    require(path.resolve() == path and path.is_file(), 'missing or symlinked evidence file')
    return path

def load_record(descriptor):
    root = Path(descriptor['root'])
    path = contained(root, descriptor['receipt'])
    expected_receipt = descriptor['receiptSHA256']
    require(isinstance(expected_receipt, str) and re.fullmatch('[a-f0-9]{64}', expected_receipt), 'invalid receipt digest')
    require(sha(path) == expected_receipt, 'receipt digest mismatch')
    record = load_json(path)
    attachments = record.get('attachments')
    require(isinstance(attachments, dict) and attachments, 'missing raw attachments')
    for relative, expected in attachments.items():
        require(isinstance(expected, str) and re.fullmatch('[a-f0-9]{64}', expected), 'invalid raw digest')
        require(sha(contained(root, relative)) == expected, 'raw attachment digest mismatch')
    require(sha(path) == expected_receipt, 'receipt changed during verification')
    return root, path, record, expected_receipt

def bound_attachment(root, record, relative):
    require(relative in record['attachments'], 'required raw file is not bound by receipt')
    path = contained(root, relative)
    require(sha(path) == record['attachments'][relative], 'required raw file changed')
    return path

def resource_proofs(record):
    if record['selector'] in {
        'HostwrightRegistryTests.RegistryAuthenticationTests/testLiveDockerHubBearerScopeWhenExplicitlyEnabled',
        'HostwrightSchedulerTests.Phase10SchedulerQualificationTests/testPhase10SchedulerQualificationPerformanceCell',
    }:
        return
    proofs = record.get('cleanupProofAttachments')
    require(record.get('cleanupStatus') == 'passed' and record.get('unmanagedPreservationStatus') == 'passed', 'runtime cell lacks verified cleanup/preservation')
    require(isinstance(proofs, dict) and proofs and all(record['attachments'].get(name) == digest for name, digest in proofs.items()), 'runtime cell lacks bound cleanup proof')

def binding(record, commit, version, lane):
    require(record.get('sourceCommit') == commit and record.get('version') == version, 'mixed source/version')
    require(record.get('sourceCleanBefore') is True and record.get('sourceCleanAfter') is True, 'dirty source')
    require(record.get('executionMode') == 'real' and record.get('exitCode') == 0, 'non-real or failed execution')
    require(record.get('sanitizer') == (None if lane == 'source' else lane), 'mixed sanitizer lane')

def inventory(text):
    names = [line for line in text.splitlines() if IDENTITY.fullmatch(line)]
    require(names and len(names) == len(set(names)), 'empty or duplicate compiled inventory')
    native = {name for name in names if '(' not in name}
    swift = set(names) - native
    require(native and swift, 'missing compiled test framework')
    return native, swift

def native_cases(text):
    cases = [(module + '/' + method, outcome) for module, method, outcome in CASE.findall(text)]
    require(cases and len(cases) == len({name for name, _ in cases}), 'empty or duplicate executed XCTest')
    return dict(cases)

def swift_cases(path):
    cases = list(ET.parse(path).getroot().iter('testcase'))
    names = [case.get('classname', '') + '/' + case.get('name', '') for case in cases]
    require(names and all(IDENTITY.fullmatch(name) for name in names), 'missing or unsupported Swift Testing identities')
    require(len(names) == len(set(names)), 'duplicate Swift Testing identities')
    require(all(case.find('failure') is None and case.find('error') is None and case.find('skipped') is None for case in cases), 'failed or skipped Swift Testing case')
    return set(names)

def coverage(native_inventory, swift_inventory, routed, base_cases, base_swift, attended_cases, lane):
    require(routed and routed <= native_inventory, 'unsupported routed identities')
    require(base_swift == swift_inventory, 'missing or extra Swift Testing coverage')
    require(all(status != 'failed' for status in base_cases.values()), 'failed base XCTest')
    skipped = {name for name, status in base_cases.items() if status == 'skipped'}
    passed = {name for name, status in base_cases.items() if status == 'passed'}
    require(set(base_cases) <= native_inventory, 'unsupported base XCTest identity')
    if lane == 'source':
        require(skipped == routed and set(base_cases) == native_inventory, 'unexpected source omissions or skipped cases')
    else:
        require(not skipped and set(base_cases) == native_inventory - routed, 'incomplete sanitizer base inventory')
    require(len(attended_cases) == len(set(attended_cases)), 'duplicate attended coverage')
    require(set(attended_cases) <= routed, 'unsupported attended identity')
    require(not passed & set(attended_cases), 'duplicate base/attended coverage')
    require(passed | set(attended_cases) == native_inventory, 'missing required attended coverage')
    return {'xctestCases': len(native_inventory), 'swiftTestingCases': len(swift_inventory),
            'passedCases': len(native_inventory) + len(swift_inventory), 'failedCases': 0, 'skippedCases': 0}

def verify(config):
    source = Path(config['sourceRoot'])
    commit, version, lane = config['sourceCommit'], config['version'], config['lane']
    require(lane in {'source', 'address', 'thread'}, 'unsupported suite lane')
    require(source.is_absolute() and source.resolve() == source, 'noncanonical source root')
    require(re.fullmatch('[a-f0-9]{40}', commit), 'invalid source commit')
    def clean():
        return (subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() == commit
                and not subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain=v1', '--untracked-files=all'], text=True).strip()
                and load_json(source / 'contracts/v0.0.2/versions.json')['productVersion'] == version)
    require(clean(), 'current source is dirty or different')
    compiled_path = Path(config['compiledInventory'])
    require(compiled_path.is_absolute() and compiled_path.resolve() == compiled_path and compiled_path.is_file(), 'unsafe compiled inventory')
    require(sha(compiled_path) == config['compiledInventorySHA256'], 'compiled inventory changed')
    native, swift = inventory(compiled_path.read_text())
    binary = Path(config['binary'])
    require(binary.is_absolute() and binary.resolve() == binary and binary.is_file(), 'unsafe executed binary')
    binary_sha = sha(binary)
    require(binary_sha == config['binarySHA256'], 'executed binary changed')
    routed = set(config['routedSelectors'])
    require(len(routed) == len(config['routedSelectors']), 'duplicate routed identities')
    base_root, base_path, base, base_sha = load_record(config['base'])
    binding(base, commit, version, lane)
    require(base.get('binarySHA256') == binary_sha, 'base execution has missing or mixed binary binding')
    require(base.get('compiledInventorySHA256') == config['compiledInventorySHA256'], 'base execution has missing or mixed compiled inventory binding')
    require(base.get('status') == ('incomplete' if lane == 'source' else 'partial-base-passed'), 'unexpected base execution status')
    if lane == 'source':
        require(base.get('command') == ['scripts/test.sh', 'full'] and base.get('failedCases') == [], 'source base is not full or contains failures')
    else:
        command = base.get('command', [])
        require('--sanitize' in command and command[command.index('--sanitize') + 1] == lane, 'base command sanitizer mismatch')
        expected_skip = '^(?:' + '|'.join(re.escape(name) for name in base['qualifiedRoutedSelectors']) + ')$'
        require('--filter' not in command and '--skip' in command and command[command.index('--skip') + 1] == expected_skip, 'unexpected base filter')
        require(set(base['qualifiedRoutedSelectors']) == routed, 'routed base inventory mismatch')
    base_text = bound_attachment(base_root, base, 'commands.log').read_text()
    require('ERROR: AddressSanitizer' not in base_text and 'WARNING: ThreadSanitizer' not in base_text, 'reported sanitizer defect in base')
    observed = native_cases(base_text)
    summaries = re.findall(r"Test Suite 'All tests' (passed|failed)[^\n]*\n[ \t]*Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", base_text)
    require(len(summaries) == 1 and summaries[0][0] == 'passed', 'missing complete native base summary')
    require(int(summaries[0][1]) == len(observed) and int(summaries[0][2] or 0) == sum(x == 'skipped' for x in observed.values()) and int(summaries[0][3]) == 0, 'native base summary mismatch')
    base_swift_path = bound_attachment(base_root, base, config['baseSwiftXML'])
    actual_swift = swift_cases(base_swift_path)
    swift_summary = re.findall(r'Test run with (\d+) tests? in \d+ suites? (passed|failed) after', base_text)
    require(len(swift_summary) == 1 and swift_summary[0][1] == 'passed' and int(swift_summary[0][0]) == len(actual_swift), 'Swift Testing base summary mismatch')
    attended = []
    retained = [{'root': str(base_root), 'receipt': str(base_path), 'sha256': base_sha}]
    for descriptor in config['attended']:
        evidence, path, record, receipt_sha = load_record(descriptor)
        binding(record, commit, version, lane)
        require(record.get('status') == 'passed' and record.get('binarySHA256') == binary_sha, 'failed attended cell or mixed binary')
        text = bound_attachment(evidence, record, descriptor['log']).read_text()
        require('ERROR: AddressSanitizer' not in text and 'WARNING: ThreadSanitizer' not in text, 'reported sanitizer defect')
        actual = native_cases(text)
        require(len(actual) == 1 and set(actual) == {record['selector']} and list(actual.values()) == ['passed'], 'attended raw outcome mismatch')
        resource_proofs(record)
        attended.extend(actual)
        retained.append({'root': str(evidence), 'receipt': str(path), 'sha256': receipt_sha})
    counts = coverage(native, swift, routed, observed, actual_swift, attended, lane)
    require(clean() and sha(binary) == binary_sha and sha(compiled_path) == config['compiledInventorySHA256'], 'inputs changed during verification')
    require(all(sha(Path(item['receipt'])) == item['sha256'] for item in retained), 'receipt changed during matrix verification')
    return dict(kind='hostwright.supported-suite-matrix-verification.v1', sourceCommit=commit, version=version,
                lane=lane, status='passed', sourceCleanBefore=True, sourceCleanAfter=True, executionMode='real',
                counts=counts, routedExecutedPassingCases=sorted(attended), baseSkippedResultsCountedAsPassing=False,
                completeSupportedSuite=True, protectedQualificationAccepted=False, retainedReceipts=retained,
                compiledInventorySHA256=config['compiledInventorySHA256'], binarySHA256=binary_sha,
                verifierSHA256=sha(Path(__file__)), verifiedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    config = load_json(args.config)
    require(args.output.is_absolute() and args.output.resolve() == args.output and not args.output.exists(), 'unsafe or existing output path')
    require(Path(config['sourceRoot']) not in args.output.parents, 'output must be outside clean source')
    result = verify(config)
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
