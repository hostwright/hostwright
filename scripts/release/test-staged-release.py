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
    return dict(sourceCommit='a'*40, version='0.0.2', status='passed', executionMode='real',
                sourceCleanBefore=True, sourceCleanAfter=True, blockers=[], failures=[],
                attachments={'raw.log':raw_hash}, cleanupStatus='passed', unresolvedP0P1=0,
                conformancePassed=True, completedCycles=10, elapsedSeconds=1800,
                fullSuiteLanes=['address','thread'], inventorySHA256=inventory_hash,
                reviewer='reviewer', reviewKind='independent-agent', reportSHA256=raw_hash,
                passedOperations=sorted(acceptance.RECOVERY_OPERATIONS if name == 'local-backup-recovery' else acceptance.VM_OPERATIONS),
                passedQuickstarts=['cli','compose','desktop'], passedWebsiteChecks=sorted(acceptance.WEBSITE_CHECKS),
                websiteCommit='c'*40, websiteSourceClean=True, correspondingSource=source_binding,
                runtimeSourceLicenseStatus='qualified', independentlyVerifiedKernelSignature=True,
                targets=[dict(target=t,elapsedSeconds=300,status='passed') for t in
                         ['manifest-v3','compose-import','control-stream-v2.1','containerization-helper-v1','apple-container-json','release-qualification-json']])

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

    def test_aggregate_requires_all_source_bound_gates_and_review(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary); bundle = root / 'stage'; evidence = root / 'evidence'
            (bundle / 'release').mkdir(parents=True); (bundle / 'Formula').mkdir(); evidence.mkdir()
            manifest = dict(sourceCommit='a'*40, packageVersion='0.0.2', releaseTag='v0.0.2')
            for key, name in [('archive','artifact.zip'), ('package','artifact.pkg'), ('archiveSBOM','artifact.archive.spdx.json'), ('packageSBOM','artifact.pkg.spdx.json')]:
                path = bundle / 'release' / name; path.write_bytes(key.encode()); manifest[key] = dict(fileName=name, sha256=stage.digest(path))
            for name in ('release-manifest.json.cms','SHA256SUMS','SHA256SUMS.cms','provenance.intoto.json','provenance.intoto.json.cms','release-evidence.json','release-evidence.json.cms'):
                (bundle / 'release' / name).write_text('test')
            (bundle / 'release/release-manifest.json').write_text(json.dumps(manifest)); (bundle / 'Formula/hostwright.rb').write_text('formula')
            source_binding=source_fixture(bundle)
            (bundle / 'stage-inventory.json').write_text(json.dumps(stage.inventory(bundle,'a'*40,'0.0.2','123','1')))
            inventory_hash = stage.digest(bundle / 'stage-inventory.json')
            (evidence / 'raw.log').write_text('actual raw evidence fixture')
            for name in stage.REQUIRED_GATES:
                gate = gate_fixture(name, stage.digest(evidence/'raw.log'), inventory_hash, source_binding)
                (evidence / (name+'.json')).write_text(json.dumps(gate))
            command = [sys.executable,str(pathlib.Path(__file__).with_name('accept-qualification.py')),'--commit','a'*40,'--version','0.0.2','--run','123','--attempt','1','--reviewer','reviewer','--review-sha256',stage.digest(evidence/'raw.log'),'--producer','producer','--acceptance-run','456','--stage',str(bundle),'--evidence',str(evidence),'--output',str(root/'receipt.json')]
            def run_acceptance():
                values={command[i][2:].replace('-','_'):command[i+1] for i in range(2,len(command),2)}
                for key in ('stage','evidence','output'):values[key]=pathlib.Path(values[key])
                with mock.patch.object(stage.source_stage,'verify_contract',return_value=source_binding) as verifier:
                    try:acceptance.accept(argparse.Namespace(**values)); verifier.assert_called_once_with(bundle,'a'*40,'0.0.2'); return 0
                    except ValueError:return 1
            self.assertEqual(run_acceptance(),0)
            receipt = json.loads((root/'receipt.json').read_text()); self.assertEqual(set(receipt['gates']),stage.REQUIRED_GATES)
            verify = [sys.executable,str(pathlib.Path(__file__).with_name('staged-release.py')),'receipt','--commit','a'*40,'--version','0.0.2','--run','123','--attempt','1','--root',str(bundle),'--receipt',str(root/'receipt.json')]
            self.assertEqual(subprocess.run(verify,capture_output=True).returncode,0)
            receipt['gates'].pop('critical-fuzz'); (root/'receipt.json').write_text(json.dumps(receipt))
            self.assertNotEqual(subprocess.run(verify,capture_output=True).returncode,0)
            (root/'receipt.json').unlink()
            gate_path = evidence/'critical-fuzz.json'; gate=json.loads(gate_path.read_text()); gate['targets'][0]['elapsedSeconds']=299; gate_path.write_text(json.dumps(gate))
            self.assertNotEqual(run_acceptance(),0)
            gate['targets'][0]['elapsedSeconds']=300; gate['version']='0.0.2-rc.1'; gate_path.write_text(json.dumps(gate))
            self.assertNotEqual(run_acceptance(),0)
            gate['version']='0.0.2'; gate_path.write_text(json.dumps(gate))
            for lane in ('installed-lifecycle-vm', 'single-host-soak', 'desktop-accessibility', 'compose-execution', 'signed-notarized-artifacts', 'dependency-security', 'license-policy-sbom', 'local-backup-recovery', 'public-education'):
                if lane not in stage.REQUIRED_GATES: continue
                lane_path=evidence/(lane+'.json'); original=json.loads(lane_path.read_text()); changed=dict(original); changed['inventorySHA256']='b'*64; lane_path.write_text(json.dumps(changed))
                self.assertNotEqual(run_acceptance(),0,lane)
                lane_path.write_text(json.dumps(original))
            vm=evidence/'installed-lifecycle-vm.json'; original=json.loads(vm.read_text()); changed=dict(original); changed['passedOperations']=['install','reboot','upgrade','rollback','repair','uninstall']; vm.write_text(json.dumps(changed))
            self.assertNotEqual(run_acceptance(),0)
            vm.write_text(json.dumps(original))
            review=evidence/'independent-review.json'; original=json.loads(review.read_text())
            for field, value in [('reportSHA256', 'b'*64), ('reviewKind', 'external-human')]:
                changed=dict(original); changed[field]=value; review.write_text(json.dumps(changed))
                self.assertNotEqual(run_acceptance(),0)
            review.write_text(json.dumps(original))
            outside=root/'outside'; outside.mkdir(); (outside/'raw.log').write_bytes((evidence/'raw.log').read_bytes())
            (evidence/'linked').symlink_to(outside, target_is_directory=True)
            changed=dict(original); changed['attachments']={'linked/raw.log':stage.digest(outside/'raw.log')}; review.write_text(json.dumps(changed))
            self.assertNotEqual(run_acceptance(),0)
            review.write_text(json.dumps(original))
            (evidence/'raw.log').write_text('tampered')
            self.assertNotEqual(run_acceptance(),0)

class QualificationGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        (self.root / 'raw.log').write_text('command exit=0; actual observations retained')
        self.raw_hash = stage.digest(self.root / 'raw.log')

    def validate(self, name, gate):
        acceptance.validate_gate(name, gate, self.root, 'a'*40, '0.0.2', 'b'*64,
                                 {}, 'reviewer', self.raw_hash)

    def gate(self, name):
        return gate_fixture(name, self.raw_hash, 'b'*64, {})

    def test_recovery_requires_every_real_outcome(self):
        original = self.gate('local-backup-recovery')
        self.validate('local-backup-recovery', original)
        for outcome in acceptance.RECOVERY_OPERATIONS:
            changed = copy.deepcopy(original); changed['passedOperations'].remove(outcome)
            with self.subTest(outcome=outcome), self.assertRaises(ValueError):
                self.validate('local-backup-recovery', changed)
        for field, value in [('executionMode','fixture'), ('status','blocked'),
                             ('sourceCleanBefore',False), ('sourceCleanAfter',False),
                             ('blockers',['unavailable provider']), ('failures',['interrupted']),
                             ('cleanupStatus','failed'), ('sourceCommit','c'*40),
                             ('version','0.0.2-rc.2'), ('inventorySHA256','d'*64)]:
            changed = dict(original); changed[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.validate('local-backup-recovery', changed)
        changed=copy.deepcopy(original); changed['passedOperations'].append(changed['passedOperations'][0])
        with self.assertRaises(ValueError): self.validate('local-backup-recovery', changed)

    def test_vm_requires_reupgrade_and_compensation_recovery(self):
        original=self.gate('installed-lifecycle-vm')
        self.validate('installed-lifecycle-vm', original)
        for outcome in ('re-upgrade', 'compensation-recovery-repair'):
            changed=copy.deepcopy(original); changed['passedOperations'].remove(outcome)
            with self.subTest(outcome=outcome), self.assertRaises(ValueError):
                self.validate('installed-lifecycle-vm', changed)

    def test_education_requires_each_quickstart_and_both_website_packages(self):
        original=self.gate('public-education')
        self.validate('public-education', original)
        for field in ('passedQuickstarts','passedWebsiteChecks'):
            for outcome in original[field]:
                changed=copy.deepcopy(original); changed[field].remove(outcome)
                with self.subTest(outcome=outcome), self.assertRaises(ValueError):
                    self.validate('public-education', changed)
        for field, value in [('websiteCommit','0'*40), ('websiteCommit','main'), ('websiteSourceClean',False)]:
            changed=dict(original); changed[field]=value
            with self.subTest(field=field,value=value), self.assertRaises(ValueError):
                self.validate('public-education', changed)

    def test_numeric_shortcuts_and_json_nonfinite_are_rejected(self):
        for name, field, values in [('single-host-soak','elapsedSeconds',[float('nan'),float('inf'),True,1799]),
                                    ('provider-apple-container-1.1.0','completedCycles',[True,10.0,9])]:
            for value in values:
                gate=self.gate(name); gate[field]=value
                with self.subTest(name=name,value=value), self.assertRaises(ValueError): self.validate(name,gate)
        path=self.root/'nan.json'; path.write_text('{"elapsedSeconds":NaN}')
        with self.assertRaises(ValueError): stage.load(path)


if __name__ == '__main__': unittest.main()
