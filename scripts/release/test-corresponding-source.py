#!/usr/bin/env python3
import contextlib,hashlib,importlib.util,io,json,pathlib,tarfile,tempfile,types,unittest,sys
from unittest import mock
HERE=pathlib.Path(__file__).parent

def load(name):
 spec=importlib.util.spec_from_file_location(name,HERE/(name+'.py'));module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
bundle=load('corresponding-source');signature=load('verify-kernel-source-signature')
class SourceBundleTests(unittest.TestCase):
 def archive(self,entries):
  data=io.BytesIO()
  with tarfile.open(fileobj=data,mode='w') as t:
   for name,body,mode,type_,target in entries:
    info=tarfile.TarInfo(name);info.mode=mode;info.type=type_;info.linkname=target;info.size=len(body) if type_==tarfile.REGTYPE else 0;t.addfile(info,io.BytesIO(body) if info.isfile() else None)
  data.seek(0);return tarfile.open(fileobj=data,mode='r:')
 def record(self,name='kernel/file',body=b'exact',mode=0o644):return dict(path=name,sha256=hashlib.sha256(body).hexdigest(),sizeBytes=len(body),mode=mode,type='regular',linkTarget='')
 def test_exact_files(self):
  with self.archive([('kernel/file',b'exact',0o644,tarfile.REGTYPE,'')]) as t:bundle.verify_records(t,[self.record()])
 def test_changed_file(self):
  with self.archive([('kernel/file',b'wrong',0o644,tarfile.REGTYPE,'')]) as t:
   with self.assertRaisesRegex(ValueError,'changed'):bundle.verify_records(t,[self.record()])
 def test_missing_extra_and_duplicate_files(self):
  for entries in [[],[('kernel/extra',b'exact',0o644,tarfile.REGTYPE,'')],[('kernel/file',b'exact',0o644,tarfile.REGTYPE,'')]*2]:
   with self.archive(entries) as t:
    with self.assertRaises(ValueError):bundle.verify_records(t,[self.record()])
 def test_traversal_paths(self):
  for path in ['../outside','/absolute','kernel/../../outside','kernel//file','kernel/./file','kernel\\outside']:
   with self.archive([(path,b'exact',0o644,tarfile.REGTYPE,'')]) as t:
    with self.assertRaises(ValueError):bundle.verify_records(t,[self.record(path)])
 def test_escaping_and_unlisted_links(self):
  for path,target in [('kernel/link','../../outside'),('kernel/link','/absolute'),('kernel/link','safe')]:
   with self.archive([(path,b'',0o777,tarfile.SYMTYPE,target)]) as t:
    with self.assertRaises(ValueError):bundle.verify_records(t,[self.record()])
 def test_mode_and_special_file_refused(self):
  for mode,type_ in [(0o755,tarfile.REGTYPE),(0o644,tarfile.FIFOTYPE)]:
   with self.archive([('kernel/file',b'exact',mode,type_,'')]) as t:
    with self.assertRaises(ValueError):bundle.verify_records(t,[self.record()])
 def test_exact_relative_source_symlink(self):
  target='../common.conf';record=dict(path='kernel/configs/arch/link',sha256=hashlib.sha256(target.encode()).hexdigest(),sizeBytes=len(target),mode=0o777,type='symlink',linkTarget=target)
  with self.archive([(record['path'],b'',0o777,tarfile.SYMTYPE,target)]) as t:bundle.verify_records(t,[record])
 def test_candidate_notice_scope_and_changed_inventory(self):
  metadata=dict(kind='hostwright.sdk-candidate-runtime-source-notices.v1',status='not-actual-oci-link-qualified',sdkArchiveSHA256='d2078b69bdeb5c31202c10e9d8a11d6f66f82938b51a4b75f032ccb35c4c286c',documents=[dict(path='LICENSE',sha256='a'*64,sizeBytes=10)])
  records={'LICENSE':dict(sha256='a'*64,sizeBytes=10)}
  bundle.validate_sdk_notice_inventory(metadata,records)
  for changed in [{},{'LICENSE':dict(sha256='b'*64,sizeBytes=10)}]:
   with self.assertRaises(ValueError):bundle.validate_sdk_notice_inventory(metadata,changed)
  metadata['status']='qualified'
  with self.assertRaises(ValueError):bundle.validate_sdk_notice_inventory(metadata,records)
 def test_version_ranges(self):
  for version in ['0.0.2','0.0.2-dev.1','0.0.2-dev.999','0.0.2-rc.1','0.0.2-rc.99']:self.assertTrue(bundle.valid_version(version))
  for version in ['0.0.2-dev.0','0.0.2-dev.1000','0.0.2-rc.0','0.0.2-rc.100','0.0.2-rc.01','0.0.3']:self.assertFalse(bundle.valid_version(version))
 def test_prepare_runtime_archive_carries_verified_new_runtime_bytes(self):
  with tempfile.TemporaryDirectory() as temporary:
   root=pathlib.Path(temporary);out_parent=root.parent/(root.name+'-out');out_parent.mkdir();incoming=root/'runtime.tar.gz'
   manifest=dict(kind='hostwright.corresponding-source.new-runtime.v1',schemaVersion=1,releaseSourceRevision='a'*40,version='0.0.2',status='prepared-not-release-qualified',publicationRoute='same-github-release-alongside-binaries',upstreamSignatureVerified=True,preparedSourceState=dict(head='a'*40,clean=True,gitStatusSHA256=hashlib.sha256(b'').hexdigest()),files=[])
   manifest_data=bundle.canonical(manifest)
   with tarfile.open(incoming,'w:gz') as archive:
    item=tarfile.TarInfo('source-manifest.json');item.size=len(manifest_data);archive.addfile(item,io.BytesIO(manifest_data))
   args=types.SimpleNamespace(root=root,runtime_provenance_archive=incoming,output_parent=out_parent,source='a'*40,version='0.0.2',gpg=None,gpg_sha256=None,kernel_inputs=None,kata_recipes=None,loader_receipt=None)
   original=incoming.read_bytes()
   def verify_snapshot(path, **_):
    incoming.write_bytes(b'tampered after snapshot')
    return dict(archiveSHA256=bundle.digest_file(path),manifestSHA256=hashlib.sha256(manifest_data).hexdigest(),sizeBytes=path.stat().st_size,version='0.0.2',releaseSourceRevision='a'*40,status='prepared-not-release-qualified')
   with mock.patch.object(bundle,'source_state',return_value=manifest['preparedSourceState']),mock.patch.object(bundle,'verify',side_effect=verify_snapshot):
    result=bundle.prepare(args)
   staged=pathlib.Path(result['directory']);name='hostwright-0.0.2-'+'a'*12+'-corresponding-source.tar.gz'
   self.assertEqual((staged/'source-manifest.json').read_bytes(),manifest_data)
   self.assertEqual((staged/name).read_bytes(),original)
   self.assertEqual((staged/'SOURCE_SHA256SUMS').read_text().splitlines()[0].split()[0],bundle.digest_file(staged/name))
   self.assertTrue((staged/'source-bundle-receipt.json').is_file())
   import shutil;shutil.rmtree(out_parent)
 def test_prepare_cli_prints_runtime_handoff_json(self):
  args=['corresponding-source.py','prepare','--root','/tmp/root','--runtime-provenance-archive','/tmp/runtime.tar.gz','--output-parent','/tmp/out','--version','0.0.2','--source','a'*40]
  expected={'directory':'/tmp/out/prepared','archive':'/tmp/out/prepared/archive.tar.gz'}
  output=io.StringIO()
  with mock.patch.object(bundle,'prepare',return_value=expected),mock.patch.object(sys,'argv',args),contextlib.redirect_stdout(output):
   bundle.main()
  self.assertEqual(json.loads(output.getvalue()),expected)
 def test_prepare_runtime_archive_uses_real_verifier_and_rejects_incomplete_bundle(self):
  with tempfile.TemporaryDirectory() as temporary:
   root=pathlib.Path(temporary);out_parent=root.parent/(root.name+'-out');out_parent.mkdir();incoming=root/'runtime.tar.gz'
   manifest=dict(kind='hostwright.corresponding-source.new-runtime.v1',schemaVersion=1,releaseSourceRevision='a'*40,version='0.0.2',status='prepared-not-release-qualified',publicationRoute='same-github-release-alongside-binaries',upstreamSignatureVerified=True,preparedSourceState=dict(head='a'*40,clean=True,gitStatusSHA256=hashlib.sha256(b'').hexdigest()),files=[])
   manifest_data=bundle.canonical(manifest)
   with tarfile.open(incoming,'w:gz') as archive:
    item=tarfile.TarInfo('source-manifest.json');item.size=len(manifest_data);archive.addfile(item,io.BytesIO(manifest_data))
   args=types.SimpleNamespace(root=root,runtime_provenance_archive=incoming,output_parent=out_parent,source='a'*40,version='0.0.2',gpg=None,gpg_sha256=None,kernel_inputs=None,kata_recipes=None,loader_receipt=None)
   with mock.patch.object(bundle,'source_state',return_value=dict(head='a'*40,clean=True,gitStatusSHA256=hashlib.sha256(b'').hexdigest())):
    with self.assertRaisesRegex(ValueError,'missing regular provenance evidence'):
     bundle.prepare(args)
   self.assertFalse(list(out_parent.glob('hostwright-runtime-source-*')))
   import shutil;shutil.rmtree(out_parent)
 def test_pinned_signature_status(self):
  valid='[GNUPG:] VALIDSIG '+signature.FINGERPRINT+' 2026-02-27 1772226351 0 4 0 1 10 00 '+signature.FINGERPRINT
  signature.valid_status(valid,0)
  for status,code in [(valid,1),(valid.replace(signature.FINGERPRINT,'A'*40),0),(valid+'\n[GNUPG:] BADSIG bad',0),(valid+'\n'+valid,0),('',0)]:
   with self.assertRaises(ValueError):signature.valid_status(status,code)
if __name__=='__main__':unittest.main()
