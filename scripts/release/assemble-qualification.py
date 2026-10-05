#!/usr/bin/env python3
"""Validate real lane receipts and copy their exact bytes into a private export."""
import argparse
import importlib.util
import json
import pathlib
import re
import shutil

spec = importlib.util.spec_from_file_location('acceptance', pathlib.Path(__file__).with_name('accept-qualification.py'))
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)
staged = acceptance.staged


def assemble(a):
    staged.version(a.version)
    if (not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/-]{0,127}', a.reviewer)
            or not re.fullmatch('[a-f0-9]{64}', a.review_sha256)):
        raise ValueError('exact independent reviewer and report digest required')
    if not a.input_root.is_absolute() or not a.output.is_absolute():
        raise ValueError('input and export directories must be explicit absolute paths')
    if a.input_root.is_symlink() or not a.input_root.is_dir() or a.output.exists() or a.output.is_symlink():
        raise ValueError('unsafe input root or existing export')
    actual = staged.inventory(a.stage, a.commit, a.version, a.run, a.attempt)
    inventory_path = a.stage / 'stage-inventory.json'
    inventory_hash = staged.digest(inventory_path)
    if staged.load(inventory_path, expected_sha256=inventory_hash) != actual:
        raise ValueError('staged inventory changed')
    source_binding = staged.source_stage.verify_contract(a.stage, a.commit, a.version)
    if source_binding != actual['correspondingSource']:
        raise ValueError('independent source verification differs from staged inventory')
    inputs_hash = staged.contained_digest(a.input_root, a.inputs)
    inputs = staged.load(a.input_root / a.inputs, expected_sha256=inputs_hash)
    if (not isinstance(inputs, dict) or set(inputs) != {'kind', 'gates'} or inputs['kind'] != 'hostwright.qualification-inputs.v1'
            or not isinstance(inputs['gates'], dict) or set(inputs['gates']) != staged.REQUIRED_GATES):
        raise ValueError('inputs must identify every required gate exactly once')
    gates, files = {}, {}
    for name, relative in sorted(inputs['gates'].items()):
        if not isinstance(relative, str):
            raise ValueError('gate report path must be relative')
        report_hash = staged.contained_digest(a.input_root, relative)
        report_path = pathlib.PurePosixPath(relative)
        gate = staged.load(a.input_root / relative, expected_sha256=report_hash)
        if not isinstance(gate, dict):
            raise ValueError('raw gate report must be an object: ' + name)
        attachments = gate.get('attachments')
        if not isinstance(attachments, dict) or not attachments:
            raise ValueError('raw report lacks command evidence: ' + name)
        rebased = {}
        for attachment, expected in attachments.items():
            if not isinstance(attachment, str):
                raise ValueError('raw attachment path must be relative')
            # Attachments are relative to the raw report, as emitted by lane wrappers.
            if staged.contained_digest(a.input_root / report_path.parent, attachment) != expected:
                raise ValueError('raw attachment changed: ' + name)
            rebased[str(report_path.parent / attachment)] = expected
        rebased[str(report_path)] = report_hash
        gate['attachments'] = rebased
        acceptance.validate_gate(name, gate, a.input_root, a.commit, a.version,
                                 inventory_hash, source_binding,
                                 a.reviewer, a.review_sha256)
        for path, expected in rebased.items():
            target = 'raw/' + path
            if target in files and files[target] != expected:
                raise ValueError('conflicting raw evidence identity')
            files[target] = expected
        gate['attachments'] = {'raw/' + path: digest for path, digest in rebased.items()}
        gates[name] = gate

    if staged.digest(inventory_path) != inventory_hash:
        raise ValueError('staged inventory changed during assembly')
    # No pass flags or source bindings are synthesized. All validation precedes output.
    a.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    for relative, expected in files.items():
        target = a.output / relative
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (a.input_root / relative.removeprefix('raw/')).open('rb') as source, target.open('xb') as dest:
            shutil.copyfileobj(source, dest)
        target.chmod(0o600)
        if staged.contained_digest(a.output, relative) != expected:
            raise ValueError('raw evidence changed during export; incomplete output retained')
    for name, gate in gates.items():
        path = a.output / (name + '.json')
        with path.open('x') as handle:
            json.dump(gate, handle, sort_keys=True, separators=(',', ':'), allow_nan=False)
            handle.write('\n')
        path.chmod(0o600)
        files[path.name] = staged.digest(path)
    inventory = dict(kind='hostwright.qualification-export.v1', sourceCommit=a.commit,
                     version=a.version, files=files)
    path = a.output / 'evidence-inventory.json'
    with path.open('x') as handle:
        json.dump(inventory, handle, sort_keys=True, separators=(',', ':'), allow_nan=False)
        handle.write('\n')
    path.chmod(0o600)
    return staged.digest(path)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ('commit', 'version', 'run', 'attempt', 'reviewer', 'review-sha256'):
        parser.add_argument('--' + name, required=True)
    for name in ('stage', 'input-root', 'output'):
        parser.add_argument('--' + name, type=pathlib.Path, required=True)
    parser.add_argument('--inputs', default='qualification-inputs.json')
    print(assemble(parser.parse_args()))
