#!/usr/bin/env python3
"""Create a canonical single-layer arm64 OCI layout from a deterministic rootfs layer."""
import argparse, gzip, hashlib, json, pathlib

def canonical(value): return json.dumps(value,sort_keys=True,separators=(',',':')).encode()
def digest(data): return hashlib.sha256(data).hexdigest()

def create(layer_path, output):
    if layer_path.is_symlink() or not layer_path.is_file() or output.exists() or output.is_symlink():
        raise ValueError('unsafe runtime OCI input or output')
    layer=layer_path.read_bytes();raw=gzip.decompress(layer)
    blobs=output/'blobs'/'sha256';blobs.mkdir(parents=True,mode=0o700)
    def blob(data):
        value=digest(data);(blobs/value).write_bytes(data);return {'digest':'sha256:'+value,'size':len(data)}
    layer_record=blob(layer);layer_record['mediaType']='application/vnd.oci.image.layer.v1.tar+gzip'
    config=blob(canonical({'architecture':'arm64','os':'linux','rootfs':{'type':'layers','diff_ids':['sha256:'+digest(raw)]}}))
    config['mediaType']='application/vnd.oci.image.config.v1+json'
    manifest=blob(canonical({'schemaVersion':2,'mediaType':'application/vnd.oci.image.manifest.v1+json','config':config,'layers':[layer_record]}))
    manifest['mediaType']='application/vnd.oci.image.manifest.v1+json'
    (output/'oci-layout').write_bytes(canonical({'imageLayoutVersion':'1.0.0'}))
    (output/'index.json').write_bytes(canonical({'schemaVersion':2,'mediaType':'application/vnd.oci.image.index.v1+json','manifests':[manifest]}))
    return digest((output/'index.json').read_bytes())

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--layer',type=pathlib.Path,required=True);parser.add_argument('--output',type=pathlib.Path,required=True);args=parser.parse_args()
    print(create(args.layer,args.output))
