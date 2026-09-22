#!/usr/bin/env python3
import gzip, importlib.util, io, json, pathlib, tarfile, tempfile, unittest

HERE=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('create_runtime_oci',HERE/'create-runtime-oci.py');oci=importlib.util.module_from_spec(spec);spec.loader.exec_module(oci)

class RuntimeOCITests(unittest.TestCase):
 def test_canonical_single_layer_layout_is_deterministic_and_closed(self):
  buffer=io.BytesIO()
  with tarfile.open(fileobj=buffer,mode='w') as archive:
   data=b'elf';item=tarfile.TarInfo('sbin/vminitd');item.size=len(data);item.mtime=0;archive.addfile(item,io.BytesIO(data))
  layer=gzip.compress(buffer.getvalue(),mtime=0)
  with tempfile.TemporaryDirectory() as temporary:
   root=pathlib.Path(temporary);source=root/'layer.tar.gz';source.write_bytes(layer)
   first=root/'first';second=root/'second';self.assertEqual(oci.create(source,first),oci.create(source,second))
   self.assertEqual({p.relative_to(first).as_posix():p.read_bytes() for p in first.rglob('*') if p.is_file()},
                    {p.relative_to(second).as_posix():p.read_bytes() for p in second.rglob('*') if p.is_file()})
   index=json.loads((first/'index.json').read_bytes());descriptor=index['manifests'][0]
   manifest=json.loads((first/'blobs/sha256'/descriptor['digest'][7:]).read_bytes())
   self.assertEqual(len(manifest['layers']),1);self.assertEqual(manifest['layers'][0]['size'],len(layer))

if __name__=='__main__':unittest.main()
