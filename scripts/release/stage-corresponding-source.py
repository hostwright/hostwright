#!/usr/bin/env python3
"""Bind source bytes to staged products; qualification requires independent verification."""
import argparse,hashlib,json,pathlib,re,shutil,subprocess,tarfile,zipfile
EMPTY_STATUS_SHA256=hashlib.sha256(b'').hexdigest()
KIND='hostwright.corresponding-source.v1'

def sha(path):
 path=pathlib.Path(path)
 if path.is_symlink() or not path.is_file():raise ValueError('unsafe source stage input')
 with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def canonical(value):return (json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False)+'\n').encode()
def parse(data):
 def pairs(items):
  result={}
  for key,value in items:
   if key in result:raise ValueError('duplicate source JSON key')
   result[key]=value
  return result
 return json.loads(data,object_pairs_hook=pairs)
def read(path):
 sha(path)
 if path.stat().st_size>16*1024**2:raise ValueError('oversized source metadata')
 return path.read_bytes()
def archive_name(commit,version):
 if not re.fullmatch('[a-f0-9]{40}',commit) or not re.fullmatch(r'0\.0\.2(?:-dev\.[1-9][0-9]{0,2}|-rc\.[1-9][0-9]?)?',version):raise ValueError('invalid source/version')
 return 'hostwright-'+version+'-'+commit[:12]+'-corresponding-source.tar.gz'
def validate_manifest(manifest,commit,version):
 state=manifest.get('preparedSourceState',{})
 if (manifest.get('kind')!=KIND or manifest.get('schemaVersion')!=1 or manifest.get('releaseSourceRevision')!=commit or manifest.get('version')!=version or manifest.get('status')!='prepared-not-release-qualified' or manifest.get('publicationRoute')!='same-github-release-alongside-binaries' or manifest.get('upstreamSignatureVerified') is not True or state.get('head')!=commit or state.get('clean') is not True or state.get('gitStatusSHA256')!=EMPTY_STATUS_SHA256):
  raise ValueError('source manifest is mismatched, dirty, or lacks pinned signature preparation')
def descriptor(root,commit,version):
 source=root/'source';name=archive_name(commit,version)
 if source.is_symlink() or not source.is_dir() or {p.name for p in source.iterdir()}!={name,'source-manifest.json','SOURCE_SHA256SUMS'}:raise ValueError('missing or unexpected staged corresponding-source files')
 manifest_data=read(source/'source-manifest.json');manifest=parse(manifest_data)
 if canonical(manifest)!=manifest_data:raise ValueError('noncanonical source manifest')
 validate_manifest(manifest,commit,version)
 archive_sha=sha(source/name);manifest_sha=sha(source/'source-manifest.json')
 checksums=(archive_sha+'  '+name+'\n'+manifest_sha+'  source-manifest.json\n').encode()
 if read(source/'SOURCE_SHA256SUMS')!=checksums:raise ValueError('source checksum inventory mismatch')
 return dict(kind='hostwright.corresponding-source-stage.v1',sourceCommit=commit,version=version,
             sourceManifestKind=KIND,sourceManifestSchemaVersion=1,
             archive=dict(fileName=name,sha256=archive_sha,sizeBytes=(source/name).stat().st_size),
             manifest=dict(fileName='source-manifest.json',sha256=manifest_sha,sizeBytes=len(manifest_data)),
             checksums=dict(fileName='SOURCE_SHA256SUMS',sha256=sha(source/'SOURCE_SHA256SUMS')))
def qualified_runtime(runtime):
 # No validator yet binds the actual OCI static link/build provenance to source and licenses.
 # Producer signatures and matching inventory JSON cannot establish that missing proof.
 raise ValueError('runtime provenance validator unavailable: source stage fails closed; editable status/license/evidence fields cannot qualify actual runtime bytes')
def source_evidence_contents(runtime):
 result=parse(canonical(runtime));result.pop('payloadFiles',None)
 for asset in result['assets']:
  if asset['identity']=='hostwright-netfilter-loader':asset.pop('sha256',None);asset.pop('sizeBytes',None)
 return result
def gpg_arguments(path=None,digest=None):
 if (path is None)!=(digest is None):raise ValueError('GPG path and SHA256 must be supplied together')
 if path is None:return []
 executable=pathlib.Path(path)
 if not executable.is_absolute() or '..' in executable.parts or not re.fullmatch('[a-f0-9]{64}',digest):raise ValueError('GPG requires an absolute path and exact SHA256')
 return ['--gpg',str(executable),'--gpg-sha256',digest]
def verify_contract(root,commit,version,gpg=None,gpg_sha256=None):
 binding=descriptor(root,commit,version);source=root/'source';archive=source/binding['archive']['fileName']
 command=['python3',str(pathlib.Path(__file__).with_name('corresponding-source.py')),'verify','--archive',str(archive),'--expected-archive-sha256',binding['archive']['sha256'],'--expected-manifest-sha256',binding['manifest']['sha256'],'--expected-source',commit,'--expected-version',version]+gpg_arguments(gpg,gpg_sha256)
 result=subprocess.run(command,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE);verified=parse(result.stdout)
 if verified.get('archiveSHA256')!=binding['archive']['sha256'] or verified.get('manifestSHA256')!=binding['manifest']['sha256'] or verified.get('releaseSourceRevision')!=commit or verified.get('version')!=version:raise ValueError('independent source verifier returned different bindings')
 with tarfile.open(archive,'r:gz') as bundle:
  manifests=[m for m in bundle.getmembers() if m.name=='source-manifest.json'];runtimes=[m for m in bundle.getmembers() if m.name=='licenses/runtime-license-inventory.json']
  if len(manifests)!=1 or not manifests[0].isfile() or bundle.extractfile(manifests[0]).read()!=read(source/'source-manifest.json'):raise ValueError('external source manifest differs from bundled bytes')
  if len(runtimes)!=1 or not runtimes[0].isfile() or runtimes[0].size>16*1024**2:raise ValueError('source bundle lacks exact runtime license inventory')
  source_runtime=parse(bundle.extractfile(runtimes[0]).read())
 release=parse(read(root/'release/release-manifest.json'))
 if (pathlib.PurePosixPath(release['archive']['fileName']).name!=release['archive']['fileName'] or not release['archive']['fileName'].endswith('.zip') or not re.fullmatch('[A-Za-z0-9_.-]+',release['artifactID'])):raise ValueError('unsafe product archive identity')
 product=root/'release'/release['archive']['fileName']
 if sha(product)!=release['archive']['sha256']:raise ValueError('product archive changed')
 path=release['artifactID']+'/share/doc/hostwright/runtime-license-inventory.json'
 with zipfile.ZipFile(product) as archive:
  matches=[i for i in archive.infolist() if i.filename==path]
  if len(matches)!=1 or matches[0].file_size>16*1024**2:raise ValueError('product lacks exact runtime license inventory')
  product_runtime=parse(archive.read(matches[0]))
 if source_evidence_contents(source_runtime)!=source_evidence_contents(product_runtime):raise ValueError('product runtime source evidence differs from corresponding-source contents')
 qualified_runtime(source_runtime)
 qualified_runtime(product_runtime)
 return binding

def install(root,prepared,commit,version,gpg=None,gpg_sha256=None):
 gpg_arguments(gpg,gpg_sha256)
 name=archive_name(commit,version)
 if prepared.is_symlink() or not prepared.is_dir() or root.is_symlink() or not root.is_dir():raise ValueError('unsafe staging directory')
 manifest_data=read(prepared/'source-manifest.json');validate_manifest(parse(manifest_data),commit,version);archive_sha=sha(prepared/name);manifest_sha=sha(prepared/'source-manifest.json')
 output=root/'source'
 if output.exists() or output.is_symlink():raise ValueError('source stage already exists')
 output.mkdir(mode=0o700)
 try:
  shutil.copyfile(prepared/name,output/name);shutil.copyfile(prepared/'source-manifest.json',output/'source-manifest.json')
  (output/'SOURCE_SHA256SUMS').write_bytes((archive_sha+'  '+name+'\n'+manifest_sha+'  source-manifest.json\n').encode())
  for path in output.iterdir():path.chmod(0o644)
  binding=verify_contract(root,commit,version,gpg,gpg_sha256)
  if binding['archive']['sha256']!=archive_sha or binding['manifest']['sha256']!=manifest_sha:raise ValueError('source changed during staging')
  return binding
 except BaseException:shutil.rmtree(output);raise

def main():
 p=argparse.ArgumentParser();p.add_argument('mode',choices=['install','verify']);p.add_argument('--root',type=pathlib.Path,required=True);p.add_argument('--prepared-dir',type=pathlib.Path);p.add_argument('--commit',required=True);p.add_argument('--version',required=True);p.add_argument('--gpg');p.add_argument('--gpg-sha256');a=p.parse_args()
 result=install(a.root,a.prepared_dir,a.commit,a.version,a.gpg,a.gpg_sha256) if a.mode=='install' else verify_contract(a.root,a.commit,a.version,a.gpg,a.gpg_sha256)
 print(json.dumps(result,sort_keys=True))
if __name__=='__main__':main()
