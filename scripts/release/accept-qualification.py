#!/usr/bin/env python3
"""Validate retained gate evidence before protected acceptance attests its aggregate."""
import argparse
import importlib.util
import json
import pathlib
import re

spec = importlib.util.spec_from_file_location('staged', pathlib.Path(__file__).with_name('staged-release.py'))
staged = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staged)

REQUIRED_CHECKS = {
    'source': {'targeted-regressions', 'full-suite'},
    'artifact-integrity': {'signatures', 'notarization', 'checksums', 'provenance',
                           'sbom-licenses', 'secrets', 'dependency-security'},
    'installation': {'archive-install', 'pkg-install', 'reboot', 'upgrade-preserve-data',
                     'authorized-rollback', 'repair', 'uninstall-preserve-data'},
    'working-product': {'compose-execution', 'desktop-lifecycle', 'keyboard-accessibility',
                        'state-backup-restore', 'workload-data-backup-restore',
                        'interrupted-lifecycle-recovery', 'daemon-restart-recovery',
                        'cancellation', 'stale-authority-refusal', 'exact-owned-cleanup',
                        'unmanaged-preservation'},
    'documentation': {'cli-quickstart', 'compose-quickstart', 'desktop-quickstart',
                       'compatibility-claims', 'install-claims', 'documentation-links'},
}
PROVIDERS = {'apple-container-1.0.0', 'apple-container-1.1.0', 'containerization-0.35.0'}
PROVIDER_CHECKS = {'up', 'status', 'stats', 'logs', 'restart', 'down', 'owned-cleanup'}
WEBSITE_CHECKS = {f'{package}-{check}' for package in ('root', 'docs')
                  for check in ('typecheck', 'build', 'links')}


def exact_outcomes(value, expected):
    return (isinstance(value, list) and all(isinstance(item, str) for item in value)
            and len(value) == len(expected) and set(value) == expected)


def validate_gate(name, gate, evidence, commit, version, inventory_sha256, source_binding):
    if name not in staged.REQUIRED_GATES:
        raise ValueError('unknown focused qualification group: ' + name)
    if (not isinstance(gate, dict) or gate.get('qualificationPolicy') != staged.QUALIFICATION_POLICY
            or gate.get('sourceCommit') != commit or gate.get('version') != version
            or gate.get('status') != 'passed' or gate.get('executionMode') != 'real'
            or gate.get('sourceCleanBefore') is not True or gate.get('sourceCleanAfter') is not True
            or gate.get('blockers') != [] or gate.get('failures') != []):
        raise ValueError('group is incomplete or bound to different clean real source/version/policy: ' + name)
    attachments = gate.get('attachments')
    if not isinstance(attachments, dict) or not attachments:
        raise ValueError('group lacks retained raw evidence: ' + name)
    for relative, expected in attachments.items():
        if not isinstance(relative, str) or not isinstance(expected, str) or not re.fullmatch('[a-f0-9]{64}', expected):
            raise ValueError('invalid group attachment digest: ' + name)
        if staged.contained_digest(evidence, relative) != expected:
            raise ValueError('group attachment digest mismatch: ' + name)
    if not exact_outcomes(gate.get('passedChecks'), REQUIRED_CHECKS[name]):
        raise ValueError('required checks missing, duplicated or unexpected: ' + name)
    if name != 'source' and gate.get('inventorySHA256') != inventory_sha256:
        raise ValueError('artifact group must bind exact staged bytes: ' + name)
    if name in {'installation', 'working-product', 'documentation'} and gate.get('cleanupStatus') != 'passed':
        raise ValueError('resource group requires verified cleanup: ' + name)
    if name == 'artifact-integrity':
        if (gate.get('correspondingSource') != source_binding
                or gate.get('runtimeSourceLicenseStatus') != 'qualified'
                or gate.get('independentlyVerifiedKernelSignature') is not True
                or type(gate.get('unresolvedP0P1')) is not int or gate['unresolvedP0P1'] != 0):
            raise ValueError('artifact integrity requires verified source/licenses and zero unresolved P0/P1')
    if name == 'working-product':
        providers = gate.get('providerChecks')
        if (not isinstance(providers, dict) or set(providers) != PROVIDERS
                or any(not exact_outcomes(checks, PROVIDER_CHECKS) for checks in providers.values())):
            raise ValueError('each declared provider requires one complete real lifecycle and output checks')
    if name == 'documentation':
        site_commit = gate.get('websiteCommit')
        if (not exact_outcomes(gate.get('passedWebsiteChecks'), WEBSITE_CHECKS)
                or not isinstance(site_commit, str) or not re.fullmatch('[a-f0-9]{40}', site_commit)
                or site_commit == '0' * 40 or gate.get('websiteSourceClean') is not True):
            raise ValueError('clean exact website checks required')


def arguments():
    p = argparse.ArgumentParser()
    for name in ('commit', 'version', 'run', 'attempt', 'producer', 'acceptance-run'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--stage', type=pathlib.Path, required=True)
    p.add_argument('--evidence', type=pathlib.Path, required=True)
    p.add_argument('--output', type=pathlib.Path, required=True)
    return p.parse_args()

def accept(a):
    actual = staged.inventory(a.stage, a.commit, a.version, a.run, a.attempt)
    inventory_path = a.stage / 'stage-inventory.json'
    inventory_hash = staged.digest(inventory_path)
    if staged.load(inventory_path, expected_sha256=inventory_hash) != actual:
        raise ValueError('staged inventory changed')
    independently_verified_source=staged.source_stage.verify_contract(a.stage,a.commit,a.version)
    if independently_verified_source!=actual['correspondingSource']:
        raise ValueError('independent source verification differs from staged inventory')
    gates = {}
    for name in sorted(staged.REQUIRED_GATES):
        path = a.evidence / (name + '.json')
        receipt_hash = staged.contained_digest(a.evidence, path.name)
        gate = staged.load(path, expected_sha256=receipt_hash)
        validate_gate(name, gate, a.evidence, a.commit, a.version, inventory_hash,
                      independently_verified_source)
        if staged.contained_digest(a.evidence, path.name) != receipt_hash:
            raise ValueError('gate receipt changed during acceptance: ' + name)
        gates[name] = dict(status='passed', sourceCommit=a.commit, version=a.version, receiptSHA256=receipt_hash)
    if staged.digest(inventory_path) != inventory_hash:
        raise ValueError('staged inventory changed during acceptance')
    receipt = dict(kind='hostwright.promotion-receipt.v3', qualificationPolicy=staged.QUALIFICATION_POLICY, sourceCommit=a.commit, version=a.version,
                   buildRunID=a.run, buildRunAttempt=a.attempt, inventorySHA256=inventory_hash,
                   files=actual['files'], correspondingSource=independently_verified_source, gates=gates, acceptanceActor=a.producer, producer=a.producer, acceptanceRunID=a.acceptance_run)
    with a.output.open('x') as handle:
        json.dump(receipt, handle, sort_keys=True, separators=(',', ':'))
        handle.write('\n')

if __name__ == "__main__":
    accept(arguments())
