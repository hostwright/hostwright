#!/usr/bin/env python3
"""Validate retained gate evidence before protected acceptance attests its aggregate."""
import argparse
import importlib.util
import json
import math
import pathlib
import re

spec = importlib.util.spec_from_file_location('staged', pathlib.Path(__file__).with_name('staged-release.py'))
staged = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staged)

VM_OPERATIONS = {
    'archive-install', 'pkg-install', 'reboot', 'upgrade-dev.11', 'upgrade-dev.12',
    'interrupted-upgrade', 'downgrade-refusal', 'authorized-rollback', 're-upgrade',
    'compensation-recovery-repair', 'repair', 'uninstall',
}
RECOVERY_OPERATIONS = {
    'state-backup-restore', 'workload-data-backup-restore', 'interrupted-lifecycle-recovery',
    'daemon-restart-recovery', 'cancellation', 'stale-authority-refusal',
    'exact-owned-cleanup', 'unmanaged-preservation',
}
WEBSITE_CHECKS = {f'{package}-{check}' for package in ('root', 'docs')
                  for check in ('typecheck', 'build', 'links')}
ARTIFACT_GATES = {
    'installed-lifecycle-vm', 'single-host-soak', 'desktop-accessibility',
    'compose-execution', 'signed-notarized-artifacts', 'dependency-security',
    'license-policy-sbom', 'independent-review', 'local-backup-recovery', 'public-education',
}
RESOURCE_GATES = {
    'installed-lifecycle-vm', 'single-host-soak', 'desktop-accessibility',
    'compose-execution', 'local-backup-recovery', 'public-education',
}

def exact_outcomes(value, expected):
    return (isinstance(value, list) and all(isinstance(item, str) for item in value)
            and len(value) == len(expected) and set(value) == expected)

def duration_passed(value, minimum):
    return (type(value) in (int, float) and math.isfinite(value) and value >= minimum)

def validate_gate(name, gate, evidence, commit, version, inventory_sha256,
                  source_binding, reviewer, review_sha256):
    if (not isinstance(gate, dict) or gate.get('sourceCommit') != commit
            or gate.get('version') != version or gate.get('status') != 'passed'
            or gate.get('executionMode') != 'real'
            or gate.get('sourceCleanBefore') is not True or gate.get('sourceCleanAfter') is not True
            or gate.get('blockers') != [] or gate.get('failures') != []):
        raise ValueError('gate is incomplete or bound to different clean real source/version: ' + name)
    attachments = gate.get('attachments')
    if not isinstance(attachments, dict) or not attachments:
        raise ValueError('gate lacks retained raw evidence: ' + name)
    for relative, expected in attachments.items():
        if not isinstance(relative, str) or not isinstance(expected, str) or not re.fullmatch('[a-f0-9]{64}', expected):
            raise ValueError('invalid gate attachment digest: ' + name)
        if staged.contained_digest(evidence, relative) != expected:
            raise ValueError('gate attachment digest mismatch: ' + name)
    provider = name.startswith('provider-')
    if (provider or name in ARTIFACT_GATES) and gate.get('inventorySHA256') != inventory_sha256:
        raise ValueError('executed artifact gate must bind exact staged bytes: ' + name)
    if (provider or name in RESOURCE_GATES) and gate.get('cleanupStatus') != 'passed':
        raise ValueError('resource gate requires verified cleanup: ' + name)
    cycles = gate.get('completedCycles')
    if provider and (gate.get('conformancePassed') is not True or type(cycles) is not int or cycles < 10):
        raise ValueError('provider requires conformance and ten actual cycles')
    if name == 'single-host-soak' and not duration_passed(gate.get('elapsedSeconds'), 1800):
        raise ValueError('soak requires thirty actual minutes')
    if name == 'sanitizers' and not exact_outcomes(gate.get('fullSuiteLanes'), {'address', 'thread'}):
        raise ValueError('both full-suite sanitizer lanes required')
    if name == 'critical-fuzz':
        targets = gate.get('targets')
        expected = {'manifest-v3', 'compose-import', 'control-stream-v2.1', 'containerization-helper-v1', 'apple-container-json', 'release-qualification-json'}
        if (not isinstance(targets, list) or any(not isinstance(t, dict) for t in targets)
                or not exact_outcomes([t.get('target') for t in targets], expected)
                or any(not duration_passed(t.get('elapsedSeconds'), 300) or t.get('status') != 'passed' for t in targets)):
            raise ValueError('all six targets require five actual minutes')
    if name == 'installed-lifecycle-vm' and not exact_outcomes(gate.get('passedOperations'), VM_OPERATIONS):
        raise ValueError('independent VM artifact lifecycle matrix incomplete')
    if name == 'local-backup-recovery' and not exact_outcomes(gate.get('passedOperations'), RECOVERY_OPERATIONS):
        raise ValueError('local state/data and interruption recovery matrix incomplete')
    if name == 'public-education':
        site_commit = gate.get('websiteCommit')
        if (not exact_outcomes(gate.get('passedQuickstarts'), {'cli', 'compose', 'desktop'})
                or not exact_outcomes(gate.get('passedWebsiteChecks'), WEBSITE_CHECKS)
                or not isinstance(site_commit, str) or not re.fullmatch('[a-f0-9]{40}', site_commit)
                or site_commit == '0' * 40 or gate.get('websiteSourceClean') is not True):
            raise ValueError('executed quickstarts and clean exact website checks required')
    if name == 'license-policy-sbom' and (gate.get('correspondingSource') != source_binding
            or gate.get('runtimeSourceLicenseStatus') != 'qualified'
            or gate.get('independentlyVerifiedKernelSignature') is not True):
        raise ValueError('license/source gate lacks exact independently verified qualified source binding')
    if name == 'independent-review':
        if (gate.get('reviewKind') != 'independent-agent' or gate.get('reviewer') != reviewer
                or gate.get('reportSHA256') != review_sha256 or review_sha256 not in attachments.values()
                or type(gate.get('unresolvedP0P1')) is not int or gate['unresolvedP0P1'] != 0):
            raise ValueError('independent review requires exact retained report and no unresolved P0/P1')
def arguments():
    p = argparse.ArgumentParser()
    for name in ('commit', 'version', 'run', 'attempt', 'reviewer', 'producer', 'acceptance-run', 'review-sha256'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--stage', type=pathlib.Path, required=True)
    p.add_argument('--evidence', type=pathlib.Path, required=True)
    p.add_argument('--output', type=pathlib.Path, required=True)
    return p.parse_args()

def accept(a):
    actual = staged.inventory(a.stage, a.commit, a.version, a.run, a.attempt)
    inventory_path = a.stage / 'stage-inventory.json'
    if staged.load(inventory_path) != actual:
        raise ValueError('staged inventory changed')
    independently_verified_source=staged.source_stage.verify_contract(a.stage,a.commit,a.version)
    if independently_verified_source!=actual['correspondingSource']:
        raise ValueError('independent source verification differs from staged inventory')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/-]{0,127}', a.reviewer) or not re.fullmatch(r'[a-f0-9]{64}', a.review_sha256):
        raise ValueError('independent review requires its issuer descriptor and exact report digest')
    gates = {}
    for name in sorted(staged.REQUIRED_GATES):
        path = a.evidence / (name + '.json')
        gate = staged.load(path)
        validate_gate(name, gate, a.evidence, a.commit, a.version, staged.digest(inventory_path),
                      independently_verified_source, a.reviewer, a.review_sha256)
        gates[name] = dict(status='passed', sourceCommit=a.commit, version=a.version, receiptSHA256=staged.digest(a.evidence / (name + '.json')))
    receipt = dict(kind='hostwright.promotion-receipt.v2', sourceCommit=a.commit, version=a.version,
                   buildRunID=a.run, buildRunAttempt=a.attempt, inventorySHA256=staged.digest(inventory_path),
                   files=actual['files'], correspondingSource=independently_verified_source, gates=gates, acceptanceActor=a.producer, producer=a.producer, acceptanceRunID=a.acceptance_run,
                   independentReview=dict(status='approved', reviewKind='independent-agent', issuerClaim=a.reviewer, reviewer=a.reviewer, reportSHA256=a.review_sha256, sourceCommit=a.commit,
                                          inventorySHA256=staged.digest(inventory_path)))
    with a.output.open('x') as handle:
        json.dump(receipt, handle, sort_keys=True, separators=(',', ':'))
        handle.write('\n')

if __name__ == "__main__":
    accept(arguments())
