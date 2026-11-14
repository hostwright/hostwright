#!/usr/bin/env python3
import argparse
import copy
from unittest import mock
import importlib.util
import json
import pathlib
import tempfile
import subprocess
import sys
import unittest
spec = importlib.util.spec_from_file_location('stage', pathlib.Path(__file__).with_name('staged-release.py'))
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)
retain_spec = importlib.util.spec_from_file_location('retain', pathlib.Path(__file__).with_name('retain-evidence.py'))
retention = importlib.util.module_from_spec(retain_spec)
retain_spec.loader.exec_module(retention)

def source_fixture(root,commit='a'*40,version='0.0.2'):
    source=root/'source';source.mkdir()
    manifest=dict(kind='hostwright.corresponding-source.v1',schemaVersion=1,releaseSourceRevision=commit,version=version,status='prepared-not-release-qualified',publicationRoute='same-github-release-alongside-binaries',upstreamSignatureVerified=True,preparedSourceState=dict(head=commit,clean=True,gitStatusSHA256=stage.source_stage.EMPTY_STATUS_SHA256))
    name=stage.source_stage.archive_name(commit,version);(source/name).write_bytes(b'structural stage fixture; cryptographic verifier tested separately')
    (source/'source-manifest.json').write_bytes(stage.source_stage.canonical(manifest))
    (source/'SOURCE_SHA256SUMS').write_text(stage.digest(source/name)+'  '+name+'\n'+stage.digest(source/'source-manifest.json')+'  source-manifest.json\n')
    return stage.source_stage.descriptor(root,commit,version)

accept_spec=importlib.util.spec_from_file_location('acceptance',pathlib.Path(__file__).with_name('accept-qualification.py'))
acceptance=importlib.util.module_from_spec(accept_spec);accept_spec.loader.exec_module(acceptance)

def gate_fixture(name, raw_hash, inventory_hash, source_binding):
    return dict(qualificationPolicy=stage.QUALIFICATION_POLICY,
                sourceCommit='a'*40, version='0.0.2', status='passed', executionMode='real',
                sourceCleanBefore=True, sourceCleanAfter=True, blockers=[], failures=[],
                attachments={'raw.log':raw_hash}, cleanupStatus='passed', unresolvedP0P1=0,
                inventorySHA256=inventory_hash, passedChecks=sorted(acceptance.REQUIRED_CHECKS[name]),
                providerChecks={p:sorted(acceptance.PROVIDER_CHECKS) for p in acceptance.PROVIDERS},
                passedWebsiteChecks=sorted(acceptance.WEBSITE_CHECKS),
                websiteCommit='c'*40, websiteSourceClean=True, correspondingSource=source_binding,
                runtimeSourceLicenseStatus='qualified', independentlyVerifiedKernelSignature=True)

class StagingTests(unittest.TestCase):
    def test_retention_copies_only_exact_complete_export(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary); evidence = root/'evidence'; evidence.mkdir()
            (evidence/'raw.log').write_text('retained raw evidence')
            for name in stage.REQUIRED_GATES:
                (evidence/(name+'.json')).write_text(json.dumps({'sourceCommit':'a'*40, 'version':'0.0.2'}))
            files={p.name:stage.digest(p) for p in evidence.iterdir()}
            inventory=evidence/'evidence-inventory.json'
            inventory.write_text(json.dumps(dict(kind='hostwright.qualification-export.v1', sourceCommit='a'*40, version='0.0.2', files=files)))
            expected=stage.digest(inventory)
            retention.retain(evidence, root/'copied', expected, 'a'*40, '0.0.2')
            self.assertEqual(stage.digest(root/'copied/raw.log'), files['raw.log'])
            with self.assertRaises(ValueError): retention.retain(evidence, root/'wrong-source', expected, 'b'*40, '0.0.2')
            with self.assertRaises(ValueError): retention.retain(evidence, root/'wrong-version', expected, 'a'*40, '0.0.2-rc.1')
            (evidence/'extra').write_text('unlisted')
            with self.assertRaises(ValueError): retention.retain(evidence, root/'extra-output', expected, 'a'*40, '0.0.2')
            (evidence/'extra').unlink(); (evidence/'raw.log').write_text('changed')
            with self.assertRaises(ValueError): retention.retain(evidence, root/'tampered-output', expected, 'a'*40, '0.0.2')
            self.assertFalse((root/'tampered-output').exists())

    def test_explicit_channel_bounds(self):
        for version in ('0.0.2-dev.1', '0.0.2-dev.999', '0.0.2-rc.1', '0.0.2-rc.99', '0.0.2'):
            self.assertEqual(stage.version(version), version)
        for version in ('0.0.2-dev.0', '0.0.2-dev.1000', '0.0.2-dev.01', '0.0.2-rc.0', '0.0.2-rc.100', '0.0.2+meta', '0.0.3'):
            with self.assertRaises(ValueError): stage.version(version)
    def test_duplicate_json_and_symlink_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            path = root / 'receipt.json'
            path.write_text('{"status":"failed","status":"passed"}')
            with self.assertRaises(ValueError): stage.load(path)
            link = root / 'link'; link.symlink_to(path)
            with self.assertRaises(ValueError): stage.digest(link)
            outside = root / 'outside'; outside.mkdir(); (outside / 'raw.log').write_text('raw')
            evidence = root / 'evidence'; evidence.mkdir(); (evidence / 'linked').symlink_to(outside, target_is_directory=True)
            with self.assertRaises(ValueError): stage.contained_digest(evidence, 'linked/raw.log')
            with self.assertRaises(ValueError): stage.contained_digest(evidence, '../outside/raw.log')
            (evidence / 'raw.log').write_text('raw')
            self.assertEqual(stage.contained_digest(evidence, 'raw.log'), stage.digest(evidence / 'raw.log'))
    def test_exact_inventory_source_version_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary); (root / 'release').mkdir(); (root / 'Formula').mkdir()
            manifest = dict(sourceCommit='a'*40, packageVersion='0.0.2', releaseTag='v0.0.2')
            for key, name in [('archive','artifact.zip'), ('package','artifact.pkg'), ('archiveSBOM','artifact.archive.spdx.json'), ('packageSBOM','artifact.pkg.spdx.json')]:
                path = root / 'release' / name; path.write_bytes(key.encode()); manifest[key] = dict(fileName=name, sha256=stage.digest(path))
            for name in ('release-manifest.json.cms','SHA256SUMS','SHA256SUMS.cms','provenance.intoto.json','provenance.intoto.json.cms','release-evidence.json','release-evidence.json.cms'):
                (root / 'release' / name).write_text('test')
            (root / 'release/release-manifest.json').write_text(json.dumps(manifest)); (root / 'Formula/hostwright.rb').write_text('formula')
            source_fixture(root)
            inventory = stage.inventory(root, 'a'*40, '0.0.2','123','1'); self.assertEqual(len(inventory['files']),16)
            for commit, version in [('b'*40,'0.0.2'), ('a'*40,'0.0.2-rc.1')]:
                with self.assertRaises(ValueError): stage.inventory(root,commit,version,'123','1')
            (root/'release/unexpected').write_text('extra')
            with self.assertRaises(ValueError): stage.inventory(root,'a'*40,'0.0.2','123','1')


class QualificationGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        (self.root / 'raw.log').write_text('command exit=0; actual observations retained')
        self.raw_hash = stage.digest(self.root / 'raw.log')

    def validate(self, name, gate):
        acceptance.validate_gate(name, gate, self.root, 'a'*40, '0.0.2', 'b'*64, {})

    def gate(self, name):
        return gate_fixture(name, self.raw_hash, 'b'*64, {})

    def test_each_group_requires_its_checks_without_duplicates(self):
        for name in stage.REQUIRED_GATES:
            original = self.gate(name)
            self.validate(name, original)
            for outcome in original['passedChecks']:
                changed = copy.deepcopy(original); changed['passedChecks'].remove(outcome)
                with self.subTest(name=name, missing=outcome), self.assertRaises(ValueError):
                    self.validate(name, changed)
            changed = copy.deepcopy(original); changed['passedChecks'].append(changed['passedChecks'][0])
            with self.assertRaises(ValueError): self.validate(name, changed)

    def test_failed_cleanup_wrong_source_and_artifact_cannot_pass(self):
        for name in stage.REQUIRED_GATES:
            fields = [('executionMode','fixture'), ('status','blocked'), ('sourceCleanBefore',False),
                      ('sourceCleanAfter',False), ('blockers',['unavailable']), ('failures',['failed']),
                      ('sourceCommit','c'*40), ('version','0.0.2-rc.2'), ('qualificationPolicy','old')]
            if name != 'source': fields.append(('inventorySHA256','d'*64))
            if name in {'installation','working-product','documentation'}: fields.append(('cleanupStatus','failed'))
            for field, value in fields:
                changed = self.gate(name); changed[field] = value
                with self.subTest(name=name, field=field), self.assertRaises(ValueError):
                    self.validate(name, changed)

    def test_every_provider_requires_stats_logs_and_one_lifecycle(self):
        for provider in acceptance.PROVIDERS:
            for operation in acceptance.PROVIDER_CHECKS:
                changed = self.gate('working-product'); changed['providerChecks'][provider].remove(operation)
                with self.subTest(provider=provider, operation=operation), self.assertRaises(ValueError):
                    self.validate('working-product', changed)
        changed = self.gate('working-product'); changed['providerChecks'].pop(next(iter(acceptance.PROVIDERS)))
        with self.assertRaises(ValueError): self.validate('working-product', changed)

    def test_content_findings_and_tampered_evidence_are_rejected(self):
        for field, value in [('unresolvedP0P1',1), ('unresolvedP0P1',False),
                             ('correspondingSource',{'wrong':True}), ('runtimeSourceLicenseStatus','pending'),
                             ('independentlyVerifiedKernelSignature',False)]:
            changed=self.gate('artifact-integrity'); changed[field]=value
            with self.subTest(field=field), self.assertRaises(ValueError): self.validate('artifact-integrity',changed)
        (self.root/'raw.log').write_text('tampered')
        with self.assertRaises(ValueError): self.validate('source',self.gate('source'))

    def test_website_checks_remain_bound_to_a_clean_commit(self):
        for field,value in [('websiteCommit','main'),('websiteCommit','0'*40),('websiteSourceClean',False),('passedWebsiteChecks',[])]:
            changed=self.gate('documentation'); changed[field]=value
            with self.subTest(field=field), self.assertRaises(ValueError): self.validate('documentation',changed)
        path=self.root/'nan.json'; path.write_text('{"duration":NaN}')
        with self.assertRaises(ValueError): stage.load(path)


if __name__ == '__main__': unittest.main()
