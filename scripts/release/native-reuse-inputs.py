#!/usr/bin/env python3
"""Git-object proofs for the fixed native producer input boundary."""

import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re
import subprocess

HERE = Path(__file__).resolve().parent
WORKFLOW = '.github/workflows/runtime-ingredients.yml'
VERIFIER = 'scripts/release/verify-runtime-provenance.py'
CONSUMERS = ('scripts/release/prepare-runtime-provenance.py', 'scripts/release/runtime-provenance.schema.json')
TEST_CONSUMERS = ('scripts/release/test-runtime-ingredient-gates.py',)
ADDITIONS = (
    'scripts/release/resolve-native-checkpoint.py', 'scripts/release/native-reuse-inputs.py',
    'scripts/release/verify-native-reuse.py', 'scripts/release/test-native-runtime-reuse.py',
)
PREFIXES = ('scripts/release/', 'ThirdPartyLicenses/', 'Guest/', 'contracts/')
FILES = ('Package.swift', 'Package.resolved', 'runtime-license-inventory.json',
         'THIRD_PARTY_NOTICES', 'third-party-license-inventory.json')
HOOK = '''    if "nativeReuse" in manifest:
        import importlib.util
        spec = importlib.util.spec_from_file_location("native_reuse", pathlib.Path(__file__).with_name("verify-native-reuse.py"))
        reuse = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(reuse)
        reuse.verify_composition(manifest, fetch, source_commit, require_authentication)
'''
NATIVE_CHECKPOINT_JOB_SHA256 = 'b4fa6898cccb47be502aa59aff52da06059fe386cb67dc540b79a3ce3c0ac078'
FINAL_COMPOSITION_JOB_SHA256 = '0a77bba93362dd4966043ec6140a355bfa5ec1047f8e9f226d542c102119229d'
EMPTY_NATIVE = " && inputs.native_checkpoint_run == '' && inputs.native_checkpoint_attempt == ''"
OLD_MODE = "manifest['closureMode']=='new-source-build'"
NEW_MODE = "manifest['closureMode']==('authenticated-native-reuse' if 'nativeReuse' in manifest else 'new-source-build')"


def require(condition, message):
    if not condition: raise ValueError(message)


def canonical(value): return (json.dumps(value, sort_keys=True, separators=(',', ':'))+'\n').encode()
def digest(data): return hashlib.sha256(data).hexdigest()
def oid(kind, data): return hashlib.sha1(kind.encode()+b' '+str(len(data)).encode()+b'\0'+data).hexdigest()


def git(repo, *args):
    return subprocess.check_output(['git','-C',str(repo),*args], stderr=subprocess.PIPE, timeout=60)


def selected(name): return name in FILES or name == WORKFLOW or name.startswith(PREFIXES)


def record(root, name, data):
    target = root/name; target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists(): require(target.read_bytes() == data, 'conflicting Git proof object')
    else: target.write_bytes(data)
    return dict(path=name, sha256=digest(data), sizeBytes=len(data))


def capture(repo, commit, output, prefix):
    require(re.fullmatch('[a-f0-9]{40}',commit), 'invalid Git comparison commit')
    commit_data = git(repo,'cat-file','commit',commit)
    require(oid('commit',commit_data) == commit, 'Git comparison commit mismatch')
    root_tree = commit_data.splitlines()[0].removeprefix(b'tree ').decode()
    trees = {root_tree}
    leaves = {}
    for row in git(repo,'ls-tree','-r','-t','-z',commit).split(b'\0'):
        if not row: continue
        metadata,name = row.split(b'\t',1); mode,kind,identity = metadata.decode().split()
        name = name.decode('utf-8','strict')
        if kind == 'tree': trees.add(identity)
        elif selected(name):
            require(kind == 'blob' and mode in ('100644','100755'), 'unsupported native input mode: '+name)
            raw = git(repo,'cat-file','blob',identity)
            leaves[name] = dict(mode=mode, oid=identity, content=record(output,prefix+'/blobs/'+identity,raw))
    return dict(commit=commit, commitObject=record(output,prefix+'/commit',commit_data),
                trees={identity:record(output,prefix+'/trees/'+identity,git(repo,'cat-file','tree',identity)) for identity in sorted(trees)},
                files=leaves)


def bound(item, fetch):
    require(set(item) == {'path','sha256','sizeBytes'}, 'invalid native input proof record')
    name=item['path'];path=PurePosixPath(name)
    require(name and not path.is_absolute() and path.as_posix()==name and '\\' not in name and '..' not in path.parts,
            'unsafe native input proof path')
    data = fetch(item['path'])
    require(len(data) == item['sizeBytes'] and digest(data) == item['sha256'], 'native input proof bytes changed')
    return data


def snapshot(value, fetch):
    commit = bound(value['commitObject'],fetch)
    require(oid('commit',commit) == value['commit'], 'native comparison commit object mismatch')
    root = commit.splitlines()[0]
    require(re.fullmatch(rb'tree [a-f0-9]{40}',root), 'native comparison root tree missing')
    trees = {identity:bound(item,fetch) for identity,item in value['trees'].items()}
    require(all(oid('tree',raw) == identity for identity,raw in trees.items()), 'native comparison tree object mismatch')
    leaves = {}; visited = set()
    def visit(identity, prefix, ancestors):
        require(identity in trees and identity not in ancestors and len(ancestors) < 128, 'missing or recursive native comparison tree')
        visited.add(identity); raw = trees[identity]; cursor = 0; names = set()
        while cursor < len(raw):
            end = raw.find(b'\0',cursor); require(end > cursor and end+21 <= len(raw), 'malformed native comparison tree')
            mode,name = raw[cursor:end].split(b' ',1); cursor=end+1
            child = raw[cursor:cursor+20].hex(); cursor+=20
            name = name.decode('utf-8','strict')
            require(name not in ('','.','..') and '/' not in name and '\\' not in name and name not in names, 'unsafe native comparison tree entry')
            names.add(name); path=prefix+name
            if mode == b'40000': visit(child,path+'/',ancestors|{identity})
            else:
                require(path not in leaves and len(leaves) < 100000, 'duplicate or oversized native comparison tree')
                leaves[path] = (mode.decode(),child)
    visit(root[5:].decode(),'',set())
    require(visited == set(trees), 'extraneous native comparison tree objects')
    expected = {name for name in leaves if selected(name)}
    require(set(value['files']) == expected, 'native build input closure is incomplete')
    files = {}
    for name,item in value['files'].items():
        require((item['mode'],item['oid']) == leaves[name] and item['mode'] in ('100644','100755'), 'native build input tree identity mismatch')
        raw = bound(item['content'],fetch)
        require(oid('blob',raw) == item['oid'], 'native build input Git blob mismatch')
        files[name] = raw
    return files


def jobs(data):
    text = data.decode('utf-8','strict'); lines=text.splitlines(keepends=True)
    require(lines.count('jobs:\n')==1,'workflow must contain exactly one jobs mapping')
    starts = [(i,re.fullmatch(r'  ([A-Za-z0-9_-]+):\n',line).group(1)) for i,line in enumerate(lines) if re.fullmatch(r'  ([A-Za-z0-9_-]+):\n',line)]
    at = lines.index('jobs:\n')
    require(not any(line.strip() and not line.startswith((' ','#')) for line in lines[at+1:]),
            'top-level workflow settings after jobs are unsupported')
    starts = [(i,name) for i,name in starts if i > at]
    require(len({name for _,name in starts}) == len(starts), 'duplicate workflow job')
    return {name:''.join(lines[start:starts[n+1][0] if n+1<len(starts) else len(lines)]) for n,(start,name) in enumerate(starts)}


def compare_files(old, new):
    require(set(old)-set(new) == set(), 'original native input was removed')
    require(set(new)-set(old) <= set(ADDITIONS), 'unreviewed native producer input was added')
    require(all(name in old and name in new for name in FILES[:3]), 'native package/asset input is missing')
    changes = []
    for name,raw in old.items():
        if name == WORKFLOW: continue
        current = new[name]
        if name in (*CONSUMERS, *TEST_CONSUMERS):
            role = 'reviewed-workflow-routing-test' if name in TEST_CONSUMERS else 'reviewed-final-composition-consumer'
            changes.append(dict(path=name, role=role, before=digest(raw), after=digest(current)))
        elif name == VERIFIER:
            if current != raw:
                require(current.count(HOOK.encode()) == 1 and current.count(NEW_MODE.encode()) == 1,
                        'runtime verifier reuse hook or mode guard is missing/ambiguous')
                normalized=current.replace(HOOK.encode(),b'',1).replace(NEW_MODE.encode(),OLD_MODE.encode(),1)
                require(normalized == raw,'runtime verifier differs beyond the exact reuse hook and mode guard')
            changes.append(dict(path=name,role='exact-final-reuse-hook-and-mode-guard',before=digest(raw),after=digest(current)))
        else: require(current == raw, 'native producer input changed: '+name)
    old_jobs,new_jobs = jobs(old[WORKFLOW]),jobs(new[WORKFLOW])
    require(set(new_jobs)==set(old_jobs)|{'native-checkpoint'},'unreviewed native workflow job addition/removal')
    require(digest(new_jobs['native-checkpoint'].encode())==NATIVE_CHECKPOINT_JOB_SHA256,'native checkpoint consumer job differs from reviewed recipe')
    for name,block in old_jobs.items():
        if name not in ('source-built-swift-sdk','swift-sdk-evidence','runtime-build-ingredients','runtime-provenance'):
            require(new_jobs[name]==block,'unreviewed workflow job change: '+name)
    require(new_jobs['runtime-provenance']==old_jobs['runtime-provenance'] or
            digest(new_jobs['runtime-provenance'].encode())==FINAL_COMPOSITION_JOB_SHA256,
            'final native composition job differs from reviewed recipe')
    for name in ('source-built-swift-sdk','swift-sdk-evidence','runtime-build-ingredients'):
        require(name in old_jobs and name in new_jobs, 'original native/SDK workflow job missing')
        candidate = new_jobs[name]
        old_block = old_jobs[name]
        if candidate != old_block:
            require(candidate.count(EMPTY_NATIVE) == 1, 'unreviewed native workflow admission change')
            candidate = candidate.replace(EMPTY_NATIVE,'',1)
        require(candidate == old_block, 'native/SDK producer workflow changed: '+name)
    spec=importlib.util.spec_from_file_location('native_sdk_inputs',HERE/'verify-sdk-reuse.py')
    sdk=importlib.util.module_from_spec(spec);spec.loader.exec_module(sdk)
    require(sdk._workflow_globals(old[WORKFLOW].decode()) == sdk._workflow_globals(new[WORKFLOW].decode()), 'workflow global environment/defaults/permissions changed')
    def recipe(files):
        data={sdk.MATERIALIZER:files[sdk.MATERIALIZER],sdk.PINS:files[sdk.PINS],
              'builder-compile-prefix':sdk._builder_compile_prefix(files[sdk.BUILDER])}
        data.update({name:raw for name,raw in files.items() if name.startswith('scripts/release/patches/swift-sdk/')})
        hashes={name:digest(raw) for name,raw in sorted(data.items())}
        hashes['workflow-compile-config']=digest(json.dumps(sdk._workflow_compile_config(files[WORKFLOW]),sort_keys=True,separators=(',',':')).encode())
        return dict(sha256=digest(json.dumps(hashes,sort_keys=True,separators=(',',':')).encode()),files=hashes)
    old_recipe,new_recipe=recipe(old),recipe(new)
    require(old_recipe == new_recipe, 'original SDK compilation recipe changed')
    return dict(unchanged={name:digest(raw) for name,raw in old.items() if name not in (*CONSUMERS,*TEST_CONSUMERS,VERIFIER,WORKFLOW)},
                reviewedConsumerChanges=changes, workflow=dict(before=digest(old[WORKFLOW]),after=digest(new[WORKFLOW])),
                sdkCompileInputs=new_recipe,
                addedConsumers={name:digest(new[name]) for name in sorted(set(new)-set(old))})


def verify(comparison, fetch, producer, source):
    require(comparison['producer']['commit'] == producer and comparison['consumer']['commit'] == source, 'native comparison source claim mismatch')
    old=snapshot(comparison['producer'],fetch);new=snapshot(comparison['consumer'],fetch)
    require(all(name in comparison['consumer']['files'] and row['mode']==comparison['consumer']['files'][name]['mode']
                for name,row in comparison['producer']['files'].items()),'native producer input mode changed')
    chain={identity:bound(item,fetch) for identity,item in comparison['ancestry'].items()}
    require(all(oid('commit',raw)==identity for identity,raw in chain.items()),'native ancestry object mismatch')
    pending=[source];seen=set()
    while pending:
        identity=pending.pop()
        if identity==producer:break
        if identity in seen:continue
        seen.add(identity);require(len(seen)<=10000,'native ancestry exceeds bound')
        require(identity in chain,'native producer ancestry proof is incomplete')
        parents=[line[7:].decode() for line in chain[identity].splitlines() if re.fullmatch(rb'parent [a-f0-9]{40}',line)]
        pending.extend(parent for parent in parents if parent==producer or parent in chain)
    else: raise ValueError('native producer is not an ancestor of the accepted source')
    result=compare_files(old,new)
    require(result==comparison['comparison'],'native unchanged-input comparison changed')
    return result


def prepare(repo, producer, source, output):
    require(git(repo,'rev-parse','HEAD').decode().strip()==source and not git(repo,'status','--porcelain=v1','--untracked-files=all'), 'native reuse requires exact clean current source')
    subprocess.run(['git','-C',str(repo),'merge-base','--is-ancestor',producer,source],check=True,timeout=30)
    old=capture(repo,producer,output,'git/producer');new=capture(repo,source,output,'git/consumer')
    ancestors=git(repo,'rev-list','--ancestry-path',producer+'..'+source).decode().splitlines()
    require(len(ancestors)<=10000,'native ancestry exceeds bound')
    chain={identity:record(output,'git/ancestry/'+identity,git(repo,'cat-file','commit',identity)) for identity in ancestors}
    fetch=lambda name:(output/name).read_bytes()
    proof=dict(producer=old,consumer=new,ancestry=chain,comparison=compare_files(snapshot(old,fetch),snapshot(new,fetch)))
    verify(proof,fetch,producer,source)
    return proof
