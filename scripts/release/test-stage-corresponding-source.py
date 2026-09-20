#!/usr/bin/env python3
import copy,importlib.util,pathlib,tempfile,unittest
from unittest import mock
spec=importlib.util.spec_from_file_location('fixtures',pathlib.Path(__file__).with_name('test-staged-release.py'));fixtures=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixtures)
source=fixtures.stage.source_stage
spec=importlib.util.spec_from_file_location('signature',pathlib.Path(__file__).with_name('verify-kernel-source-signature.py'));signature=importlib.util.module_from_spec(spec);spec.loader.exec_module(signature)
class SourceTests(unittest.TestCase):
 def test_dirty_wrong_source_version_and_signature_refused(self):
  with tempfile.TemporaryDirectory() as temporary:
   root=pathlib.Path(temporary);fixtures.source_fixture(root)
   path=root/'source/source-manifest.json';original=source.parse(path.read_bytes())
   for update in [dict(version='0.0.2-rc.1'),dict(releaseSourceRevision='b'*40),dict(upstreamSignatureVerified=False),dict(preparedSourceState=dict(head='a'*40,clean=False,gitStatusSHA256=source.EMPTY_STATUS_SHA256)),dict(preparedSourceState=dict(head='a'*40,clean=True,gitStatusSHA256='0'*64))]:
    body=copy.deepcopy(original);body.update(update)
    with self.assertRaises(ValueError):source.validate_manifest(body,'a'*40,'0.0.2')
 def test_missing_extra_tampered_and_symlink_assets_refused(self):
  with tempfile.TemporaryDirectory() as temporary:
   root=pathlib.Path(temporary);binding=fixtures.source_fixture(root);directory=root/'source';archive=directory/binding['archive']['fileName']
   archive.write_bytes(b'tampered')
   with self.assertRaises(ValueError):source.descriptor(root,'a'*40,'0.0.2')
   archive.unlink()
   with self.assertRaises(ValueError):source.descriptor(root,'a'*40,'0.0.2')
   archive.symlink_to(directory/'source-manifest.json')
   with self.assertRaises(ValueError):source.descriptor(root,'a'*40,'0.0.2')
 def test_failed_install_cleans_only_new_source_directory(self):
  with tempfile.TemporaryDirectory() as temporary:
   root=pathlib.Path(temporary);prepared=root/'prepared';prepared.mkdir();fixtures.source_fixture(prepared);stage=root/'stage';stage.mkdir();(stage/'historic').write_bytes(b'preserve')
   with mock.patch.object(source,'verify_contract',side_effect=ValueError('unqualified runtime')):
    with self.assertRaises(ValueError):source.install(stage,prepared/'source','a'*40,'0.0.2')
   self.assertFalse((stage/'source').exists());self.assertEqual((stage/'historic').read_bytes(),b'preserve')
   (stage/'source').mkdir();(stage/'source/owned-by-other').write_bytes(b'preserve')
   with self.assertRaises(ValueError):source.install(stage,prepared/'source','a'*40,'0.0.2')
   self.assertEqual((stage/'source/owned-by-other').read_bytes(),b'preserve')
 def test_contract_invokes_independent_verifier_and_compares_product_source_evidence(self):
  import io,tarfile,zipfile,subprocess
  with tempfile.TemporaryDirectory() as temporary:
   root=pathlib.Path(temporary);binding=fixtures.source_fixture(root);directory=root/'source';manifest=(directory/'source-manifest.json').read_bytes()
   runtime=dict(kind='hostwright.runtime-license-inventory.v1',schemaVersion=1,status='qualified',assets=[dict(identity=identity,status='qualified',blockers=[],licenseExpression='Apache-2.0',sourceDistributionEvidence={'files':['exact']}) for identity in ('kata-linux-kernel','apple-vminit-oci','hostwright-netfilter-loader')])
   archive=directory/binding['archive']['fileName']
   with tarfile.open(archive,'w:gz') as tar:
    for name,data in [('source-manifest.json',manifest),('licenses/runtime-license-inventory.json',source.canonical(runtime))]:
     info=tarfile.TarInfo(name);info.size=len(data);tar.addfile(info,io.BytesIO(data))
   (directory/'SOURCE_SHA256SUMS').write_text(source.sha(archive)+'  '+archive.name+'\n'+source.sha(directory/'source-manifest.json')+'  source-manifest.json\n')
   release=root/'release';release.mkdir();product=release/'product.zip'
   def write_product(body):
    with zipfile.ZipFile(product,'w') as zip:zip.writestr('artifact/share/doc/hostwright/runtime-license-inventory.json',source.canonical(body))
    (release/'release-manifest.json').write_bytes(source.canonical(dict(artifactID='artifact',archive=dict(fileName=product.name,sha256=source.sha(product)))))
   write_product(runtime);binding=source.descriptor(root,'a'*40,'0.0.2')
   verified=dict(archiveSHA256=binding['archive']['sha256'],manifestSHA256=binding['manifest']['sha256'],releaseSourceRevision='a'*40,version='0.0.2')
   with mock.patch.object(source.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout=source.canonical(verified))) as verifier:
    with self.assertRaisesRegex(ValueError,'legacy runtime source'):source.verify_contract(root,'a'*40,'0.0.2')
    self.assertIn('--expected-manifest-sha256',verifier.call_args.args[0]);self.assertIn('a'*40,verifier.call_args.args[0])
    import shutil
    target=root/'failed-stage';target.mkdir();shutil.copytree(release,target/'release');(target/'historic').write_bytes(b'preserve')
    with self.assertRaisesRegex(ValueError,'legacy runtime source'):source.install(target,directory,'a'*40,'0.0.2')
    self.assertFalse((target/'source').exists());self.assertEqual((target/'historic').read_bytes(),b'preserve')
    altered=copy.deepcopy(runtime);altered['assets'][1]['sourceDistributionEvidence']['files']=['different'];write_product(altered)
    with self.assertRaisesRegex(ValueError,'differs'):source.verify_contract(root,'a'*40,'0.0.2')
    altered['assets'][1]['status']='blocked';write_product(altered)
    with self.assertRaisesRegex(ValueError,'differs'):source.verify_contract(root,'a'*40,'0.0.2')
 def test_forged_runtime_flags_paths_digests_and_attestation_are_never_authority(self):
  assets=[dict(identity=identity,status='qualified',blockers=[],licenseExpression='Apache-2.0',sourceDistributionEvidence={'files':['exact']}) for identity in ('kata-linux-kernel','apple-vminit-oci','hostwright-netfilter-loader')]
  runtime=dict(kind='hostwright.runtime-license-inventory.v1',schemaVersion=1,status='qualified',assets=assets)
  with self.assertRaisesRegex(ValueError,'validator unavailable'):source.qualified_runtime(runtime)
  for change in ('blocked','missing','candidate','nonexistent-proof','forged-digests','forged-attestation'):
   value=copy.deepcopy(runtime)
   if change=='blocked':value['assets'][1]['blockers']=['actual OCI link provenance missing']
   elif change=='missing':value['assets'].pop()
   elif change=='candidate':value['assets'][1]['status']='candidate'
   elif change=='nonexistent-proof':value['assets'][1]['sourceDistributionEvidence']={'files':['/nonexistent/proof']}
   elif change=='forged-digests':value['assets'][1]['sourceDistributionEvidence']={'ociIndexSHA256':'a'*64,'kernelSHA256':'b'*64,'staticLinkInventorySHA256':'c'*64}
   else:value['assets'][1]['sourceDistributionEvidence']={'kind':'hostwright.trusted-proof.v1','status':'verified','signerWorkflow':'hostwright/hostwright/.github/workflows/trusted-release.yml','signatureVerified':True,'files':['exact']}
   with self.assertRaises(ValueError):source.qualified_runtime(value)
  dynamic=copy.deepcopy(runtime);dynamic['payloadFiles']=['filled'];dynamic['assets'][2].update(sha256='filled',sizeBytes=42)
  self.assertEqual(source.source_evidence_contents(runtime),source.source_evidence_contents(dynamic))
  dynamic['assets'][1]['sourceDistributionEvidence']['files']=['changed']
  self.assertNotEqual(source.source_evidence_contents(runtime),source.source_evidence_contents(dynamic))
 def test_new_runtime_stage_binds_actual_product_payloads_to_authenticated_source(self):
  import io,subprocess,tarfile,zipfile
  with tempfile.TemporaryDirectory() as temporary:
   root=pathlib.Path(temporary);binding=fixtures.source_fixture(root);directory=root/'source'
   manifest_path=directory/'source-manifest.json';manifest=source.parse(manifest_path.read_bytes())
   manifest['kind']=source.NEW_RUNTIME_KIND
   manifest_path.write_bytes(source.canonical(manifest))
   runtime=dict(kind='hostwright.runtime-license-inventory.v1',schemaVersion=1,status='qualified',assets=[])
   bundle=directory/binding['archive']['fileName']
   with tarfile.open(bundle,'w:gz') as archive:
    for name,data in [('source-manifest.json',manifest_path.read_bytes()),('licenses/runtime-license-inventory.json',source.canonical(runtime))]:
     item=tarfile.TarInfo(name);item.size=len(data);archive.addfile(item,io.BytesIO(data))
   (directory/'SOURCE_SHA256SUMS').write_text(source.sha(bundle)+'  '+bundle.name+'\n'+source.sha(manifest_path)+'  source-manifest.json\n')
   release=root/'release';release.mkdir();product=release/'product.zip'
   payload=b'actual signed product runtime bytes'
   with zipfile.ZipFile(product,'w') as archive:
    archive.writestr('artifact/share/doc/hostwright/runtime-license-inventory.json',source.canonical(runtime))
    archive.writestr('artifact/share/hostwright/containerization/kernel/vmlinux',payload)
   (release/'release-manifest.json').write_bytes(source.canonical(dict(artifactID='artifact',archive=dict(fileName=product.name,sha256=source.sha(product)))))
   binding=source.descriptor(root,'a'*40,'0.0.2')
   verified=dict(archiveSHA256=binding['archive']['sha256'],manifestSHA256=binding['manifest']['sha256'],releaseSourceRevision='a'*40,version='0.0.2')
   with mock.patch.object(source.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout=source.canonical(verified))),mock.patch.object(source,'qualified_runtime',return_value={'verified':True}) as validator:
    source.verify_contract(root,'a'*40,'0.0.2')
   self.assertEqual(validator.call_args.args[1],'a'*40)
   self.assertEqual(validator.call_args.args[2],{'share/hostwright/containerization/kernel/vmlinux':payload})
 def test_explicit_gpg_requires_both_absolute_path_and_exact_digest(self):
  spec=importlib.util.spec_from_file_location('bundle',pathlib.Path(__file__).with_name('corresponding-source.py'));bundle=importlib.util.module_from_spec(spec);spec.loader.exec_module(bundle)
  for validate in (bundle.gpg_arguments,source.gpg_arguments):
   self.assertEqual(validate(),[])
   self.assertEqual(validate('/Users/dev/private/gpg','a'*64),['--gpg','/Users/dev/private/gpg','--gpg-sha256','a'*64])
   for path,digest in [('/Users/dev/private/gpg',None),(None,'a'*64),('gpg','a'*64),('/tmp/../gpg','a'*64),('/Users/dev/private/gpg','bad')]:
    with self.assertRaises(ValueError):validate(path,digest)
 def test_gpg_platform_selection_has_no_path_fallback(self):
  self.assertEqual(str(signature.select_executable('darwin')),'/opt/homebrew/bin/gpg')
  self.assertEqual(str(signature.select_executable('linux')),'/usr/bin/gpg')
  for system,path in [('linux','gpg'),('linux','/tmp/../gpg'),('win32',None)]:
   with self.assertRaises(ValueError):signature.select_executable(system,path)
  self.assertEqual(str(signature.select_executable('darwin','/Users/dev/private/gpg')),'/Users/dev/private/gpg')
  with self.assertRaises(ValueError):signature.trusted_executable(pathlib.Path('/tmp/gpg'))
 def test_actual_macos_gpg_resolves_to_reviewed_homebrew_package(self):
  import sys
  if sys.platform!='darwin':self.skipTest('macOS executable inspection')
  if pathlib.Path('/opt/homebrew/Cellar').stat().st_mode & 0o022:
   with self.assertRaises(ValueError):signature.trusted_executable(signature.select_executable('darwin'))
   return
  resolved=signature.trusted_executable(signature.select_executable('darwin'))
  self.assertTrue(resolved.startswith('/opt/homebrew/Cellar/gnupg/'));self.assertTrue(resolved.endswith('/gpg'))
 def test_linux_and_private_gpg_executable_guards(self):
  import stat,types,os
  path=pathlib.Path('/usr/bin/gpg')
  good=types.SimpleNamespace(st_uid=os.getuid(),st_mode=stat.S_IFREG|0o755)
  with mock.patch.object(pathlib.Path,'resolve',return_value=path),mock.patch.object(pathlib.Path,'stat',return_value=good):
   self.assertEqual(signature.trusted_executable(path),str(path))
  for mode,owner in [(stat.S_IFREG|0o775,os.getuid()),(stat.S_IFREG|0o644,os.getuid()),(stat.S_IFDIR|0o755,os.getuid()),(stat.S_IFREG|0o755,99999)]:
   bad=types.SimpleNamespace(st_uid=owner,st_mode=mode)
   with mock.patch.object(pathlib.Path,'resolve',return_value=path),mock.patch.object(pathlib.Path,'stat',return_value=bad):
    with self.assertRaises(ValueError):signature.trusted_executable(path)
  private=pathlib.Path('/Users/dev/private/gpg')
  with mock.patch.object(pathlib.Path,'resolve',return_value=private),mock.patch.object(pathlib.Path,'stat',return_value=good),mock.patch.object(signature,'sha',return_value='b'*64):
   with self.assertRaises(ValueError):signature.trusted_executable(private,'a'*64)
   self.assertEqual(signature.trusted_executable(private,'b'*64),str(private))
  with mock.patch.object(pathlib.Path,'resolve',return_value=pathlib.Path('/tmp/gpg')):
   with self.assertRaises(ValueError):signature.trusted_executable(private,'a'*64)
 def test_signature_status_identity_and_exit_remain_pinned(self):
  status='[GNUPG:] VALIDSIG '+signature.FINGERPRINT+' 2026-01-01 1 0 4 0 1 10 00 '+signature.FINGERPRINT
  signature.valid_status(status,0)
  for value,code in [(status,1),(status.replace(signature.FINGERPRINT,'0'*40),0),(status+'\n[GNUPG:] BADSIG bad',0),(status+'\n'+status,0)]:
   with self.assertRaises(ValueError):signature.valid_status(value,code)
if __name__=='__main__':unittest.main()
