#!/usr/bin/env python3
"""Light source inventory check; qualified runtime evidence is a separate release gate."""
import argparse
import hashlib
import json
import pathlib


def sha(data): return hashlib.sha256(data).hexdigest()

def load(path):
    if path.is_symlink() or not path.is_file(): raise ValueError('unsafe inventory input')
    data=path.read_bytes(); result=json.loads(data)
    if (json.dumps(result,sort_keys=True,separators=(',',':'),ensure_ascii=False)+'\n').encode()!=data:
        raise ValueError('inventory is not compact sorted canonical JSON')
    return result

def verify(root, require_qualified=False):
    notices=(root/'THIRD_PARTY_NOTICES').read_bytes()
    inventory=load(root/'third-party-license-inventory.json')
    runtime=load(root/'runtime-license-inventory.json')
    if inventory['kind']!='hostwright.third-party-license-inventory.v1' or runtime['kind']!='hostwright.runtime-license-inventory.v1' or inventory['schemaVersion']!=1 or runtime['schemaVersion']!=1:
        raise ValueError('unsupported inventory schema')
    resolved=(root/'Package.resolved').read_bytes()
    if inventory['resolvedSHA256']!=sha(resolved) or inventory['noticesSHA256']!=sha(notices) or runtime['noticesSHA256']!=sha(notices):
        raise ValueError('notice/resolved digest mismatch')
    pins=json.loads(resolved)['pins']
    actual=sorted((p['identity'],p['location'],p['state']['revision'],p['state'].get('version','')) for p in pins)
    expected=sorted((p['identity'],p['location'],p['revision'],p['version']) for p in inventory['dependencies'])
    if actual!=expected or inventory['dependencyCount']!=len(actual) or len(set(p[0] for p in expected))!=len(expected):
        raise ValueError('incomplete/mismatched dependency pin inventory')
    for dependency in runtime['guestDependencies']:
        prefix='guest-swift/'+dependency['identity']+'@'+dependency['revision']+'/'
        if not any(d['category']=='runtime-guest-license' and d['sourcePath'].startswith(prefix) for d in inventory['runtimeDocuments']):
            raise ValueError('missing exact pinned guest dependency license')
    for dependency in inventory['dependencies']:
        if not any(d['category']=='root-license' for d in dependency['documents']):
            raise ValueError('missing root dependency license')
    for document in [d for p in inventory['dependencies'] for d in p['documents']]+inventory['runtimeDocuments']:
        offset,size=document['offsetBytes'],document['sizeBytes']
        if offset<0 or size<=0 or offset+size>len(notices) or sha(notices[offset:offset+size])!=document['sha256']:
            raise ValueError('license text missing/changed')
    for name,key in [('go.mod','goModuleSHA256'),('go.sum','goSumSHA256')]:
        if sha((root/'Guest/HostwrightNetfilter'/name).read_bytes())!=runtime[key]:
            raise ValueError('guest Go module/checksum source drift')
    for path,digest in runtime['retainedLoaderSourceFiles'].items():
        if not path.startswith('Guest/HostwrightNetfilter/') or '..' in path or sha((root/path).read_bytes())!=digest:
            raise ValueError('retained loader source/binary binding drift')
    if len(runtime['retainedLoaderSourceFiles'])!=20 or len(runtime['retainedLoaderLinkedModules'])!=6 or any(m not in runtime['goDependencies'] for m in runtime['retainedLoaderLinkedModules']):
        raise ValueError('retained loader inventory incomplete')
    if require_qualified and (runtime['status']!='qualified' or any(a['status']!='qualified' or a['blockers'] or not a['sourceDistributionEvidence'] for a in runtime['assets'])):
        raise ValueError('runtime source/license provenance qualification remains blocked')
    return dict(dependencies=len(actual),documents=sum(len(p['documents']) for p in inventory['dependencies']),runtimeDocuments=len(inventory['runtimeDocuments']),runtimeStatus=runtime['status'])

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--root',type=pathlib.Path,required=True);p.add_argument('--require-qualified',action='store_true');a=p.parse_args()
    print(json.dumps(verify(a.root,a.require_qualified),sort_keys=True))
