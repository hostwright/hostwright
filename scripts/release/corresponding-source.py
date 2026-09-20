#!/usr/bin/env python3
"""Prepare and verify pinned source bytes; preparation is not release qualification."""
import argparse
import gzip
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import re
import subprocess
import tarfile
import tempfile

PINS = dict(kernelVersion='6.18.15', kernelConfigurationVersion='186',
            kernelSourceSHA256='7c716216c3c4134ed0de69195701e677577bbcdd3979f331c182acd06bf2f170',
            kernelSourceSizeBytes=154366036,
            kernelConfigurationSHA256='ff5267fc331832a0d337af8ca05ff88d86869970920711c9bc3341922599214f',
            kataRevision='660e3bb6535b141c84430acb25b159857278d596', kataFileCount=175,
            kataInventorySHA256='d1a15af116394a738339e96c3e55e875506d2037c7afc538b35fb9327a0587b7',
            kataModesSHA256='d68ab7c767d40becd53286c82bf6f725b6eb56dc687987dd96ca15796ca80114',
            kataSupplementalSHA256='c131014d09d4a08697027d31e95bcbd0b39244e9d320427afaacb42624871756',
            kataSupplementalFileCount=16,
            retainedLoaderSourceRevision='5216c716ff16c8e93bc9e461af3fd95f26ce569b',
            retainedLoaderReceiptSHA256='3c5d53e8857f33d02a2bd58716a5fa05230f8292109aab8b244acd58e3fcd77f')
MAX_FILES = 200000
MAX_BYTES = 4 * 1024**3


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)+'\n').encode()


def digest_file(path):
    h = hashlib.sha256()
    with pathlib.Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024*1024), b''): h.update(chunk)
    return h.hexdigest()


def regular(path):
    path = pathlib.Path(path)
    if path.is_symlink() or not path.is_file(): raise ValueError('missing or unsafe source input: '+str(path))
    return path


def safe_path(name):
    if not name or '\\' in name or '\x00' in name or name.startswith('/') or any(p in {'', '.', '..'} for p in name.split('/')):
        raise ValueError('unsafe archive path: '+repr(name))
    return pathlib.PurePosixPath(name)


def validate_members(members, root=None, regular_only=False):
    names, size = set(), 0
    for member in members:
        name = member.name.rstrip('/') if member.isdir() else member.name
        path = safe_path(name)
        if name in names: raise ValueError('duplicate archive path')
        names.add(name)
        if len(names)>MAX_FILES: raise ValueError('archive file limit exceeded')
        if root and path.parts[0] != root: raise ValueError('source archive has an unexpected root')
        if member.size<0: raise ValueError('negative archive entry size')
        size += member.size
        if size>MAX_BYTES: raise ValueError('archive byte limit exceeded')
        if member.isfile() or member.isdir(): continue
        if regular_only or not (member.issym() or member.islnk()): raise ValueError('unsupported archive entry type')
        link = member.linkname
        if not link or link.startswith('/') or '\\' in link: raise ValueError('unsafe archive link')
        parts = list(path.parent.parts) if member.issym() else []
        for part in link.split('/'):
            if part in {'', '.'}: continue
            if part=='..':
                if len(parts)<=1: raise ValueError('archive link escapes source root')
                parts.pop()
            else: parts.append(part)
        if root and (not parts or parts[0]!=root): raise ValueError('archive link escapes source root')
    return names


def verify_records(archive, records):
    members = archive.getmembers()
    validate_members(members)
    files = {m.name:m for m in members if not m.isdir()}
    expected = {r['path']:r for r in records}
    if len(expected)!=len(records) or set(files)-{'source-manifest.json'}!=set(expected):
        raise ValueError('missing, extra, or duplicate source inventory file')
    for path, record in expected.items():
        safe_path(path)
        member=files[path]
        if member.mode!=record['mode'] or not re.fullmatch('[a-f0-9]{64}',record['sha256']):
            raise ValueError('source inventory size/mode/hash mismatch')
        if record['type']=='symlink':
            if not member.issym() or member.linkname!=record['linkTarget'] or len(member.linkname.encode())!=record['sizeBytes'] or hashlib.sha256(member.linkname.encode()).hexdigest()!=record['sha256']:
                raise ValueError('changed source symlink')
            continue
        if not member.isfile() or member.size!=record['sizeBytes'] or record['linkTarget']:raise ValueError('source file type/size mismatch')
        h=hashlib.sha256()
        with archive.extractfile(member) as stream:
            for chunk in iter(lambda:stream.read(1024*1024),b''):h.update(chunk)
        if h.hexdigest()!=record['sha256']:raise ValueError('changed source inventory file: '+path)


def gpg_arguments(executable=None, executable_sha256=None):
    if (executable is None)!=(executable_sha256 is None):raise ValueError('GPG path and SHA256 must be supplied together')
    if executable is None:return []
    path=pathlib.Path(executable)
    if not path.is_absolute() or '..' in path.parts or not re.fullmatch('[a-f0-9]{64}',executable_sha256):raise ValueError('GPG requires an absolute path and exact SHA256')
    return ['--gpg',str(path),'--gpg-sha256',executable_sha256]


def verify(bundle, expected_archive=None, expected_manifest=None, expected_source=None, expected_version=None, gpg=None, gpg_sha256=None):
    verifier_arguments=gpg_arguments(gpg,gpg_sha256)
    bundle=regular(bundle)
    archive_sha=digest_file(bundle)
    if expected_archive and archive_sha!=expected_archive:raise ValueError('staged source archive digest mismatch')
    with tarfile.open(bundle,'r:gz') as archive:
        manifest_member=archive.getmember('source-manifest.json')
        if not manifest_member.isfile() or manifest_member.size>8*1024**2:raise ValueError('unsafe source manifest')
        data=archive.extractfile(manifest_member).read();manifest=json.loads(data)
        manifest_sha=hashlib.sha256(data).hexdigest()
        if data!=canonical(manifest) or (expected_manifest and manifest_sha!=expected_manifest):raise ValueError('source manifest digest/canonical encoding mismatch')
        source_kind=manifest['kind']
        if manifest['schemaVersion']!=1 or (source_kind!='hostwright.corresponding-source.new-runtime.v1' and (source_kind!='hostwright.corresponding-source.v1' or manifest.get('pins')!=PINS)):
            raise ValueError('unexpected source bundle schema or pins')
        if not re.fullmatch('[a-f0-9]{40}',manifest['releaseSourceRevision']) or not valid_version(manifest['version']):raise ValueError('invalid source/version binding')
        if manifest['status']!='prepared-not-release-qualified' or manifest['publicationRoute']!='same-github-release-alongside-binaries' or manifest.get('upstreamSignatureVerified') is not True:raise ValueError('source preparation lacks authenticated upstream signature')
        if (expected_source and manifest['releaseSourceRevision']!=expected_source) or (expected_version and manifest['version']!=expected_version):raise ValueError('source bundle differs from accepted source/version')
        verify_records(archive,manifest['files'])
        if source_kind=='hostwright.corresponding-source.new-runtime.v1':
            spec=importlib.util.spec_from_file_location('runtime_provenance',pathlib.Path(__file__).with_name('verify-runtime-provenance.py'))
            validator=importlib.util.module_from_spec(spec);spec.loader.exec_module(validator)
            validator.verify_source_bundle(archive,manifest['releaseSourceRevision'])
            return dict(archiveSHA256=archive_sha,manifestSHA256=manifest_sha,sizeBytes=bundle.stat().st_size,
                        version=manifest['version'],releaseSourceRevision=manifest['releaseSourceRevision'],status=manifest['status'])
        records={r['path']:r for r in manifest['files']}
        if records['kernel/linux-6.18.15.tar.xz']['sha256']!=PINS['kernelSourceSHA256'] or records['kernel/linux-6.18.15.tar.xz']['sizeBytes']!=PINS['kernelSourceSizeBytes'] or records['kernel/actual.config']['sha256']!=PINS['kernelConfigurationSHA256']:
            raise ValueError('kernel corresponding-source pin mismatch')
        inventory_data=archive.extractfile('kernel/kata/inventory.json').read()
        if hashlib.sha256(inventory_data).hexdigest()!=PINS['kataInventorySHA256']:raise ValueError('Kata source inventory pin mismatch')
        inventory=json.loads(inventory_data)
        if inventory['revision']!=PINS['kataRevision'] or len(inventory['documents'])!=PINS['kataFileCount']:raise ValueError('Kata source recipe coverage mismatch')
        modes_data=archive.extractfile('kernel/kata/git-file-modes.json').read()
        if hashlib.sha256(modes_data).hexdigest()!=PINS['kataModesSHA256']:raise ValueError('Kata file mode pin mismatch')
        modes=json.loads(modes_data)
        for doc in inventory['documents']:
            if records['kernel/kata/'+doc['path']]['sha256']!=doc['sha256'] or records['kernel/kata/'+doc['path']]['mode']!=(0o777 if modes[doc['path']]=='120000' else int(modes[doc['path']][-3:],8)):raise ValueError('Kata recipe differs from pinned inventory')
        sdk_metadata=json.loads(archive.extractfile('licenses/sdk-candidate/source-documents.json').read())
        validate_sdk_notice_inventory(sdk_metadata,{p.removeprefix('licenses/sdk-candidate/'):r for p,r in records.items() if p.startswith('licenses/sdk-candidate/')})
        supplemental_data=archive.extractfile('kernel/kata/supplemental-inventory.json').read()
        if hashlib.sha256(supplemental_data).hexdigest()!=PINS['kataSupplementalSHA256']:raise ValueError('Kata build dependency inventory pin mismatch')
        supplemental=json.loads(supplemental_data)
        if supplemental['revision']!=PINS['kataRevision'] or len(supplemental['documents'])!=PINS['kataSupplementalFileCount']:raise ValueError('Kata build dependency coverage mismatch')
        for doc in supplemental['documents']:
            record=records['kernel/kata/'+doc['path']]
            if record['sha256']!=doc['sha256'] or record['mode']!=int(doc['gitMode'][-3:],8):raise ValueError('Kata build dependency differs from exact revision')
        loader_data=archive.extractfile('guest/retained-build-receipt.json').read()
        if hashlib.sha256(loader_data).hexdigest()!=PINS['retainedLoaderReceiptSHA256']:raise ValueError('retained guest receipt digest mismatch')
        loader=json.loads(loader_data)
        if loader['source']!=PINS['retainedLoaderSourceRevision'] or len(loader['sourceFiles'])!=20:raise ValueError('guest source coverage mismatch')
        for path,sha in loader['sourceFiles'].items():
            if records['guest/'+path]['sha256']!=sha:raise ValueError('guest source differs from retained build inventory')
        with tempfile.TemporaryDirectory(prefix='kernel-source-verification-',dir=bundle.parent) as temporary:
            temporary=pathlib.Path(temporary)
            for archive_path,name in [('kernel/linux-6.18.15.tar.xz','linux-6.18.15.tar.xz'),('kernel/upstream-evidence/linux-6.18.15.tar.sign','linux-6.18.15.tar.sign'),('kernel/upstream-evidence/gregkh-pinned-public-key.asc','gregkh-pinned-public-key.asc')]:
                with archive.extractfile(archive_path) as incoming,(temporary/name).open('xb') as outgoing:
                    import shutil
                    shutil.copyfileobj(incoming,outgoing,1024*1024)
            subprocess.run(['python3',str(pathlib.Path(__file__).with_name('verify-kernel-source-signature.py')),'--inputs',str(temporary),'--output',str(temporary/'verified-signature.json')]+verifier_arguments,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    return dict(archiveSHA256=archive_sha,manifestSHA256=manifest_sha,sizeBytes=bundle.stat().st_size,
                version=manifest['version'],releaseSourceRevision=manifest['releaseSourceRevision'],status=manifest['status'])


def valid_version(version):
    return re.fullmatch(r'0\.0\.2(?:-dev\.(?:[1-9][0-9]{0,2})|-rc\.(?:[1-9][0-9]?))?',version) is not None


def source_state(root):
    head=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()
    status=subprocess.check_output(['git','-C',str(root),'status','--porcelain=v1','--untracked-files=all'])
    return dict(head=head,clean=not status,gitStatusSHA256=hashlib.sha256(status).hexdigest())


def validate_sdk_notice_inventory(metadata, records):
    if metadata['kind']!='hostwright.sdk-candidate-runtime-source-notices.v1' or metadata['status']!='not-actual-oci-link-qualified' or metadata['sdkArchiveSHA256']!='d2078b69bdeb5c31202c10e9d8a11d6f66f82938b51a4b75f032ccb35c4c286c':
        raise ValueError('candidate SDK notice scope/pin mismatch')
    paths=set()
    for document in metadata['documents']:
        safe_path(document['path'])
        if document['path'] in paths:raise ValueError('duplicate candidate SDK notice')
        paths.add(document['path'])
        record=records.get(document['path'])
        if not record or record['sha256']!=document['sha256'] or record['sizeBytes']!=document['sizeBytes'] or document['sizeBytes']<=0:
            raise ValueError('candidate SDK source notice missing or changed')


def prepare(args):
    root=args.root.resolve();out_parent=args.output_parent.resolve()
    if root==out_parent or root in out_parent.parents:raise ValueError('source output must be outside the source checkout')
    if not valid_version(args.version) or not re.fullmatch('[a-f0-9]{40}',args.source):raise ValueError('invalid release source/version')
    before=source_state(root)
    if before['head']!=args.source:raise ValueError('requested source differs from preparation checkout HEAD')
    inputs={}
    def add(path,source):
        safe_path(path);source=regular(source)
        if path in inputs:raise ValueError('duplicate source output path')
        inputs[path]=source
    kernel=args.kernel_inputs
    add('kernel/linux-6.18.15.tar.xz',kernel/'linux-6.18.15.tar.xz');add('kernel/actual.config',kernel/'kernel-actual-config-6.18.15-186')
    if digest_file(inputs['kernel/linux-6.18.15.tar.xz'])!=PINS['kernelSourceSHA256'] or inputs['kernel/linux-6.18.15.tar.xz'].stat().st_size!=PINS['kernelSourceSizeBytes'] or digest_file(inputs['kernel/actual.config'])!=PINS['kernelConfigurationSHA256']:raise ValueError('retained kernel source/config pin mismatch')
    for name in ['kernel-sha256sums.asc','linux-6.18.15.tar.sign','kernel-download-receipt.json','gregkh-pinned-public-key.asc','kernel-source-signature-receipt-r2.json']:add('kernel/upstream-evidence/'+name,kernel/name)
    receipt=json.loads(inputs['kernel/upstream-evidence/kernel-download-receipt.json'].read_text())
    signature_receipt=json.loads(inputs['kernel/upstream-evidence/kernel-source-signature-receipt-r2.json'].read_text())
    if signature_receipt['archiveSHA256']!=PINS['kernelSourceSHA256'] or not signature_receipt['signatureVerified'] or signature_receipt['fingerprint']!='647F28654894E3BD457199BE38DBBDC86092693E':raise ValueError('kernel signature evidence mismatch')
    if receipt['verifiedSHA256']!=PINS['kernelSourceSHA256']:raise ValueError('kernel download receipt mismatch')
    with tarfile.open(inputs['kernel/linux-6.18.15.tar.xz'],'r:xz') as archive:validate_members(archive,'linux-6.18.15')
    add('kernel/kata/inventory.json',args.kata_recipes/'inventory.json')
    if digest_file(inputs['kernel/kata/inventory.json'])!=PINS['kataInventorySHA256']:raise ValueError('Kata source inventory mismatch')
    inventory=json.loads(inputs['kernel/kata/inventory.json'].read_text())
    add('kernel/kata/git-file-modes.json',args.kata_recipes/'git-file-modes.json')
    if digest_file(inputs['kernel/kata/git-file-modes.json'])!=PINS['kataModesSHA256']:raise ValueError('Kata file mode inventory mismatch')
    modes=json.loads(inputs['kernel/kata/git-file-modes.json'].read_text())
    for document in inventory['documents']:
        safe_path(document['path']);path=args.kata_recipes/document['path'];add('kernel/kata/'+document['path'],path)
        data=path.read_bytes()
        if hashlib.sha256(data).hexdigest()!=document['sha256'] or len(data)!=document['sizeBytes'] or hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()!=document['gitBlobSHA']:raise ValueError('Kata recipe file differs from exact revision')
    add('kernel/kata/supplemental-inventory.json',args.kata_recipes/'supplemental-inventory.json')
    if digest_file(inputs['kernel/kata/supplemental-inventory.json'])!=PINS['kataSupplementalSHA256']:raise ValueError('Kata build dependency inventory mismatch')
    supplemental=json.loads(inputs['kernel/kata/supplemental-inventory.json'].read_text())
    for doc in supplemental['documents']:
        safe_path(doc['path']);path=args.kata_recipes/doc['path'];add('kernel/kata/'+doc['path'],path);data=path.read_bytes()
        if hashlib.sha256(data).hexdigest()!=doc['sha256'] or hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()!=doc['gitBlobSHA']:raise ValueError('Kata build dependency differs from pinned Git blob')
        modes[doc['path']]=doc['gitMode']
    add('guest/retained-build-receipt.json',args.loader_receipt);loader=json.loads(regular(args.loader_receipt).read_text())
    if loader['source']!=PINS['retainedLoaderSourceRevision'] or len(loader['sourceFiles'])!=20:raise ValueError('unexpected retained guest source receipt')
    for path,sha in loader['sourceFiles'].items():
        safe_path(path)
        if not path.startswith('Guest/HostwrightNetfilter/'):raise ValueError('guest source path outside owned package')
        add('guest/'+path,root/path)
        if digest_file(inputs['guest/'+path])!=sha:raise ValueError('guest source differs from retained source receipt')
    for name in ['LICENSE','THIRD_PARTY_NOTICES','third-party-license-inventory.json','runtime-license-inventory.json','Package.resolved']:add('licenses/'+name,root/name)
    for source in sorted((root/'ThirdPartyLicenses/runtime-sdk-source-notices').rglob('*')):
        if source.is_file():add('licenses/sdk-candidate/'+str(source.relative_to(root/'ThirdPartyLicenses/runtime-sdk-source-notices')),source)
    add('SOURCE_DISTRIBUTION.md',root/'docs/reference/corresponding-source-bundle.md')
    for name in ['corresponding-source.py','verify-kernel-source-signature.py']:
        if (root/'scripts/release'/name).exists():add('verification/'+name,root/'scripts/release'/name)
    records=[]
    for path,file in sorted(inputs.items()):
        git_mode=modes.get(path.removeprefix('kernel/kata/'),'100644') if path.startswith('kernel/kata/') else '100644'
        records.append(dict(path=path,sha256=digest_file(file),sizeBytes=file.stat().st_size,
                            mode=0o777 if git_mode=='120000' else int(git_mode[-3:],8),
                            type='symlink' if git_mode=='120000' else 'regular',
                            linkTarget=file.read_text() if git_mode=='120000' else ''))
    sdk_metadata=json.loads((root/'ThirdPartyLicenses/runtime-sdk-source-notices/source-documents.json').read_text())
    validate_sdk_notice_inventory(sdk_metadata,{r['path'].removeprefix('licenses/sdk-candidate/'):r for r in records if r['path'].startswith('licenses/sdk-candidate/')})
    after=source_state(root)
    if after!=before or any(digest_file(inputs[r['path']])!=r['sha256'] for r in records):raise ValueError('source inputs changed during preparation')
    manifest=dict(kind='hostwright.corresponding-source.v1',schemaVersion=1,pins=PINS,version=args.version,
                  releaseSourceRevision=args.source,preparedSourceState=before,status='prepared-not-release-qualified',
                  publicationRoute='same-github-release-alongside-binaries',upstreamSignatureVerified=signature_receipt['signatureVerified'],
                  limitations=['Retained loader build is not final candidate runtime qualification.',
                               'Kata recipe/config/source bytes are retained; exact original applied build flags are not established.',
                               'Published vminit static runtime and complete OCI digest-to-source/link provenance remain separate required evidence.'],files=records)
    out=pathlib.Path(tempfile.mkdtemp(prefix='hostwright-source-'+args.source[:12]+'-',dir=out_parent))
    bundle=out/('hostwright-'+args.version+'-'+args.source[:12]+'-corresponding-source.tar.gz')
    data=canonical(manifest)
    try:
        with bundle.open('xb') as raw,gzip.GzipFile(filename='',mode='wb',fileobj=raw,compresslevel=1,mtime=0) as compressed,tarfile.open(fileobj=compressed,mode='w',format=tarfile.PAX_FORMAT) as archive:
            for record in records:
                info=tarfile.TarInfo(record['path']);info.size=record['sizeBytes'];info.mode=record['mode'];info.mtime=0
                if record['type']=='symlink':
                    info.type=tarfile.SYMTYPE;info.size=0;info.linkname=record['linkTarget'];archive.addfile(info)
                else:
                    with inputs[record['path']].open('rb') as stream:archive.addfile(info,stream)
            info=tarfile.TarInfo('source-manifest.json');info.size=len(data);info.mode=0o644;info.mtime=0;archive.addfile(info,io.BytesIO(data))
        verified=verify(bundle,gpg=args.gpg,gpg_sha256=args.gpg_sha256)
        if source_state(root)!=before or any(digest_file(inputs[r['path']])!=r['sha256'] for r in records):raise ValueError('source inputs changed after packaging')
        (out/'source-manifest.json').write_bytes(data);(out/'source-bundle-receipt.json').write_bytes(canonical(verified));print(json.dumps(dict(directory=str(out),archive=str(bundle),**verified),sort_keys=True))
    except BaseException:
        import shutil
        shutil.rmtree(out)
        raise


def main():
    p=argparse.ArgumentParser();subs=p.add_subparsers(dest='command',required=True)
    q=subs.add_parser('prepare');q.add_argument('--root',type=pathlib.Path,required=True);q.add_argument('--kernel-inputs',type=pathlib.Path,required=True);q.add_argument('--kata-recipes',type=pathlib.Path,required=True);q.add_argument('--loader-receipt',type=pathlib.Path,required=True);q.add_argument('--output-parent',type=pathlib.Path,required=True);q.add_argument('--version',required=True);q.add_argument('--source',required=True)
    q=subs.add_parser('verify');q.add_argument('--archive',type=pathlib.Path,required=True);q.add_argument('--expected-archive-sha256',required=True);q.add_argument('--expected-manifest-sha256',required=True);q.add_argument('--expected-source',required=True);q.add_argument('--expected-version',required=True)
    for parser in subs.choices.values():parser.add_argument('--gpg');parser.add_argument('--gpg-sha256')
    args=p.parse_args()
    gpg_arguments(args.gpg,args.gpg_sha256)
    if args.command=='prepare':prepare(args)
    else:
        if not re.fullmatch('[a-f0-9]{64}',args.expected_archive_sha256) or not re.fullmatch('[a-f0-9]{64}',args.expected_manifest_sha256):raise ValueError('exact staged archive and manifest digests are required')
        print(json.dumps(verify(args.archive,args.expected_archive_sha256,args.expected_manifest_sha256,args.expected_source,args.expected_version,args.gpg,args.gpg_sha256),sort_keys=True))
if __name__=='__main__':main()
