#!/usr/bin/env python3
"""Collect exact pinned root/nested texts and embedded C attribution into reviewed source."""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--root', type=pathlib.Path, required=True)
p.add_argument('--checkouts', type=pathlib.Path, required=True)
p.add_argument('--verify', action='store_true')
p.add_argument('--go-modules', type=pathlib.Path, required=True)
p.add_argument('--go-toolchain', type=pathlib.Path, required=True)
a = p.parse_args()
root = a.root.resolve()
resolved = (root / 'Package.resolved').read_bytes()
pins = json.loads(resolved)['pins']
notices = bytearray(b'Hostwright third-party licenses and notices\n==========================================\n\nThese texts preserve attribution for the exact resolved host dependency graph.\nRoot project licenses do not replace licenses of embedded components. Runtime\ncorresponding-source and static-runtime gaps remain in runtime-license-inventory.json.\nThis inventory makes no blanket legal compliance claim.\n\n')

def add(data, path, category, paths=None):
    notices.extend(('\n--- ' + path + ' ---\n').encode())
    offset = len(notices)
    notices.extend(data)
    notices.extend(b'\n')
    return dict(sourcePath=path, category=category, offsetBytes=offset, sizeBytes=len(data),
                sha256=hashlib.sha256(data).hexdigest(), sourcePaths=paths or [path])

dependencies = []
for pin in sorted(pins, key=lambda item: item['identity']):
    checkout = next(path for path in a.checkouts.iterdir() if path.name.lower() == pin['identity'])
    observed = subprocess.check_output(['git','-C',str(checkout),'rev-parse','HEAD'],text=True).strip()
    if observed != pin['state']['revision']:
        raise ValueError('checkout revision differs from resolved pin: '+pin['identity'])
    documents = []
    for path in sorted(checkout.rglob('*')):
        if path.is_file() and '.git' not in path.parts and re.fullmatch(r'(LICENSE|COPYING|COPYRIGHT|NOTICES?)([._-][A-Za-z0-9.-]+)?',path.name,re.I) and path.suffix.lower() not in {'.h','.sh','.swift','.json'}:
            if path.is_symlink() and checkout.resolve() not in path.resolve().parents:
                raise ValueError('license alias escapes pinned checkout')
            if not path.read_bytes(): continue
            relative = str(path.relative_to(checkout))
            category = 'root-notice' if path.parent == checkout and path.name.upper().startswith('NOTICE') else 'root-license' if path.parent == checkout else 'nested-license'
            documents.append(add(path.read_bytes(),pin['identity']+'/'+relative,category))
    headers = {}
    for path in sorted((checkout/'Sources').rglob('*')):
        if path.is_file() and re.search(r'\.(c|h|cc|cpp|s|inc)$',path.name,re.I):
            data = path.read_bytes()
            match = re.match(rb'\A(?:\s*(?://[^\n]*\n|/\*.*?\*/|\#[^\n]*\n|;[^\n]*\n))+',data,re.S)
            if match and re.search(rb'copyright|permission|licensed|redistribution|SPDX-License',match[0],re.I):
                text = match[0].strip()
                headers.setdefault(text,[]).append(pin['identity']+'/'+str(path.relative_to(checkout)))
    for data, paths in sorted(headers.items(),key=lambda item:item[1][0]):
        documents.append(add(data,paths[0]+' (embedded attribution)','source-license-header',paths))
    if pin['identity'] in {'swift-crypto','swift-nio-ssl'}:
        upstream = root/'ThirdPartyLicenses/upstream'/('boringssl-'+pin['identity']+'-LICENSE')
        boring_dir = 'CCryptoBoringSSL' if pin['identity']=='swift-crypto' else 'CNIOBoringSSL'
        boring_revision = (checkout/'Sources'/boring_dir/'hash.txt').read_text().strip().split()[-1]
        documents.append(add(upstream.read_bytes(),'upstream/boringssl-'+pin['identity']+'@'+boring_revision+'/LICENSE',
                             'upstream-bundled-license',['https://raw.githubusercontent.com/google/boringssl/'+boring_revision+'/LICENSE',
                             pin['location'].removesuffix('.git')+'/blob/'+observed+'/Sources/'+boring_dir+'/hash.txt']))
    if not any(doc['category']=='root-license' for doc in documents):
        raise ValueError('missing root license: '+pin['identity'])
    expression = 'MIT' if pin['identity'] in {'wasmkit','yams'} else '(BSD-3-Clause OR GPL-2.0-only)' if pin['identity']=='zstd' else 'Apache-2.0'
    dependencies.append(dict(identity=pin['identity'],location=pin['location'],revision=observed,
                             version=pin['state'].get('version',''),rootLicenseExpression=expression,documents=documents))
runtime_documents = [add((root/'ThirdPartyLicenses/upstream/linux-GPL-2.0').read_bytes(),
                         'runtime/linux-6.18.15/LICENSES/preferred/GPL-2.0','runtime-license')]
for base in sorted((root/'ThirdPartyLicenses/guest').iterdir()):
    metadata = json.loads((base/'source-documents.json').read_text())
    pin = metadata['pin']
    for document in metadata['documents']:
        data = (base/document['path']).read_bytes()
        if hashlib.sha256(data).hexdigest() != document['sha256'] or len(data) != document['sizeBytes']:
            raise ValueError('retained guest license source digest mismatch')
        if not data: continue
        runtime_documents.append(add(data,'guest-swift/'+pin['identity']+'@'+pin['state']['revision']+'/'+document['path'],
                                     'runtime-guest-license', [document['url']]))
for document in json.loads((root/'ThirdPartyLicenses/runtime-build-recipes/source-documents.json').read_text()):
    data = (root/'ThirdPartyLicenses/runtime-build-recipes'/document['path']).read_bytes()
    if hashlib.sha256(data).hexdigest() != document['sha256']: raise ValueError('runtime recipe source drift')
    runtime_documents.append(add(data,'runtime-build-recipe/'+document['path'],'runtime-build-recipe',[document['url']]))
go_mod = (root/'Guest/HostwrightNetfilter/go.mod').read_text()
go_sum = (root/'Guest/HostwrightNetfilter/go.sum').read_text()
for module, version in re.findall(r'^\s*([a-zA-Z0-9./_-]+)\s+(v[^\s]+)',go_mod,re.M):
    checkout = a.go_modules/(module+'@'+version)
    checksum_path = a.go_modules/'cache/download'/module/'@v'/(version+'.ziphash')
    checksum = checksum_path.read_text().strip()
    if module+' '+version+' '+checksum not in go_sum.splitlines():
        raise ValueError('Go cached module does not match exact go.sum: '+module)
    found = False
    for path in sorted(checkout.rglob('*')):
        if path.is_file() and re.fullmatch(r'(LICENSE|COPYING|COPYRIGHT|NOTICES?|PATENTS)([._-][A-Za-z0-9.-]+)?',path.name,re.I):
            runtime_documents.append(add(path.read_bytes(),'guest-go/'+module+'@'+version+'/'+str(path.relative_to(checkout)),'runtime-go-license'))
            found = True
    if not found: raise ValueError('Go dependency root license is missing: '+module)
for path in [a.go_toolchain/'LICENSE',a.go_toolchain/'PATENTS'] + sorted((a.go_toolchain/'src/vendor').rglob('LICENSE')) + sorted((a.go_toolchain/'src/vendor').rglob('PATENTS')):
    if path.is_file():
        runtime_documents.append(add(path.read_bytes(),'go-1.26.5/'+str(path.relative_to(a.go_toolchain)),'runtime-go-toolchain-license'))
inventory = dict(kind='hostwright.third-party-license-inventory.v1',schemaVersion=1,
                 resolvedSHA256=hashlib.sha256(resolved).hexdigest(),dependencyCount=len(pins),
                 noticesSHA256=hashlib.sha256(notices).hexdigest(),dependencies=dependencies,runtimeDocuments=runtime_documents)
# Compact sorted UTF-8 JSON is checked byte-for-byte by the distribution boundary.
encoded = json.dumps(inventory,sort_keys=True,ensure_ascii=False,separators=(',', ':'))+'\n'
if a.verify:
    if (root/'THIRD_PARTY_NOTICES').read_bytes() != notices or json.loads((root/'third-party-license-inventory.json').read_text()) != inventory:
        raise ValueError('reviewed notices/inventory drift from exact pinned sources')
else:
    (root/'THIRD_PARTY_NOTICES').write_bytes(notices)
    (root/'third-party-license-inventory.json').write_text(encoded)
print(json.dumps(dict(dependencies=len(dependencies),documents=sum(len(item['documents']) for item in dependencies),noticeBytes=len(notices),noticesSHA256=inventory['noticesSHA256']),sort_keys=True))
