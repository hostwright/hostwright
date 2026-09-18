#!/usr/bin/env python3
"""Read-only shell contract tests; fixture bytes never represent live receipts."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('qualify-vendor-tap.sh')
NAMES = ['hostwright','hostwright-control','hostwright-dist','hostwrightd','hostwright-containerization-helper','hostwright-network-helper','hostwright-network-provider-worker','hostwright-storage-helper']

def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()

class VendorTapContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='.vendor-tap-unit-',dir=Path.home())
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.root.chmod(0o700)
        self.env = {k:v for k,v in os.environ.items() if not k.startswith('HOSTWRIGHT_')}
        self.env.update(HOSTWRIGHT_BASELINE_RELEASE_COMMIT='a'*40,HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT='b'*40,
                        HOSTWRIGHT_BASELINE_TAP_COMMIT='c'*40,HOSTWRIGHT_CANDIDATE_TAP_COMMIT='d'*40)
        self.inventory_path = self.root/'input.json'
        self.inventory = None

    def run_contract(self):
        return subprocess.run(['/bin/bash',str(SCRIPT),'validate-contract'],env=self.env,capture_output=True,text=True,timeout=10)

    def run_function(self, operation, *args):
        # Execute actual function bodies without dispatching any live stage.
        definitions = SCRIPT.read_text().split('\ncommand="${1:-}"\n')[0]
        return subprocess.run(['/bin/bash','-s','--',operation,*map(str,args)],input=definitions+'\nconfigure_versions\nvalidate_contract\ninventory_check "$@"\n',
                              env=self.env,capture_output=True,text=True,timeout=10)

    def receipts(self, baseline='0.0.2-dev.12',candidate='0.0.2-rc.1'):
        self.env.update(HOSTWRIGHT_BASELINE_VERSION=baseline,HOSTWRIGHT_CANDIDATE_VERSION=candidate,
                        HOSTWRIGHT_BASELINE_TAG='v'+baseline,HOSTWRIGHT_CANDIDATE_TAG='v'+candidate)
        self.inventory={'schemaVersion':1,'kind':'hostwright.vendor-tap-inputs.v1'}
        for role,version,commit,tap in [('baseline',baseline,'a'*40,'c'*40),('candidate',candidate,'b'*40,'d'*40)]:
            directory=self.root/role;directory.mkdir(mode=0o700)
            files=[]
            for name in NAMES:
                file=directory/'payload/bin'/name;file.parent.mkdir(parents=True,exist_ok=True)
                file.write_bytes(('unit fixture '+role+' '+name).encode());files.append({'path':'bin/'+name,'sha256':sha(file)})
            item={'version':version,'tag':'v'+version,'sourceCommit':commit,'tapCommit':tap,'payloadFiles':files}
            if '-dev.' in version: number=int(version.split('-dev.')[1])
            elif '-rc.' in version:number=1000+int(version.split('-rc.')[1])
            else:number=2000
            item['packageReceiptVersion']='0.0.2.'+str(number)
            for kind,ext in [('archive','zip'),('package','pkg')]:
                name=f'hostwright-{version}-macos-arm64-{commit[:12]}.{ext}'
                file=directory/name;file.write_bytes(('unit '+kind+' '+role).encode())
                item[kind]={'fileName':name,'sha256':sha(file)}
            formula=directory/'hostwright.rb';formula.write_text('unit formula '+role);item['formulaSHA256']=sha(formula)
            manifest={k:item[k] for k in ['archive','package','payloadFiles']}
            manifest.update(releaseTag='v'+version,packageVersion=version,sourceCommit=commit,sourceDirty=False)
            file=directory/'release-manifest.json';file.write_text(json.dumps(manifest));item['releaseManifestSHA256']=sha(file)
            self.inventory[role]=item
        self.write_inventory()

    def write_inventory(self):
        self.inventory_path.write_text(json.dumps(self.inventory));self.inventory_path.chmod(0o600)
        self.env.update(HOSTWRIGHT_ARTIFACT_INVENTORY=str(self.inventory_path),HOSTWRIGHT_ARTIFACT_INVENTORY_SHA256=sha(self.inventory_path))

    def test_historical_contract_preserved_and_exact_commits_required(self):
        self.assertEqual(self.run_contract().returncode,0)
        self.env['HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT']='a'*40
        self.assertNotEqual(self.run_contract().returncode,0)
        self.env['HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT']='main'
        self.assertNotEqual(self.run_contract().returncode,0)

    def test_explicit_versions_require_all_tags_and_receipt_inventory(self):
        self.env['HOSTWRIGHT_BASELINE_VERSION']='0.0.2-dev.11'
        self.assertIn('partial overrides',self.run_contract().stderr)
        self.env.update(HOSTWRIGHT_CANDIDATE_VERSION='0.0.2',HOSTWRIGHT_BASELINE_TAG='v0.0.2-dev.11',HOSTWRIGHT_CANDIDATE_TAG='v0.0.2')
        self.assertIn('receipt inventory',self.run_contract().stderr)
        self.env['HOSTWRIGHT_CANDIDATE_TAG']='v0.0.2-rc.1'
        self.assertIn('exactly match',self.run_contract().stderr)

    def test_dev_rc_stable_ordering_and_receipt_values(self):
        for baseline,candidate in [('0.0.2-dev.11','0.0.2-dev.12'),('0.0.2-dev.999','0.0.2-rc.1'),('0.0.2-rc.99','0.0.2')]:
            with self.subTest(pair=(baseline,candidate)):
                # Each pair gets separate fixture storage.
                self.root=self.root/str(len(list(self.root.iterdir())));self.root.mkdir(mode=0o700);self.inventory_path=self.root/'input.json'
                self.receipts(baseline,candidate)
                result=self.run_function('summary');self.assertEqual(result.returncode,0,result.stderr)
                observed=json.loads(result.stdout);self.assertEqual(observed['baseline']['version'],baseline);self.assertEqual(observed['candidate']['version'],candidate)
                self.assertEqual(observed['inventorySHA256'],sha(self.inventory_path))

    def test_downgrades_equal_versions_and_unsupported_channels_rejected(self):
        for baseline,candidate in [('0.0.2','0.0.2-rc.99'),('0.0.2-rc.1','0.0.2-dev.999'),('0.0.2-dev.12','0.0.2-dev.12'),('0.0.2-dev.1000','0.0.2'),('0.0.2-rc.0','0.0.2'),('0.0.2-rc.100','0.0.2'),('0.0.2-dev.01','0.0.2'),('0.0.2-dev.11','0.0.2-beta.1'),('0.0.2-dev.11','0.0.2+build'),('0.0.2-dev.11','0.0.3')]:
            self.env.update(HOSTWRIGHT_BASELINE_VERSION=baseline,HOSTWRIGHT_CANDIDATE_VERSION=candidate,HOSTWRIGHT_BASELINE_TAG='v'+baseline,HOSTWRIGHT_CANDIDATE_TAG='v'+candidate)
            self.assertNotEqual(self.run_contract().returncode,0,(baseline,candidate))

    def test_receipt_inventory_binds_tags_sources_taps_and_canonical_receipt(self):
        self.receipts();original=copy.deepcopy(self.inventory)
        for field,value in [('tag','vwrong'),('sourceCommit','f'*40),('tapCommit','e'*40),('packageReceiptVersion','0.0.2.1')]:
            self.inventory=copy.deepcopy(original);self.inventory['candidate'][field]=value;self.write_inventory()
            self.assertNotEqual(self.run_contract().returncode,0,field)

    def test_missing_ambiguous_or_unsafe_full_inventory_rejected(self):
        self.receipts();original=copy.deepcopy(self.inventory)
        for field in ['archive','package','payloadFiles','formulaSHA256','releaseManifestSHA256']:
            self.inventory=copy.deepcopy(original);del self.inventory['candidate'][field];self.write_inventory()
            self.assertNotEqual(self.run_contract().returncode,0,field)
        self.inventory=copy.deepcopy(original);self.inventory['candidate']['payloadFiles'].pop();self.write_inventory()
        self.assertIn('required executable',self.run_contract().stderr)
        self.inventory=copy.deepcopy(original);self.inventory['candidate']['payloadFiles'].append(self.inventory['candidate']['payloadFiles'][0]);self.write_inventory()
        self.assertIn('Duplicate',self.run_contract().stderr)
        self.inventory=copy.deepcopy(original);self.inventory['candidate']['payloadFiles'][0]['path']='../escape';self.write_inventory()
        self.assertIn('Unsafe payload',self.run_contract().stderr)

    def test_receipt_file_digest_private_mode_and_symlink_rejected(self):
        self.receipts();self.inventory_path.write_text('{}');self.assertIn('SHA256 mismatch',self.run_contract().stderr)
        self.write_inventory();self.inventory_path.chmod(0o644);self.assertIn('private bounded',self.run_contract().stderr)
        self.inventory_path.chmod(0o600);link=self.root/'link';link.symlink_to(self.inventory_path);self.env['HOSTWRIGHT_ARTIFACT_INVENTORY']=str(link)
        self.assertNotEqual(self.run_contract().returncode,0)

    def test_actual_formula_archive_package_and_installed_bytes_checked(self):
        self.receipts();item=self.inventory['candidate'];directory=self.root/'candidate';version=item['version']
        paths={'formula':[directory/'hostwright.rb'],'archive':[directory/item['archive']['fileName']],
               'package':[directory/'release-manifest.json',directory/item['package']['fileName']],'installed':[directory/'payload'],'recovery':[directory/'payload/bin/hostwright-dist']}
        for operation,args in paths.items():
            result=self.run_function(operation,version,*args);self.assertEqual(result.returncode,0,result.stderr)
            changed=args[0] if operation!='installed' else args[0]/'bin/hostwright-storage-helper'
            original=changed.read_bytes();changed.write_bytes(original+b'changed')
            self.assertNotEqual(self.run_function(operation,version,*args).returncode,0,operation);changed.write_bytes(original)

    def test_release_manifest_cannot_omit_full_payload_even_if_rebound(self):
        self.receipts();directory=self.root/'candidate';path=directory/'release-manifest.json'
        manifest=json.loads(path.read_text());manifest['payloadFiles'].pop();path.write_text(json.dumps(manifest))
        self.inventory['candidate']['releaseManifestSHA256']=sha(path);self.write_inventory()
        self.assertIn('full artifact receipt',self.run_function('package',self.inventory['candidate']['version'],path,directory/self.inventory['candidate']['package']['fileName']).stderr)

    def test_ambiguous_environment_overrides_are_rejected(self):
        for key in ['HOSTWRIGHT_APPLICATION_SUPPORT_DIR','HOSTWRIGHT_CACHE_DIR','HOSTWRIGHT_LOG_DIR','HOSTWRIGHT_STATE_DB','HOSTWRIGHT_BASELINE_PACKAGE_VERSION','HOSTWRIGHT_CONTAINERIZATION_HELPER_EXECUTABLE','HOSTWRIGHT_OTHER_STATE_ROOT']:
            self.env[key]=''
            self.assertIn('Ambiguous qualification environment',self.run_contract().stderr);del self.env[key]

    def test_durable_reboot_state_binds_versions_tags_and_full_inventory(self):
        self.receipts();state=self.root/'state'
        definitions=SCRIPT.read_text().split('\ncommand="${1:-}"\n')[0]
        def run(body):
            return subprocess.run(['/bin/bash','-s','--',str(state)],input=definitions+'\nstate_file="$1"\nconfigure_versions\nvalidate_contract\n'+body,
                                  env=self.env,capture_output=True,text=True,timeout=10)
        result=run('write_state reboot-required 123 none none\nload_and_verify_state\n')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(len(state.read_text().splitlines()),13)
        self.inventory['extraEvidence']='changed receipt';self.write_inventory()
        self.assertIn('differs from durable state',run('load_and_verify_state\n').stderr)
        # Old unbound state is explicitly refused rather than guessed across releases.
        state.write_text('phase=reboot-required\n'*8)
        self.assertIn('lacks bound version/artifact inventory',run('load_and_verify_state\n').stderr)

    def test_rollback_refusal_cannot_be_swallowed_as_success(self):
        source=SCRIPT.read_text()
        rollback=source.split('sudo -n "$distribution" rollback --prefix "$package_prefix" --output json',1)[1].split('verify_package_state',1)[0]
        self.assertNotIn('||',rollback)
        self.assertIn('set -euo pipefail',source)
        self.assertNotIn('schema7',source)

if __name__=='__main__':unittest.main()
