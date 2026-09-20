#!/usr/bin/env python3
import copy, gzip, hashlib, importlib.util, io, pathlib, struct, subprocess, tarfile, unittest
from unittest import mock
spec=importlib.util.spec_from_file_location('validator',pathlib.Path(__file__).with_name('verify-runtime-provenance.py'))
v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)

def elf(relocatable=False):
 data=bytearray(64 if relocatable else 120);data[:7]=b'\x7fELF\x02\x01\x01'
 struct.pack_into('<HH',data,16,1 if relocatable else 2,183)
 if not relocatable:
  struct.pack_into('<Q',data,32,64);struct.pack_into('<HH',data,54,56,1)
  struct.pack_into('<I',data,64,1)
 return bytes(data)

def arm64_image():
 data=bytearray(128)
 struct.pack_into('<QQQQQQ',data,8,0,4096,0xa,0,0,0)
 data[56:60]=b'ARM\x64'
 return bytes(data)

def tar(files):
 buffer=io.BytesIO()
 with tarfile.open(fileobj=buffer,mode='w:gz') as archive:
  for name,data in files.items():
   item=tarfile.TarInfo(name);item.size=len(data);archive.addfile(item,io.BytesIO(data))
 return buffer.getvalue()

def fixture():
 files={}
 def add(name,data):
  files[name]=data
  return dict(path=name,sha256=v.digest(data),sizeBytes=len(data))
 source=b'int main() { return 0; }\n';source_files={'main.c':source,'LICENSE':b'Fixture license text\n','NOTICE':b'Fixture notice text\n'}
 leaves=[dict(path=n,gitMode='100644',gitBlobSHA1=v.git_object('blob',d),sha256=v.digest(d),sizeBytes=len(d)) for n,d in sorted(source_files.items())]
 root=v.git_object('tree',b''.join(b'100644 '+r['path'].encode()+b'\0'+bytes.fromhex(r['gitBlobSHA1']) for r in leaves))
 commit=b'tree '+root.encode()+b'\nauthor Fixture <fixture@example.invalid> 1 +0000\ncommitter Fixture <fixture@example.invalid> 1 +0000\n\nFixture\n'
 def notice(name):return dict(add('proof/'+name,source_files[name]),sourcePath=name,component='compiled-project',spdx='MIT')
 project=dict(identity='compiled-project',commit=v.git_object('commit',commit),tree=root,spdx='MIT',
  commitObject=add('proof/source.commit',commit),archive=add('proof/source.tar.gz',tar(source_files)),
  inventory=add('proof/source-inventory.json',v.canonical(leaves)),licenses=[notice('LICENSE')],notices=[notice('NOTICE')],patches=[])
 tools=[]
 for identity,name in [('compiler','clang'),('linker','ld.lld')]:
  tools.append(dict(identity=identity,executablePath='/toolchains/'+name,executable=add('proof/'+name,elf()),version=add('proof/'+name+'.version',(name+' fixture version\n').encode()),
   environment=add('proof/'+name+'.env',v.canonical({'architecture':'arm64','os':'linux'})),loadedLibraries=[]))
 object=elf(True);header=(b'main.o/         '+b'0           '+b'0     '+b'0     '+b'644     '+str(len(object)).encode().ljust(10)+b'`\n')
 archive=b'!<arch>\n'+header+object
 def link(name):
  return dict(path=name,outputSHA256=v.digest(elf()),map=add('proof/'+name.replace('/','-')+'.map',b'             VMA              LMA     Size Align Out     In      Symbol\n          200270           200270       24     4         libcompiled.a(main.o):(.text)\n'),
   commands=[add('proof/'+name.replace('/','-')+'.argv',v.canonical(['/toolchains/ld.lld','@response','-Map=output.map','-o','output','libcompiled.a']))],
   responseFiles=[add('proof/'+name.replace('/','-')+'.rsp',b'libcompiled.a\n')],
   selectedInputs=[dict(mapInput='libcompiled.a(main.o)',file=add('proof/libcompiled.a',archive),member='main.o',objectSHA256=v.digest(object),
     sourceFiles=[dict(project='compiled-project',path='main.c',sha256=v.digest(source))])])
 prefix='share/hostwright/containerization/vminit';payloads={}
 def blob(data):
  digest=v.digest(data);payloads[prefix+'/blobs/sha256/'+digest]=data
  return dict(digest='sha256:'+digest,size=len(data))
 layer=blob(tar({'sbin/vminitd':elf(),'sbin/vmexec':elf()}));layer['mediaType']='application/vnd.oci.image.layer.v1.tar+gzip'
 config=blob(v.canonical(dict(architecture='arm64',os='linux',rootfs=dict(type='layers',diff_ids=['sha256:'+v.digest(gzip.decompress(payloads[prefix+'/blobs/sha256/'+layer['digest'][7:]]))]))));config['mediaType']='application/vnd.oci.image.config.v1+json'
 image=blob(v.canonical(dict(schemaVersion=2,mediaType='application/vnd.oci.image.manifest.v1+json',config=config,layers=[layer])));image['mediaType']='application/vnd.oci.image.manifest.v1+json'
 payloads[prefix+'/index.json']=v.canonical(dict(schemaVersion=2,mediaType='application/vnd.oci.image.index.v1+json',manifests=[image]))
 payloads[prefix+'/oci-layout']=v.canonical(dict(imageLayoutVersion='1.0.0'))
 kernel='share/hostwright/containerization/kernel/vmlinux';loader='share/hostwright/containerization/guest/hostwright-netfilter'
 payloads[kernel]=arm64_image();payloads[loader]=elf()
 runtime=dict(kind='hostwright.runtime-license-inventory.v1',schemaVersion=1,status='qualified',assets=[dict(identity=i,status='qualified',blockers=[],licenseExpression='MIT') for i in ('kata-linux-kernel','apple-vminit-oci','hostwright-netfilter-loader')])
 manifest=dict(kind=v.KIND,schemaVersion=1,sourceCommit=project['commit'],closureMode='new-source-build',producer=dict(commit=project['commit'],runID=1,attempt=1),
  runtimeInventorySHA256=v.digest(v.canonical(runtime)),payloads=[dict(path=p,sha256=v.digest(d),sizeBytes=len(d)) for p,d in payloads.items()],sourceProjects=[project],
  oci=dict(prefix=prefix,links=[link('sbin/vminitd'),link('sbin/vmexec')],files=[dict(path=n,sha256=v.digest(elf()),sizeBytes=len(elf()),type='elf',components=['compiled-project']) for n in ['sbin/vminitd','sbin/vmexec']]),loader=link(loader),toolchain=tools,
  licensing={i:[dict(project='compiled-project',spdx='MIT',licenses=['proof/LICENSE'],notices=['proof/NOTICE'])] for i in ['kata-linux-kernel','apple-vminit-oci','hostwright-netfilter-loader']},
  kernel=dict(project='compiled-project',payloadPath=kernel,outputSHA256=v.digest(arm64_image()),config=add('proof/kernel.config',b'CONFIG_ARM64=y\n'),compiler=tools[0]['executable'],commands=add('proof/kernel.argv',v.canonical(['/toolchains/clang','-o','vmlinux','main.c'])),patches=[]))
 return manifest,runtime,payloads,files

class RuntimeProvenanceTests(unittest.TestCase):
 def test_lld_map_uses_input_column_and_preserves_spaced_object_names(self):
  header='             VMA              LMA     Size Align Out     In      Symbol\n'
  internal='          200270           200270       24     4         <internal>:(.note.gnu.build-id)\n'
  selected='          200294           200294        4     4         /build/OrderedSet+Partial SetAlgebra.swift.o:(.text)\n'
  symbol='          200294           200294        4     4                 mldsa::(anonymous namespace)::run()\n'
  self.assertEqual(v.lld_map_inputs(header+internal+selected+symbol),{'/build/OrderedSet+Partial SetAlgebra.swift.o'})
  with self.assertRaisesRegex(ValueError,'unsupported LLD input row'):
   v.lld_map_inputs(header+'          200294           200294        4     4         unexplained-input\n')
 def test_kernel_payload_requires_raw_arm64_image_header(self):
  v.arm64_image(arm64_image())
  for payload in (elf(),b'ARM\x64',arm64_image()[:40],arm64_image()[:56]+b'bad!'+arm64_image()[60:]):
   with self.subTest(payload=payload[:8]),self.assertRaises(ValueError):v.arm64_image(payload)
  for offset,value in ((16,64),(24,1),(32,1),(8,4096)):
   payload=bytearray(arm64_image());struct.pack_into('<Q',payload,offset,value)
   with self.subTest(offset=offset),self.assertRaises(ValueError):v.arm64_image(payload)
 def test_static_sdk_spdx_identifiers_require_exact_known_values(self):
  self.assertEqual(v.spdx('0BSD AND bzip2-1.0.6'),'0BSD AND bzip2-1.0.6')
  for expression in ('0bsd','bzip2-1.0.5','LicenseRef-bzip2'):
   with self.subTest(expression=expression),self.assertRaisesRegex(ValueError,'unsupported SPDX identifier'):
    v.spdx(expression)
 def test_authenticated_seam_accepts_actual_byte_bindings_without_receipt_verification_flags(self):
  manifest,runtime,payloads,files=fixture()
  with mock.patch.object(v,'authenticate') as auth:
   result=v.verify(v.canonical(manifest),runtime,payloads,files.__getitem__,manifest['sourceCommit'])
  self.assertEqual(result['payloadCount'],len(payloads));self.assertEqual(auth.call_count,len(payloads)+1)
  self.assertNotIn('signatureVerified',manifest);self.assertNotIn('qualified',manifest)
 def test_forged_receipt_cannot_replace_authentication(self):
  manifest,runtime,payloads,files=fixture();manifest.update(signatureVerified=True,qualified=True)
  with mock.patch.object(v,'authenticate',side_effect=ValueError('untrusted producer')):
   with self.assertRaisesRegex(ValueError,'untrusted producer'):v.verify(v.canonical(manifest),runtime,payloads,files.__getitem__,manifest['sourceCommit'])
 def test_missing_source_link_license_and_wrong_payload_refused_after_authentication(self):
  for change in ('source','link','license','asset','member'):
   manifest,runtime,payloads,files=fixture()
   if change=='source':del files['proof/source.commit']
   elif change=='link':manifest['oci']['links'][0]['selectedInputs']=[]
   elif change=='license':manifest['sourceProjects'][0]['licenses']=[]
   elif change=='asset':payloads[next(iter(payloads))]+=b'drift'
   else:manifest['oci']['links'][0]['selectedInputs'][0]['objectSHA256']='b'*64
   with self.subTest(change=change),mock.patch.object(v,'authenticate'):
    with self.assertRaises((ValueError,KeyError)):v.verify(v.canonical(manifest),runtime,payloads,files.__getitem__,manifest['sourceCommit'])
 def test_complete_source_tree_cannot_be_replaced_by_flags(self):
  manifest,runtime,payloads,files=fixture();manifest['sourceProjects'][0]['tree']='b'*40
  with mock.patch.object(v,'authenticate'):
   with self.assertRaises(ValueError):v.verify(v.canonical(manifest),runtime,payloads,files.__getitem__,manifest['sourceCommit'])
 def test_production_authentication_pins_workflow_commit_source_and_run(self):
  manifest,_,_,_=fixture()
  with mock.patch.object(v.subprocess,'run',return_value=subprocess.CompletedProcess([],1)) as run:
   with self.assertRaisesRegex(ValueError,'attestation verification failed'):v.authenticate(pathlib.Path(__file__),manifest['producer'],manifest['sourceCommit'])
  args=run.call_args.args[0]
  self.assertEqual(args[args.index('--signer-workflow')+1],v.REPO+'/'+v.WORKFLOW)
  self.assertEqual(args[args.index('--source-digest')+1],manifest['sourceCommit'])
  self.assertIn('--deny-self-hosted-runners',args);self.assertNotIn('--custom-trusted-root',args)
 def test_source_bundle_and_actual_product_bytes_are_independently_compared(self):
  manifest,runtime,payloads,files=fixture()
  files=dict(files,**{'licenses/runtime-license-inventory.json':v.canonical(runtime),'runtime-provenance/manifest.json':v.canonical(manifest)})
  files.update({'runtime-provenance/payloads/'+p:d for p,d in payloads.items()})
  with tarfile.open(fileobj=io.BytesIO(tar(files)),mode='r:gz') as archive,mock.patch.object(v,'authenticate'):
   result=v.verify_source_bundle(archive,manifest['sourceCommit'],payloads)
   self.assertEqual(result['payloadCount'],len(payloads))
   forged=dict(payloads);forged[next(iter(forged))]+=b'changed'
   with self.assertRaisesRegex(ValueError,'actual product/runtime'):v.verify_source_bundle(archive,manifest['sourceCommit'],forged)
 def test_patch_replay_requires_exact_context_and_before_after_binding(self):
  patch=b'--- a/main.c\n+++ b/main.c\n@@ -1 +1 @@\n-old\n+new\n'
  files={'main.c':b'old\n'};v.apply_patch_bytes(patch,files);self.assertEqual(files['main.c'],b'new\n')
  with self.assertRaisesRegex(ValueError,'context mismatch'):v.apply_patch_bytes(patch,files)
  with self.assertRaises(ValueError):v.apply_patch_bytes(patch.replace(b'b/main.c',b'b/../escape'),{'main.c':b'old\n'})
 def test_wrong_authenticated_workflow_and_run_are_rejected_even_after_cli_success(self):
  producer=dict(commit='a'*40,runID=1,attempt=1)
  cert=dict(issuer='https://token.actions.githubusercontent.com',buildSignerURI='https://github.com/'+v.REPO+'/'+v.WORKFLOW+'@refs/heads/main',buildSignerDigest='a'*40,
   sourceRepositoryURI='https://github.com/'+v.REPO,sourceRepositoryDigest='a'*40,sourceRepositoryRef='refs/heads/main',runnerEnvironment='github-hosted',
   runInvocationURI='https://github.com/'+v.REPO+'/actions/runs/1/attempts/1')
  result=[dict(verificationResult=dict(signature=dict(certificate=cert),verifiedTimestamps=[{'type':'Tlog'}],statement=dict(subject=[dict(digest={'sha256':v.digest(pathlib.Path(__file__).read_bytes())})])))]
  def run(args,**kwargs):kwargs['stdout'].write(v.canonical(result));return subprocess.CompletedProcess(args,0)
  with mock.patch.object(v.subprocess,'run',side_effect=run):
   v.authenticate(pathlib.Path(__file__),producer,'a'*40)
   for field,value in [('buildSignerURI','https://github.com/attacker/workflow@refs/heads/main'),('runInvocationURI','https://github.com/'+v.REPO+'/actions/runs/2/attempts/1'),('runnerEnvironment','self-hosted')]:
    old=cert[field];cert[field]=value
    with self.assertRaisesRegex(ValueError,'wrong authenticated runtime'):v.authenticate(pathlib.Path(__file__),producer,'a'*40)
    cert[field]=old
 def test_go_loader_reads_actual_inline_module_info_and_rejects_invented_module(self):
  manifest,runtime,payloads,files=fixture();project=manifest['sourceProjects'][0]
  info=b'0'*16+b'mod\texample.invalid/fixture\tv1.0.0\th1:fixture\n'+b'0'*16
  def string(data):
   self.assertLess(len(data),128);return bytes([len(data)])+data
  header=bytearray(32);header[:14]=b'\xff Go buildinf:';header[14]=8;header[15]=2
  output=elf()+b'0'*8+bytes(header)+string(b'go1.26.5')+string(info)
  loader=dict(format='go-buildinfo-v1',path=manifest['loader']['path'],outputSHA256=v.digest(output),project=project['identity'],goRuntimeProject=project['identity'],goVersion='go1.26.5',
   modules=[dict(project=project['identity'],revision=project['commit'],buildInfo=['example.invalid/fixture','v1.0.0','h1:fixture'])],moduleRevisions={project['identity']:project['commit']},packageTrace=dict(path='proof/package-trace',sha256='',sizeBytes=0),sourceFiles=manifest['loader']['selectedInputs'][0]['sourceFiles'],commands=manifest['loader']['commands'],compiler=manifest['kernel']['compiler'])
  pkg=b'go object linux arm64 go1.26.5\n';pkg_header=b'__.PKGDEF/      '+b'0           '+b'0     '+b'0     '+b'644     '+str(len(pkg)).encode().ljust(10)+b'`\n';pkg_archive=b'!<arch>\n'+pkg_header+pkg+(b'\n' if len(pkg)%2 else b'');files['proof/go-package.a']=pkg_archive
  trace=v.canonical([dict(project=project['identity'],archive=dict(path='proof/go-package.a',sha256=v.digest(pkg_archive),sizeBytes=len(pkg_archive)),sourceFiles=loader['sourceFiles'])]);files['proof/package-trace']=trace;loader['packageTrace'].update(sha256=v.digest(trace),sizeBytes=len(trace))
  tools=v.toolchain(manifest,files.__getitem__)
  with mock.patch.object(v,'authenticate'):
   v.go_loader(loader,output,{project['identity']:v.source_project(project,files.__getitem__)},files.__getitem__,tools)
   loader['modules'][0]['buildInfo'][1]='v2.0.0'
   with self.assertRaisesRegex(ValueError,'module coverage'):v.go_loader(loader,output,{project['identity']:v.source_project(project,files.__getitem__)},files.__getitem__,tools)
 def test_empty_authenticated_toolchain_argv_and_kernel_inputs_never_qualify(self):
  for change in ('toolchain','executable','argv','kernel-config','kernel-compiler','kernel-commands','map','response'):
   manifest,runtime,payloads,files=fixture()
   if change=='toolchain':manifest['toolchain']=[]
   else:
    record={'executable':manifest['toolchain'][0]['executable'],'argv':manifest['oci']['links'][0]['commands'][0],
      'kernel-config':manifest['kernel']['config'],'kernel-compiler':manifest['kernel']['compiler'],
      'kernel-commands':manifest['kernel']['commands'],'map':manifest['oci']['links'][0]['map'],
      'response':manifest['oci']['links'][0]['responseFiles'][0]}[change]
    files[record['path']]=b'';record.update(sha256=v.digest(b''),sizeBytes=0)
   with self.subTest(change=change),mock.patch.object(v,'authenticate'):
    with self.assertRaises(ValueError):v.verify(v.canonical(manifest),runtime,payloads,files.__getitem__,manifest['sourceCommit'])
 def test_replacement_license_notice_and_spdx_status_do_not_replace_source_mapping(self):
  for change in ('license','notice','component','spdx','asset-spdx','asset-status','mapping'):
   manifest,runtime,payloads,files=fixture()
   if change in ('license','notice'):
    record=manifest['sourceProjects'][0]['licenses' if change=='license' else 'notices'][0]
    files[record['path']]=b'arbitrary replacement';record.update(sha256=v.digest(files[record['path']]),sizeBytes=len(files[record['path']]))
   elif change=='component':manifest['sourceProjects'][0]['licenses'][0]['component']='unrelated'
   elif change=='spdx':manifest['sourceProjects'][0]['licenses'][0]['spdx']='Apache-2.0'
   elif change=='asset-spdx':runtime['assets'][0]['licenseExpression']='Apache-2.0'
   elif change=='asset-status':runtime['assets'][0]['status']='blocked'
   else:manifest['licensing']['kata-linux-kernel'][0]['licenses']=['proof/NOTICE']
   manifest['runtimeInventorySHA256']=v.digest(v.canonical(runtime))
   with self.subTest(change=change),mock.patch.object(v,'authenticate'):
    with self.assertRaises(ValueError):v.verify(v.canonical(manifest),runtime,payloads,files.__getitem__,manifest['sourceCommit'])
 def test_unattributed_or_forged_non_elf_layer_file_is_refused(self):
  for change in ('missing','wrong-source','unsupported'):
   manifest,runtime,payloads,files=fixture();prefix=manifest['oci']['prefix'];index=v.parse(payloads[prefix+'/index.json'])
   image_path=prefix+'/blobs/sha256/'+index['manifests'][0]['digest'][7:];image=v.parse(payloads.pop(image_path))
   old_layer_path=prefix+'/blobs/sha256/'+image['layers'][0]['digest'][7:];payloads.pop(old_layer_path)
   content=b'#!/bin/sh\nexec unknown\n';layer=tar({'sbin/vminitd':elf(),'sbin/vmexec':elf(),'etc/startup.sh':content})
   layer_path=prefix+'/blobs/sha256/'+v.digest(layer);payloads[layer_path]=layer;image['layers'][0].update(digest='sha256:'+v.digest(layer),size=len(layer))
   config_path=prefix+'/blobs/sha256/'+image['config']['digest'][7:];config=v.parse(payloads.pop(config_path));config['rootfs']['diff_ids']=['sha256:'+v.digest(gzip.decompress(layer))];config_data=v.canonical(config);payloads[prefix+'/blobs/sha256/'+v.digest(config_data)]=config_data;image['config'].update(digest='sha256:'+v.digest(config_data),size=len(config_data))
   image_data=v.canonical(image);new_image=prefix+'/blobs/sha256/'+v.digest(image_data);payloads[new_image]=image_data;index['manifests'][0].update(digest='sha256:'+v.digest(image_data),size=len(image_data));payloads[prefix+'/index.json']=v.canonical(index)
   manifest['payloads']=[dict(path=p,sha256=v.digest(d),sizeBytes=len(d)) for p,d in payloads.items()]
   if change!='missing':manifest['oci']['files'].append(dict(path='etc/startup.sh',sha256=v.digest(content),sizeBytes=len(content),type='source-copy' if change=='wrong-source' else 'generated',components=['compiled-project'],source=dict(project='compiled-project',path='main.c',sha256=v.digest(content))))
   with self.subTest(change=change),mock.patch.object(v,'authenticate'):
    with self.assertRaisesRegex(ValueError,'OCI|non-ELF'):v.verify(v.canonical(manifest),runtime,payloads,files.__getitem__,manifest['sourceCommit'])
 def test_duplicate_link_paths_and_wrong_schema_media_type_are_refused(self):
  for change in ('duplicate','schema','media'):
   manifest,runtime,payloads,files=fixture()
   if change=='duplicate':manifest['oci']['links'].append(copy.deepcopy(manifest['oci']['links'][0]))
   else:
    p=manifest['oci']['prefix']+'/index.json';index=v.parse(payloads[p]);index['schemaVersion' if change=='schema' else 'mediaType']=3 if change=='schema' else 'text/plain';payloads[p]=v.canonical(index)
    record=next(r for r in manifest['payloads'] if r['path']==p);record.update(sha256=v.digest(payloads[p]),sizeBytes=len(payloads[p]))
   with self.subTest(change=change),mock.patch.object(v,'authenticate'):
    with self.assertRaisesRegex(ValueError,'duplicate OCI|schema/media'):v.verify(v.canonical(manifest),runtime,payloads,files.__getitem__,manifest['sourceCommit'])
if __name__=='__main__':unittest.main()
