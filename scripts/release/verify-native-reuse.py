#!/usr/bin/env python3
"""Authenticate an unchanged native fragment without rebasing its producer claims."""

import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

HERE=Path(__file__).resolve().parent
KIND='hostwright.native-runtime-reuse.v1'
SUBJECTS={'checksums':'checksums.sha256','nativeManifest':'runtime-native-fragment/native-provenance.json','sourceMap':'evidence/source-map.json'}


def module(name,filename):
    spec=importlib.util.spec_from_file_location(name,HERE/filename)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value


I=module('native_input_proof','native-reuse-inputs.py')
R=module('native_resolution','resolve-native-checkpoint.py')


def require(condition,message): I.require(condition,message)
def canonical(value): return I.canonical(value)
def digest(data): return I.digest(data)


def safe(root,name):
    require(isinstance(name,str) and name and not name.startswith('/') and '\\' not in name and
            all(part not in ('','.','..') for part in name.split('/')),'unsafe native evidence path')
    target=Path(root)
    for part in name.split('/'):
        target=target/part;require(not target.is_symlink(),'symlink in native evidence path')
    require(target.is_file(),'missing native evidence file: '+name)
    return target


def file_digest(path):
    import hashlib
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def checksums(raw):
    result={}
    for line in raw.decode('utf-8','strict').splitlines():
        match=re.fullmatch(r'([a-f0-9]{64})  (.+)',line)
        require(match is not None,'malformed native checksum manifest')
        expected,name=match.groups()
        if name.startswith('./'):name=name[2:]
        require(name and not name.startswith('/') and '\\' not in name and all(x not in ('','.','..') for x in name.split('/')) and name not in result,
                'unsafe or duplicate native checksum entry')
        require(name.startswith(('payloads/','evidence/','runtime-native-fragment/')),'unexpected native checksum namespace')
        result[name]=expected
    require(0<len(result)<=100000,'empty or oversized native checksum manifest')
    return result


def verify_carrier(root):
    expected=checksums(safe(root,'checksums.sha256').read_bytes())
    actual=set()
    for item in Path(root).rglob('*'):
        require(not item.is_symlink(),'symlink in retained native carrier')
        if item.is_file():actual.add(item.relative_to(root).as_posix())
        else:require(item.is_dir(),'nonregular native carrier member')
    require(actual==set(expected)|{'checksums.sha256'},'native checksum coverage is incomplete')
    for name,sha in expected.items():require(file_digest(safe(root,name))==sha,'native carrier file differs from authenticated manifest: '+name)
    return expected


def verify_attestation(subject,bundle,producer):
    require(set(producer)=={'commit','runID','attempt'} and re.fullmatch('[a-f0-9]{40}',producer['commit']) and
            type(producer['runID']) is int and producer['runID']>0 and type(producer['attempt']) is int and producer['attempt']>0,
            'invalid original native producer')
    identity=f'https://github.com/{R.REPO}/{R.WORKFLOW}@refs/heads/main'
    argv=['gh','attestation','verify',str(subject),'--bundle',str(bundle),'--repo',R.REPO,'--hostname','github.com',
          '--signer-digest',producer['commit'],'--source-digest',producer['commit'],'--source-ref','refs/heads/main',
          '--cert-identity',identity,'--cert-oidc-issuer','https://token.actions.githubusercontent.com',
          '--deny-self-hosted-runners','--format','json']
    result=subprocess.run(argv,capture_output=True,timeout=120,check=True,
                          env={k:v for k,v in os.environ.items() if k in ('PATH','HOME','GH_TOKEN','GITHUB_TOKEN','GH_CONFIG_DIR')})
    require(len(result.stdout)<=32*1024**2,'oversized native attestation verification')
    values=json.loads(result.stdout)
    require(isinstance(values,list) and values,'missing verified native attestation')
    expected_run=f'https://github.com/{R.REPO}/actions/runs/{producer["runID"]}/attempts/{producer["attempt"]}'
    actual=file_digest(subject)
    for value in values:
        verification=value['verificationResult'];cert=verification['signature']['certificate']
        if (cert.get('issuer')=='https://token.actions.githubusercontent.com' and cert.get('buildSignerURI')==identity
                and cert.get('buildSignerDigest')==producer['commit'] and cert.get('sourceRepositoryURI')=='https://github.com/'+R.REPO
                and cert.get('sourceRepositoryDigest')==producer['commit'] and cert.get('sourceRepositoryRef')=='refs/heads/main'
                and cert.get('runnerEnvironment')=='github-hosted' and cert.get('runInvocationURI')==expected_run
                and verification.get('verifiedTimestamps')
                and any(row.get('digest')=={'sha256':actual} for row in verification['statement']['subject'])):
            return result.stdout
    raise ValueError('native attestation does not bind the exact original producer and subject')


def authenticate_subject(root,name,producer,output,key):
    source=safe(root,name);subject=output/'subjects'/key
    subject.parent.mkdir(mode=0o700,exist_ok=True);shutil.copyfile(source,subject)
    bundle_dir=output/'attestation-downloads'/key;bundle_dir.mkdir(mode=0o700,parents=True)
    subprocess.run(['gh','attestation','download',str(subject),'--repo',R.REPO,'--hostname','github.com'],
                   cwd=bundle_dir,check=True,timeout=120,capture_output=True)
    bundle=bundle_dir/('sha256:'+file_digest(subject)+'.jsonl')
    require(bundle.is_file() and not bundle.is_symlink() and bundle.stat().st_size<=32*1024**2,'missing or oversized original attestation bundle')
    require(set(bundle_dir.iterdir())=={bundle},'unexpected original attestation download member')
    bundle=bundle.rename(bundle_dir/'subject.sigstore.jsonl')
    raw=verify_attestation(subject,bundle,producer)
    return dict(subject=I.record(output,'subjects/'+key,subject.read_bytes()),
                bundle=I.record(output,'subjects/'+key+'.sigstore.jsonl',bundle.read_bytes()),
                verification=I.record(output,'subjects/'+key+'.verification.json',raw))


def rebase(value,prefix):
    if isinstance(value,dict):
        result={key:rebase(child,prefix) for key,child in value.items()}
        if {'path','sha256','sizeBytes'}<=result.keys():result['path']=prefix+result['path']
        return result
    if isinstance(value,list):return [rebase(child,prefix) for child in value]
    return value


def validate(proof,fetch,source,authenticate=False):
    require(set(proof)=={'kind','schemaVersion','status','sourceCommit','producer','artifact','resolution','subjects','sdk','inputComparison'},'invalid typed native reuse proof')
    require(proof['kind']==KIND and type(proof['schemaVersion']) is int and proof['schemaVersion']==1 and proof['status']=='authenticated-unchanged-inputs-not-release-qualified'
            and proof['sourceCommit']==source,'native reuse contract/source mismatch')
    resolution=json.loads(I.bound(proof['resolution'],fetch))
    producer=proof['producer']
    selected=R.select(resolution['originalRun'],resolution['originalJobs'],resolution['originalArtifacts'],producer['runID'],producer['attempt'])
    require(selected==resolution and selected['producer']==producer and selected['artifact']==proof['artifact'],'native artifact producer resolution changed')
    require(set(proof['subjects'])==set(SUBJECTS),'native attestation subject coverage mismatch')
    subjects={name:I.bound(row['subject'],fetch) for name,row in proof['subjects'].items()}
    for row in proof['subjects'].values():
        require(set(row)=={'subject','bundle','verification'},'native attestation evidence is incomplete')
        I.bound(row['bundle'],fetch);I.bound(row['verification'],fetch)
    entries=checksums(subjects['checksums'])
    for key,name in SUBJECTS.items():
        if key!='checksums':require(entries.get(name)==digest(subjects[key]),'original native subject differs from checksum manifest')
    native=json.loads(subjects['nativeManifest'])
    require(native['sourceCommit']==producer['commit'] and native['status']=='prepared-not-release-qualified','original native source claim was rebased')
    sdk=proof['sdk'];require(set(sdk)=={'producer','reuse','archive'},'native SDK evidence coverage mismatch')
    sdk_producer=json.loads(I.bound(sdk['producer'],fetch));sdk_reuse=json.loads(I.bound(sdk['reuse'],fetch))
    require(entries.get('evidence/sdk-producer.json')==sdk['producer']['sha256'] and entries.get('evidence/sdk-reuse.json')==sdk['reuse']['sha256']
            and entries.get('evidence/swift-static-sdk.tar.gz')==sdk['archive']['sha256'],'original SDK evidence differs from carrier')
    I.bound(sdk['archive'],fetch)
    require(set(sdk_producer)=={'commit','runID','attempt'} and set(sdk_reuse['producer'])=={'commit'}
            and re.fullmatch('[a-f0-9]{40}',sdk_producer['commit'])
            and sdk_reuse['kind']=='hostwright.swift-sdk-reuse-compatibility.v1' and sdk_reuse['status']=='compatible-not-release-qualified'
            and sdk_reuse['sourceCommit']==producer['commit'] and sdk_reuse['producer']['commit']==sdk_producer['commit']
            and type(sdk_producer['runID']) is int and sdk_producer['runID']>0 and type(sdk_producer['attempt']) is int and sdk_producer['attempt']>0
            and sdk_reuse['sourceInventory']['sdkArchiveSHA256']==sdk['archive']['sha256'], 'original SDK reuse chain changed')
    comparison=I.verify(proof['inputComparison'],fetch,producer['commit'],source)
    require(comparison['sdkCompileInputs']==sdk_reuse['compileInputs'],'original SDK recipe is not the unchanged accepted recipe')
    if authenticate:
        with tempfile.TemporaryDirectory(prefix='native-reuse-auth-') as temporary:
            temporary=Path(temporary)
            for name,row in proof['subjects'].items():
                subject=temporary/name;bundle=temporary/(name+'.sigstore.jsonl')
                subject.write_bytes(subjects[name]);bundle.write_bytes(I.bound(row['bundle'],fetch))
                verify_attestation(subject,bundle,producer)
    return native


def verify_composition(manifest,fetch,source,authenticate):
    proof=manifest['nativeReuse'];native=validate(proof,fetch,source,authenticate)
    expected=rebase(native,'native/')
    require(manifest['kernel']==expected['kernel'],'reused kernel provenance changed')
    require(manifest['oci']==dict(prefix=native['oci']['prefix'],links=expected['oci']['links'],files=native['oci']['files']), 'reused OCI provenance changed')
    for item in expected['sourceProjects']:
        matches=[row for row in manifest['sourceProjects'] if row['identity']==item['identity']]
        require(matches==[item],'original native source/license evidence changed')
    for item in expected['toolchain']:
        require(item in manifest['toolchain'],'original native compiler evidence changed')
    for item in native['payloads']:
        require(item in manifest['payloads'],'original native payload claim changed')
    require(not any(row['path']==manifest['loader']['path'] for row in native['payloads']),'reused native fragment claims current loader')


def prepare(carrier,resolution_path,repo,source,output):
    require(carrier.is_dir() and not carrier.is_symlink() and not output.exists() and not output.is_symlink(),'unsafe native reuse roots')
    require(output.is_absolute() and not output.resolve().is_relative_to(carrier.resolve()),'native reuse proof must be outside the immutable carrier')
    resolution=json.loads(resolution_path.read_bytes());producer=resolution['producer']
    require(R.select(resolution['originalRun'],resolution['originalJobs'],resolution['originalArtifacts'],producer['runID'],producer['attempt'])==resolution,'native resolution mismatch')
    output.mkdir(mode=0o700)
    subjects={key:authenticate_subject(carrier,name,producer,output,key) for key,name in SUBJECTS.items()}
    # Attested checksums cover every carrier file before any file is accepted as build evidence.
    verify_carrier(carrier)
    sdk={key:I.record(output,'sdk/'+name,safe(carrier,'evidence/'+name).read_bytes())
         for key,name in [('producer','sdk-producer.json'),('reuse','sdk-reuse.json'),('archive','swift-static-sdk.tar.gz')]}
    proof=dict(kind=KIND,schemaVersion=1,status='authenticated-unchanged-inputs-not-release-qualified',sourceCommit=source,
               producer=producer,artifact=resolution['artifact'],resolution=I.record(output,'resolution.json',canonical(resolution)),
               subjects=subjects,sdk=sdk,inputComparison=I.prepare(repo,producer['commit'],source,output))
    validate(proof,lambda name:safe(output,name).read_bytes(),source)
    (output/'native-reuse.json').write_bytes(canonical(proof))
    return proof


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--carrier',type=Path,required=True)
    parser.add_argument('--resolution',type=Path,required=True)
    parser.add_argument('--repo-root',type=Path,required=True)
    parser.add_argument('--source-commit',required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();os.umask(0o077)
    prepare(args.carrier,args.resolution,args.repo_root,args.source_commit,args.output)
