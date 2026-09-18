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
        if (gate.get('sourceCommit') != a.commit or gate.get('version') != a.version
                or gate.get('status') != 'passed' or gate.get('sourceCleanBefore') is not True
                or gate.get('sourceCleanAfter') is not True):
            raise ValueError('gate is incomplete or bound to different final source/version: ' + name)
        attachments = gate.get('attachments', {})
        if not attachments:
            raise ValueError('gate lacks retained raw evidence: ' + name)
        for relative, expected in attachments.items():
            path = pathlib.PurePosixPath(relative)
            if staged.contained_digest(a.evidence, path) != expected:
                raise ValueError('gate attachment digest mismatch: ' + name)
        artifact_gates = {'installed-lifecycle-vm', 'single-host-soak', 'desktop-accessibility', 'compose-execution', 'signed-notarized-artifacts', 'dependency-security', 'license-policy-sbom', 'independent-review'}
        if (name.startswith('provider-') or name in artifact_gates) and gate.get('inventorySHA256') != staged.digest(inventory_path):
            raise ValueError('executed artifact gate must bind exact staged bytes: ' + name)
        if name.startswith('provider-') and (gate.get('conformancePassed') is not True or gate.get('completedCycles', 0) < 10):
            raise ValueError('provider requires conformance and ten actual cycles')
        if name == 'single-host-soak' and gate.get('elapsedSeconds', 0) < 1800:
            raise ValueError('soak requires thirty actual minutes')
        if name == 'sanitizers' and set(gate.get('fullSuiteLanes', [])) != {'address', 'thread'}:
            raise ValueError('both full-suite sanitizer lanes required')
        if name == 'critical-fuzz':
            targets = gate.get('targets', [])
            expected = {'manifest-v3', 'compose-import', 'control-stream-v2.1', 'containerization-helper-v1', 'apple-container-json', 'release-qualification-json'}
            if {t.get('target') for t in targets} != expected or len(targets) != 6 or any(t.get('elapsedSeconds', 0) < 300 or t.get('status') != 'passed' for t in targets):
                raise ValueError('all six targets require five actual minutes')
        if name == 'installed-lifecycle-vm' and set(gate.get('passedOperations', [])) != {'archive-install', 'pkg-install', 'reboot', 'upgrade-dev.11', 'upgrade-dev.12', 'interrupted-upgrade', 'downgrade-refusal', 'authorized-rollback', 'repair', 'uninstall'}:
            raise ValueError('independent VM artifact lifecycle matrix incomplete')
        if name == 'signed-notarized-artifacts' and gate.get('inventorySHA256') != staged.digest(inventory_path):
            raise ValueError('artifact qualification must bind final staged bytes')
        if name == 'license-policy-sbom' and (gate.get('correspondingSource')!=independently_verified_source or gate.get('runtimeSourceLicenseStatus')!='qualified' or gate.get('independentlyVerifiedKernelSignature') is not True):
            raise ValueError('license/source gate lacks exact independently verified qualified source binding')
        if name == 'independent-review':
            if (gate.get('reviewKind') != 'independent-agent' or gate.get('reviewer') != a.reviewer
                    or gate.get('reportSHA256') != a.review_sha256
                    or a.review_sha256 not in attachments.values()):
                raise ValueError('independent agent review report must match exact protected acceptance input')
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
