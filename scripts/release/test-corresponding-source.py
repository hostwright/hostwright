#!/usr/bin/env python3
import hashlib,importlib.util,io,pathlib,tarfile,unittest
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
 def test_pinned_signature_status(self):
  valid='[GNUPG:] VALIDSIG '+signature.FINGERPRINT+' 2026-02-27 1772226351 0 4 0 1 10 00 '+signature.FINGERPRINT
  signature.valid_status(valid,0)
  for status,code in [(valid,1),(valid.replace(signature.FINGERPRINT,'A'*40),0),(valid+'\n[GNUPG:] BADSIG bad',0),(valid+'\n'+valid,0),('',0)]:
   with self.assertRaises(ValueError):signature.valid_status(status,code)
if __name__=='__main__':unittest.main()
