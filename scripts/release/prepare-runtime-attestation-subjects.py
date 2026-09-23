#!/usr/bin/env python3
"""Prepare exact manifest and payload subjects from a completed runtime source archive."""
import argparse, importlib.util, json, os, pathlib, tarfile, tempfile

HERE=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('runtime_verifier',HERE/'verify-runtime-provenance.py');v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)

def prepare(archive_path,output,source_commit):
    if archive_path.is_symlink() or not archive_path.is_file() or output.exists() or output.is_symlink():raise ValueError('unsafe attestation subject input or output')
    with tarfile.open(archive_path,'r:gz') as archive:
        members={}
        for member in archive.getmembers():
            name=v.path(member.name.rstrip('/'))
            if name in members:raise ValueError('duplicate runtime source member')
            members[name]=member
        def fetch(name):
            name=v.path(name);member=members.get(name)
            if member is None or not member.isfile() or member.size>v.MAX_FILE:raise ValueError('missing runtime attestation subject: '+name)
            return archive.extractfile(member).read()
        manifest_data=fetch('runtime-provenance/manifest.json');manifest=v.parse(manifest_data)
        runtime=v.parse(fetch('licenses/runtime-license-inventory.json'))
        payloads={record['path']:fetch('runtime-provenance/payloads/'+v.path(record['path'])) for record in manifest['payloads']}
        v.verify(manifest_data,runtime,payloads,fetch,source_commit,require_authentication=False)
    temporary=pathlib.Path(tempfile.mkdtemp(prefix='.'+output.name+'.',dir=output.parent));os.chmod(temporary,0o700)
    try:
        (temporary/'runtime-provenance.json').write_bytes(manifest_data)
        records=[]
        for index,(name,data) in enumerate(sorted(payloads.items())):
            target=temporary/'payloads'/('%04d-%s' % (index,pathlib.PurePosixPath(name).name));target.parent.mkdir(mode=0o700,exist_ok=True);target.write_bytes(data)
            records.append({'path':name,'subject':target.relative_to(temporary).as_posix(),'sha256':v.digest(data),'sizeBytes':len(data)})
        receipt={'kind':'hostwright.runtime-attestation-subjects.v1','sourceCommit':source_commit,'manifestSHA256':v.digest(manifest_data),'payloads':records}
        (temporary/'subjects.json').write_bytes(v.canonical(receipt))
        for item in temporary.rglob('*'):item.chmod(0o700 if item.is_dir() else 0o600)
        os.replace(temporary,output)
    except BaseException:
        if temporary.exists():
            import shutil;shutil.rmtree(temporary)
        raise
    return receipt

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--archive',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--source-commit',required=True);a=p.parse_args();print(json.dumps(prepare(a.archive,a.output,a.source_commit),sort_keys=True))
