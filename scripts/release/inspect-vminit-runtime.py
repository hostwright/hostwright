#!/usr/bin/env python3
"""Inspect pinned retained OCI/SDK bytes without executing their binaries."""
import argparse,pathlib,tarfile,json,hashlib,re,tempfile,subprocess
p=argparse.ArgumentParser();p.add_argument("--sdk-archive",type=pathlib.Path,required=True);p.add_argument("--oci-layout",type=pathlib.Path,required=True);p.add_argument("--output-parent",type=pathlib.Path,required=True);p.add_argument("--llvm-readelf",default="/opt/homebrew/opt/llvm/bin/llvm-readelf");args=p.parse_args()
archive=args.sdk_archive
if archive.is_symlink() or not archive.is_file():raise ValueError('unsafe SDK archive')
with archive.open('rb') as stream:archive_sha=hashlib.file_digest(stream,'sha256').hexdigest()
if archive_sha!='d2078b69bdeb5c31202c10e9d8a11d6f66f82938b51a4b75f032ccb35c4c286c':raise ValueError('SDK digest differs from pinned Apple recipe')
source=pathlib.Path(__file__).resolve().parents[2];output=args.output_parent.resolve()
if output==source or source in output.parents:raise ValueError('inspection output must be outside source checkout')
base=pathlib.Path(tempfile.mkdtemp(prefix='hostwright-vminit-sdk-inspection-',dir=output));runtime=[];metadata=[];headers=[];standalone_licenses=[]
with tarfile.open(archive,'r:gz') as t:
 for m in t:
  if m.isfile() and re.fullmatch(r'(LICENSE|COPYING|COPYRIGHT|NOTICES?|PATENTS)([._-][A-Za-z0-9.-]+)?',m.name.rsplit('/',1)[-1],re.I):standalone_licenses.append(m.name)
  if not m.isfile() or '/musl-1.2.5.sdk/aarch64/' not in m.name:continue
  if m.name.startswith('/') or any(part in {'','..','.'} for part in m.name.split('/')):raise ValueError('unsafe SDK path')
  if m.name.endswith('.a'):
   data=t.extractfile(m).read();entry=dict(path=m.name,sha256=hashlib.sha256(data).hexdigest(),sizeBytes=len(data),classification='candidate-target-runtime-archive-not-proven-linked-in-vminit');runtime.append(entry)
   target=base/'aarch64-runtime-archives'/m.name.rsplit('/aarch64/',1)[1];target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
  elif '/pkgconfig/' in m.name or m.name.endswith(('libxml2-config-version.cmake','liblzma-config-version.cmake','mimalloc-config-version.cmake','uversion.h','uvernum.h','opensslv.h','mimalloc.h','bzlib.h')):
   data=t.extractfile(m).read();text=data.decode(errors='replace');version=re.findall(r'^Version:\s*(.+)|set\(PACKAGE_VERSION\s+"?([^"\)]+)|#define U_ICU_VERSION\s+"([^"]+)"',text,re.M);metadata.append(dict(path=m.name,sha256=hashlib.sha256(data).hexdigest(),versions=[next(v for v in row if v) for row in version if re.fullmatch(r'[0-9][0-9.A-Za-z_-]*',next(v for v in row if v))]));target=base/'target-metadata'/m.name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
  elif '/include/' in m.name and m.size<1024*1024:
   data=t.extractfile(m).read();match=re.match(rb'\A(?:\s*(?://[^\n]*\n|/\*.*?\*/))+',data,re.S)
   if match and re.search(rb'copyright|permission|licensed|redistribution|SPDX-License',match[0],re.I):headers.append(dict(path=m.name,sha256=hashlib.sha256(match[0]).hexdigest(),text=match[0].decode(errors='replace')))
(base/'target-runtime-inventory.json').write_text(json.dumps(dict(kind='hostwright.swift-sdk-runtime-inspection.v1',sdkArchiveSHA256='d2078b69bdeb5c31202c10e9d8a11d6f66f82938b51a4b75f032ccb35c4c286c',runtimeArchives=runtime,metadata=metadata,standaloneLicenseFiles=standalone_licenses,scope='Candidate SDK runtime inputs; actual published OCI link/source provenance not established.'),indent=2)+'\n');(base/'target-header-attribution.json').write_text(json.dumps(headers,sort_keys=True,separators=(',',':'))+'\n');print(json.dumps(dict(runtimeArchives=len(runtime),metadata=metadata,headerNotices=len(headers)),indent=2))

layer=args.oci_layout/'blobs/sha256/e3b2b9d347c2e5834d9fe5b4d615f5c0632c485d785e64f5c6b4c9b179ac168f'
if layer.is_symlink() or not layer.is_file():raise ValueError('unsafe OCI layer')
with layer.open('rb') as stream:layer_sha=hashlib.file_digest(stream,'sha256').hexdigest()
if layer_sha!=layer.name:raise ValueError('OCI layer digest mismatch')
expected={'sbin/vminitd':'b959125d64bdfb698184687d3c0bb3088bcc4a3b1cf2db418e292b7889550a17','sbin/vmexec':'e30b5e74c1af4bdfce229d4769e6b8b4308921419df611a492df74a9724109b0'}
elves=[]
with tarfile.open(layer,'r:gz') as archive:
 members=archive.getmembers()
 for path,digest in expected.items():
  matches=[m for m in members if m.name==path]
  if len(matches)!=1 or not matches[0].isfile():raise ValueError('missing/duplicate/nonregular OCI ELF')
  data=archive.extractfile(matches[0]).read()
  if hashlib.sha256(data).hexdigest()!=digest:raise ValueError('OCI ELF digest differs from retained image')
  target=base/'oci-elf'/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
  command=[args.llvm_readelf,'--file-header','--program-headers','--notes','--string-dump=.comment',str(target)]
  result=subprocess.run(command,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE);text=result.stdout.decode();(base/(path.rsplit('/',1)[-1]+'-elf.txt')).write_bytes(result.stdout)
  elves.append(dict(path=path,sha256=digest,sizeBytes=len(data),commentStrings=sorted(set(re.findall(r'(?:Apple )?clang version[^\n]+|Linker: LLD[^\n]+',text))),buildID=re.findall(r'Build ID: ([a-f0-9]+)',text),hasInterpreter='INTERP' in text,hasDynamicSegment='DYNAMIC' in text))
(base/'actual-oci-elf-inventory.json').write_text(json.dumps(dict(kind='hostwright.vminit-actual-elf-inspection.v1',layerSHA256=layer_sha,elves=elves,status='inspected-not-link-provenance-qualified',limitations=['Stripped ELFs do not establish complete linked component/source inventory.','Matching LLVM comment is consistency evidence; it does not authenticate the SDK/source used by the OCI builder.']),indent=2)+'\n')
print(json.dumps(dict(directory=str(base),sdkSHA256=archive_sha,actualELFs=elves),sort_keys=True))
