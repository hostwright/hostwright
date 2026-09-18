#!/usr/bin/env python3
import importlib.util,json,pathlib,shutil,tempfile,unittest
spec=importlib.util.spec_from_file_location('notices',pathlib.Path(__file__).with_name('validate-third-party-notices.py'));module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
ROOT=pathlib.Path(__file__).resolve().parents[2]
class NoticesTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.tmp.name)
  for name in ['THIRD_PARTY_NOTICES','third-party-license-inventory.json','runtime-license-inventory.json','Package.resolved']:shutil.copy(ROOT/name,self.root/name)
  shutil.copytree(ROOT/'Guest/HostwrightNetfilter',self.root/'Guest/HostwrightNetfilter')
 def tearDown(self):self.tmp.cleanup()
 def change(self,path,update):
  obj=json.loads((self.root/path).read_text());update(obj);(self.root/path).write_text(json.dumps(obj,sort_keys=True,separators=(',',':'))+'\n')
 def test_exact_inventory_and_blocked_release(self):
  self.assertEqual(module.verify(self.root)['dependencies'],31)
  with self.assertRaises(ValueError):module.verify(self.root,True)
 def test_altered_text_and_pin(self):
  (self.root/'THIRD_PARTY_NOTICES').write_bytes(b'altered')
  with self.assertRaises(ValueError):module.verify(self.root)
 def test_missing_guest_license(self):
  self.change('third-party-license-inventory.json',lambda x:x.update(runtimeDocuments=[d for d in x['runtimeDocuments'] if not d['sourcePath'].startswith('guest-swift/zstd@')]))
  with self.assertRaisesRegex(ValueError,'guest dependency'):module.verify(self.root)
 def test_changed_loader_source(self):
  (self.root/'Guest/HostwrightNetfilter/main.go').write_bytes(b'altered')
  with self.assertRaisesRegex(ValueError,'source/binary'):module.verify(self.root)
if __name__=='__main__':unittest.main()
