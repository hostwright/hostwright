#!/usr/bin/env python3
import importlib.util,pathlib,tempfile,unittest
HERE=pathlib.Path(__file__).resolve().parent
def load(name,file):
 s=importlib.util.spec_from_file_location(name,HERE/file);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
subjects=load('subjects','prepare-runtime-attestation-subjects.py');fixture=load('assembler_test','test-assemble-runtime-provenance.py')
class Tests(unittest.TestCase):
 def test_exact_manifest_and_every_payload_are_subjects(self):
  with tempfile.TemporaryDirectory() as value:
   root=pathlib.Path(value).resolve();source=root/'input';source.mkdir();case=fixture.RuntimeProvenanceAssemblerTests();manifest,_,payloads,_=case.fixture(source);archive=root/'source.tar.gz';case.assemble(source,archive,manifest);output=root/'subjects';receipt=subjects.prepare(archive,output,manifest['sourceCommit'])
   self.assertEqual({r['path'] for r in receipt['payloads']},set(payloads));self.assertEqual(len(list((output/'payloads').iterdir())),len(payloads));self.assertTrue((output/'runtime-provenance.json').is_file())
if __name__=='__main__':unittest.main()
