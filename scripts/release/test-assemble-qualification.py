#!/usr/bin/env python3
import argparse
import copy
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


assembler = module('assembler', 'assemble-qualification.py')
fixtures = module('fixtures', 'test-staged-release.py')
stage = assembler.staged


class AssemblyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.bundle = self.root / 'stage'
        self.raw = self.root / 'input'
        self.raw.mkdir()
        (self.bundle / 'release').mkdir(parents=True)
        (self.bundle / 'Formula').mkdir()
        manifest = dict(sourceCommit='a'*40, packageVersion='0.0.2', releaseTag='v0.0.2')
        for key, name in [('archive','artifact.zip'), ('package','artifact.pkg'),
                          ('archiveSBOM','archive.spdx.json'), ('packageSBOM','pkg.spdx.json')]:
            path = self.bundle / 'release' / name
            path.write_bytes(key.encode())
            manifest[key] = dict(fileName=name, sha256=stage.digest(path))
        for name in ('release-manifest.json.cms','SHA256SUMS','SHA256SUMS.cms',
                     'provenance.intoto.json','provenance.intoto.json.cms',
                     'release-evidence.json','release-evidence.json.cms'):
            (self.bundle / 'release' / name).write_text('cryptographic fixture')
        (self.bundle / 'release/release-manifest.json').write_text(json.dumps(manifest))
        (self.bundle / 'Formula/hostwright.rb').write_text('formula')
        self.binding = fixtures.source_fixture(self.bundle)
        inventory = stage.inventory(self.bundle, 'a'*40, '0.0.2', '123', '1')
        (self.bundle / 'stage-inventory.json').write_text(json.dumps(inventory))
        inventory_hash = stage.digest(self.bundle / 'stage-inventory.json')
        self.inputs = dict(kind='hostwright.qualification-inputs.v1', gates={})
        self.reports = {}
        for name in stage.REQUIRED_GATES:
            lane = self.raw / name
            lane.mkdir()
            (lane / 'raw.log').write_text('retained command output; exit=0')
            raw_hash = stage.digest(lane / 'raw.log')
            self.review_hash = raw_hash
            gate = fixtures.gate_fixture(name, raw_hash, inventory_hash, self.binding)
            path = lane / 'complete.json'
            path.write_text(json.dumps(gate))
            self.reports[name] = gate
            self.inputs['gates'][name] = f'{name}/complete.json'
        self.input_path = self.raw / 'qualification-inputs.json'
        self.input_path.write_text(json.dumps(self.inputs))
        self.args = argparse.Namespace(commit='a'*40, version='0.0.2', run='123', attempt='1',
            reviewer='reviewer', review_sha256=self.review_hash, stage=self.bundle,
            input_root=self.raw, inputs='qualification-inputs.json', output=self.root / 'export')

    def assemble(self):
        with mock.patch.object(stage.source_stage, 'verify_contract', return_value=self.binding):
            return assembler.assemble(self.args)

    def test_real_receipt_export_roundtrips_retention_and_acceptance(self):
        digest = self.assemble()
        output = self.args.output
        inventory = stage.load(output / 'evidence-inventory.json')
        self.assertEqual(digest, stage.digest(output / 'evidence-inventory.json'))
        self.assertEqual(set(inventory['files']), {p.relative_to(output).as_posix()
            for p in output.rglob('*') if p.is_file() and p.name != 'evidence-inventory.json'})
        fixtures.retention.retain(output, self.root / 'retained', digest, 'a'*40, '0.0.2')
        args = argparse.Namespace(**vars(self.args), evidence=output, producer='maintainer', acceptance_run='456')
        args.output = self.root / 'accepted.json'
        with mock.patch.object(stage.source_stage, 'verify_contract', return_value=self.binding):
            assembler.acceptance.accept(args)
        self.assertEqual(set(stage.load(args.output)['gates']), stage.REQUIRED_GATES)
        raw = output / 'raw/critical-fuzz/complete.json'
        self.assertEqual(raw.read_bytes(), (self.raw / 'critical-fuzz/complete.json').read_bytes())
        with self.assertRaises(ValueError): self.assemble()

    def test_invalid_lane_never_creates_an_export(self):
        path = self.raw / 'local-backup-recovery/complete.json'
        original = self.reports['local-backup-recovery']
        changes = [('sourceCommit','b'*40), ('version','0.0.2-rc.2'), ('status','blocked'),
                   ('executionMode','mock'), ('sourceCleanAfter',False),
                   ('cleanupStatus','failed'), ('inventorySHA256','f'*64),
                   ('passedOperations',[]), ('attachments',{}), ('blockers',['unsupported'])]
        for field, value in changes:
            changed = copy.deepcopy(original); changed[field] = value
            path.write_text(json.dumps(changed))
            with self.subTest(field=field), self.assertRaises(ValueError): self.assemble()
            self.assertFalse(self.args.output.exists())
        path.write_text('[]')
        with self.assertRaisesRegex(ValueError, 'must be an object'): self.assemble()
        self.assertFalse(self.args.output.exists())
        path.write_text(json.dumps(original))
        (self.raw / 'local-backup-recovery/raw.log').write_text('tampered output')
        with self.assertRaises(ValueError): self.assemble()
        self.assertFalse(self.args.output.exists())

    def test_missing_gate_and_unsafe_raw_paths_are_rejected(self):
        changed=copy.deepcopy(self.inputs); changed['gates'].pop('public-education')
        self.input_path.write_text(json.dumps(changed))
        with self.assertRaises(ValueError): self.assemble()
        self.input_path.write_text(json.dumps(self.inputs))
        report=self.raw/'public-education/complete.json'
        raw=report.read_bytes(); report.unlink()
        outside=self.root/'outside.json'; outside.write_bytes(raw); report.symlink_to(outside)
        with self.assertRaises(ValueError): self.assemble()
        report.unlink(); report.write_bytes(raw)
        changed=copy.deepcopy(self.reports['public-education'])
        changed['attachments']={'../critical-fuzz/raw.log':self.review_hash}
        report.write_text(json.dumps(changed))
        with self.assertRaises(ValueError): self.assemble()
        self.assertFalse(self.args.output.exists())

    def test_changed_json_cannot_be_parsed_under_an_older_digest(self):
        original_load = stage.load
        targets = [self.bundle / 'stage-inventory.json', self.input_path,
                   self.raw / 'public-education/complete.json']
        for target in targets:
            original = target.read_bytes()
            def swap_before_parse(path, expected_sha256=None):
                if path == target:
                    target.write_bytes(original + b'\n')
                    try:
                        return original_load(path, expected_sha256=expected_sha256)
                    finally:
                        target.write_bytes(original)
                return original_load(path, expected_sha256=expected_sha256)
            with self.subTest(path=target.name), mock.patch.object(stage, 'load', side_effect=swap_before_parse):
                with self.assertRaisesRegex(ValueError, 'between binding and parsing'):
                    self.assemble()
            self.assertFalse(self.args.output.exists())

    def test_acceptance_binds_parsed_gate_and_inventory_bytes(self):
        self.assemble()
        args = argparse.Namespace(**vars(self.args), evidence=self.args.output,
                                  producer='maintainer', acceptance_run='456')
        args.output = self.root / 'accepted.json'
        original_load = stage.load
        for target in (self.bundle / 'stage-inventory.json',
                       args.evidence / 'public-education.json'):
            original = target.read_bytes()
            for timing in ('before-parse', 'after-parse'):
                def replace_during_read(path, expected_sha256=None):
                    if path == target:
                        if timing == 'before-parse':
                            target.write_bytes(original + b'\n')
                        value = original_load(path, expected_sha256=expected_sha256)
                        if timing == 'after-parse':
                            target.write_bytes(original + b'\n')
                        return value
                    return original_load(path, expected_sha256=expected_sha256)
                try:
                    with self.subTest(path=target.name, timing=timing), \
                         mock.patch.object(stage, 'load', side_effect=replace_during_read), \
                         mock.patch.object(stage.source_stage, 'verify_contract', return_value=self.binding):
                        with self.assertRaises(ValueError):
                            assembler.acceptance.accept(args)
                    self.assertFalse(args.output.exists())
                finally:
                    target.write_bytes(original)


if __name__ == '__main__':
    unittest.main()
