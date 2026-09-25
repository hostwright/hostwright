#!/usr/bin/env python3
"""Verify new source-built runtime ingredients; receipt flags are never authority."""
import hashlib, io, json, os, pathlib, re, struct, subprocess, tarfile, tempfile

REPO = 'hostwright/hostwright'
WORKFLOW = '.github/workflows/runtime-ingredients.yml'
KIND = 'hostwright.runtime-provenance.v1'
MAX_METADATA = 16 * 1024**2
MAX_SOURCE_INVENTORY = 64 * 1024**2
MAX_FILE = 2 * 1024**3
MAX_FILES = 250000

def require(condition, message):
    if not condition: raise ValueError(message)

def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'))+'\n').encode()

def parse(data, *, limit=MAX_METADATA):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate provenance JSON key')
            result[key] = value
        return result
    require(len(data) <= limit, 'oversized provenance metadata')
    return json.loads(data, object_pairs_hook=pairs)

def path(name):
    require(isinstance(name,str) and name and not name.startswith('/') and '\\' not in name
            and not re.search(r'[\x00-\x1f\x7f]',name) and all(p not in ('', '.', '..') for p in name.split('/')), 'unsafe provenance path')
    return name

def digest(data): return hashlib.sha256(data).hexdigest()

def bound(record, fetch):
    name = path(record['path'])
    require(re.fullmatch('[a-f0-9]{64}', record['sha256']) is not None, 'invalid evidence digest')
    data = fetch(name)
    require(len(data) <= MAX_FILE and len(data) == record['sizeBytes'] and digest(data) == record['sha256'],
            'evidence bytes mismatch: '+name)
    return data

def substantive(record, fetch):
    data=bound(record,fetch)
    require(data.strip(), 'empty substantive build/license evidence: '+record['path'])
    return data

def validate_schema(value):
    schema=json.loads(pathlib.Path(__file__).with_name('runtime-provenance.schema.json').read_bytes())
    def check(item, rule):
        if '$ref' in rule:rule=schema['$defs'][rule['$ref'].split('/')[-1]]
        if 'oneOf' in rule:
            successes=0
            for option in rule['oneOf']:
                try:check(item,option);successes+=1
                except ValueError:pass
            require(successes==1, 'runtime provenance schema choice mismatch');return
        if 'const' in rule:require(type(item) is type(rule['const']) and item==rule['const'], 'runtime provenance schema constant mismatch')
        kind=rule.get('type')
        require(kind is None or {'object':isinstance(item,dict),'array':isinstance(item,list),
                'string':isinstance(item,str),'integer':type(item) is int}.get(kind,False),
                'runtime provenance schema type mismatch')
        if kind=='object':
            require(all(k in item for k in rule.get('required',[])), 'runtime provenance schema missing field')
            for key,child in rule.get('properties',{}).items():
                if key in item:check(item[key],child)
        elif kind=='array':
            require(len(item)>=rule.get('minItems',0) and len(item)<=rule.get('maxItems',MAX_FILES), 'runtime provenance schema array size')
            for child in item:check(child,rule.get('items',{}))
        elif kind=='string':
            require(len(item)>=rule.get('minLength',0) and ('pattern' not in rule or re.fullmatch(rule['pattern'],item)), 'runtime provenance schema string mismatch')
        elif kind=='integer':require(rule.get('minimum',item)<=item<=rule.get('maximum',item), 'runtime provenance schema integer range')
    check(value,schema)

def argv(record, fetch, tools):
    values=parse(substantive(record,fetch))
    require(isinstance(values,list) and values and all(isinstance(v,str) and v.strip() and '\0' not in v for v in values),
            'missing substantive compiler/linker argv')
    require(values[0] in tools, 'compiler/linker argv tool is not authenticated')
    require(len(values)>1, 'compiler/linker argv has no substantive arguments')
    return values

def toolchain(manifest, fetch):
    tools={}; identities=set()
    for tool in manifest['toolchain']:
        require(tool['identity'] not in identities and tool['executablePath'] not in tools,
                'duplicate authenticated toolchain tool')
        identities.add(tool['identity'])
        require(tool['executablePath'].startswith('/') and '..' not in tool['executablePath'].split('/'), 'unsafe authenticated executable path')
        data=substantive(tool['executable'],fetch)
        require(data.startswith(b'\x7fELF') or data[:4] in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe'), 'toolchain lacks actual executable bytes')
        substantive(tool['version'],fetch)
        environment=parse(substantive(tool['environment'],fetch))
        require(isinstance(environment,dict) and environment, 'missing authenticated toolchain environment')
        for library in tool['loadedLibraries']:substantive(library,fetch)
        tools[tool['executablePath']]=tool['executable']['sha256']
    require({'compiler','linker'}<=identities, 'missing authenticated compiler/linker toolchain')
    return tools

def spdx(expression):
    supported={'0BSD','Apache-2.0','BSD-2-Clause','BSD-3-Clause','MIT','ISC','bzip2-1.0.6','GPL-2.0-only','GPL-2.0-or-later',
               'GPL-3.0-only','GPL-3.0-or-later','LGPL-2.1-only','LGPL-2.1-or-later','LGPL-3.0-only',
               'Zlib','OpenSSL','Unicode-3.0','Unicode-DFS-2016','ICU','MPL-2.0','CC0-1.0','PSF-2.0',
               'LLVM-exception','Swift-exception'}
    tokens=re.findall(r'[A-Za-z0-9.-]+|[()]',expression)
    require(''.join(tokens)==re.sub(r'\s','',expression) and tokens, 'malformed SPDX expression')
    cursor=0
    def term():
        nonlocal cursor
        require(cursor<len(tokens), 'incomplete SPDX expression')
        if tokens[cursor]=='(':
            cursor+=1; sequence();require(cursor<len(tokens) and tokens[cursor]==')','unclosed SPDX expression');cursor+=1
        else:
            require(tokens[cursor] in supported-{'LLVM-exception','Swift-exception'}, 'unsupported SPDX identifier');cursor+=1
            if cursor<len(tokens) and tokens[cursor]=='WITH':
                cursor+=1;require(cursor<len(tokens) and tokens[cursor] in {'LLVM-exception','Swift-exception'}, 'unsupported SPDX exception');cursor+=1
    def sequence():
        nonlocal cursor
        term()
        while cursor<len(tokens) and tokens[cursor] in ('AND','OR'):cursor+=1;term()
    sequence();require(cursor==len(tokens), 'invalid SPDX expression');return expression

def producer_binding(producer, source_commit):
    require(re.fullmatch('[a-f0-9]{40}', producer['commit']) is not None and
            producer['commit'] == source_commit and type(producer['runID']) is int and producer['runID'] > 0
            and type(producer['attempt']) is int and producer['attempt'] > 0, 'invalid producer binding')

def authenticate(filename, producer, source_commit):
    """Use the same GitHub trust roots as release promotion, with exact run extensions."""
    producer_binding(producer,source_commit)
    identity = 'https://github.com/'+REPO+'/'+WORKFLOW+'@refs/heads/main'
    command = ['gh','attestation','verify',str(filename),'--repo',REPO,'--hostname','github.com',
               '--signer-digest',source_commit,
               '--source-digest',source_commit,'--source-ref','refs/heads/main',
               '--cert-identity',identity,'--cert-oidc-issuer','https://token.actions.githubusercontent.com',
               '--deny-self-hosted-runners','--format','json']
    # No executable/verifier callback or trusted-root override is accepted from a receipt.
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        result = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=120, check=False,
                                env={k:v for k,v in os.environ.items() if k in
                                     ('PATH','HOME','GH_TOKEN','GITHUB_TOKEN','GH_CONFIG_DIR')})
        require(result.returncode == 0, 'GitHub runtime attestation verification failed')
        stdout.seek(0); values = parse(stdout.read(MAX_METADATA+1))
    require(isinstance(values,list) and values, 'missing verified GitHub attestations')
    expected_run = 'https://github.com/'+REPO+'/actions/runs/'+str(producer['runID'])+'/attempts/'+str(producer['attempt'])
    matched=False
    for value in values:
        verification = value['verificationResult']; cert = verification['signature']['certificate']
        correct=(cert.get('issuer') == 'https://token.actions.githubusercontent.com' and
                cert.get('buildSignerURI') == identity and cert.get('buildSignerDigest') == source_commit and
                cert.get('sourceRepositoryURI') == 'https://github.com/'+REPO and
                cert.get('sourceRepositoryDigest') == source_commit and cert.get('sourceRepositoryRef') == 'refs/heads/main' and
                cert.get('runnerEnvironment') == 'github-hosted' and cert.get('runInvocationURI') == expected_run and
                verification.get('verifiedTimestamps'))
        if not correct:continue
        subjects = verification['statement']['subject']
        actual = digest(pathlib.Path(filename).read_bytes())
        if any(s.get('digest') == {'sha256':actual} for s in subjects):matched=True
    require(matched, 'wrong authenticated runtime producer/run or subject')

def git_object(kind, data):
    return hashlib.sha1(kind.encode()+b' '+str(len(data)).encode()+b'\0'+data).hexdigest()

def apply_patch_bytes(patch_data, contents):
    """Replay ordinary Git unified patches with exact context; no fuzz/commands/links."""
    lines=patch_data.splitlines(keepends=True); index=0; changed=False
    while index<len(lines):
        if not lines[index].startswith(b'--- '):
            require(not lines[index].startswith((b'GIT binary patch',b'new file mode',b'deleted file mode',b'old mode',b'new mode')),
                    'unsupported binary/file-mode source patch')
            index+=1; continue
        old=lines[index][4:].strip().decode(); index+=1
        require(index<len(lines) and lines[index].startswith(b'+++ '), 'missing source patch destination')
        new=lines[index][4:].strip().decode(); index+=1
        require(old.startswith('a/') and new.startswith('b/') and old[2:]==new[2:], 'unsupported source patch path')
        name=path(new[2:]); require(name in contents, 'source patch target missing')
        original=contents[name].splitlines(keepends=True); result=[]; cursor=0; hunks=0
        while index<len(lines) and lines[index].startswith(b'@@ '):
            match=re.match(rb'@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@',lines[index])
            require(match is not None, 'invalid source patch hunk'); index+=1
            start=int(match[1])-1; old_count=int(match[2] or b'1'); new_count=int(match[4] or b'1')
            require(cursor<=start<=len(original), 'source patch hunk overlap/range')
            result+=original[cursor:start]; cursor=start; consumed=produced=0
            while consumed<old_count or produced<new_count:
                require(index<len(lines), 'truncated source patch hunk'); line=lines[index]; index+=1
                require(line[:1] in (b' ',b'+',b'-'), 'unsupported source patch hunk line')
                if line[:1] in (b' ',b'-'):
                    require(cursor<len(original) and original[cursor]==line[1:], 'source patch context mismatch')
                    cursor+=1; consumed+=1
                if line[:1] in (b' ',b'+'):result.append(line[1:]); produced+=1
            require(consumed==old_count and produced==new_count, 'source patch hunk count mismatch'); hunks+=1
        require(hunks>0, 'source patch has no actual hunks')
        contents[name]=b''.join(result+original[cursor:]); changed=True
    require(changed, 'missing actual source patch changes')

def source_project(project, fetch, project_commits=None):
    """Reconstruct the complete Git tree from actual retained source leaves."""
    commit = bound(project['commitObject'], fetch)
    require(git_object('commit',commit) == project['commit'], 'source commit object mismatch')
    require(commit.splitlines()[0] == b'tree '+project['tree'].encode(), 'source commit tree mismatch')
    inventory = parse(bound(project['inventory'],fetch), limit=MAX_SOURCE_INVENTORY)
    require(isinstance(inventory,list) and 0 < len(inventory) <= MAX_FILES, 'missing complete source inventory')
    leaves = {}; tree = {}; contents={}
    with tarfile.open(fileobj=io.BytesIO(bound(project['archive'],fetch)),mode='r:*') as archive:
        members = archive.getmembers()
        require(len(members) <= MAX_FILES and all(m.isfile() or m.isdir() for m in members), 'unsafe canonical source archive')
        files = {path(m.name):m for m in members if m.isfile()}
        require(len(files) == sum(m.isfile() for m in members), 'duplicate source archive member')
        for record in inventory:
            name = path(record['path']); require(name not in leaves, 'duplicate source leaf')
            require(name in files and files[name].size <= MAX_FILE, 'missing source leaf')
            data = archive.extractfile(files[name]).read()
            require(record['gitMode'] in ('100644','100755','120000') and
                    len(data) == record['sizeBytes'] and digest(data) == record['sha256'] and
                    git_object('blob',data) == record['gitBlobSHA1'], 'source leaf mismatch')
            leaves[name] = record
            contents[name]=data
            node = tree
            for component in name.split('/')[:-1]:
                require(not isinstance(node.get(component),tuple), 'source tree collision')
                node = node.setdefault(component,{})
            require(name.split('/')[-1] not in node, 'source tree collision')
            node[name.split('/')[-1]] = (record['gitMode'],record['gitBlobSHA1'])
        require(set(files) == set(leaves), 'source archive/inventory coverage mismatch')
    submodules=project.get('submodules',[])
    require(len(leaves)+len(submodules)<=MAX_FILES, 'oversized source tree')
    link_paths=set()
    for link in submodules:
        name=path(link['path'])
        require(name not in link_paths and name not in leaves, 'duplicate source submodule path')
        link_paths.add(name)
        require(project_commits is not None and link['project'] in project_commits and
                link['project']!=project['identity'] and
                project_commits[link['project']]==link['commit'], 'submodule lacks exact captured source project')
        require(re.fullmatch('[a-f0-9]{40}',link['commit']) is not None, 'invalid submodule commit')
        node=tree
        for component in name.split('/')[:-1]:
            require(not isinstance(node.get(component),tuple), 'source tree collision')
            node=node.setdefault(component,{})
        require(name.split('/')[-1] not in node, 'source tree collision')
        node[name.split('/')[-1]]=('160000',link['commit'])
    def tree_hash(node):
        entries=[]
        for name,value in node.items():
            mode,oid = ('40000',tree_hash(value)) if isinstance(value,dict) else value
            entries.append((name.encode()+(b'/' if mode=='40000' else b''),
                            mode.encode()+b' '+name.encode()+b'\0'+bytes.fromhex(oid)))
        return git_object('tree',b''.join(v for _,v in sorted(entries)))
    require(tree_hash(tree) == project['tree'], 'incomplete or wrong source Git tree')
    require(project['licenses'] and project['notices'], 'missing source license/notice evidence')
    spdx(project['spdx'])
    for item in project['patches']:
        before=digest(canonical({p:digest(d) for p,d in contents.items()}))
        require(before==item['beforeInventorySHA256'], 'source patch before inventory mismatch')
        require(all(leaves[p]['gitMode']!='120000' for p in contents if ('a/'+p).encode() in bound(item,fetch)),
                'source patch targets retained link')
        apply_patch_bytes(bound(item,fetch),contents)
        require(digest(canonical({p:digest(d) for p,d in contents.items()}))==item['afterInventorySHA256'],
                'source patch after inventory mismatch')
    for name,data in contents.items():leaves[name]=dict(leaves[name],sha256=digest(data),sizeBytes=len(data))
    for item in project['licenses']+project['notices']:
        data=substantive(item,fetch); source_name=path(item['sourcePath'])
        require(source_name in leaves and leaves[source_name]['gitMode']!='120000' and
                leaves[source_name]['sha256']==digest(data) and item['component']==project['identity'] and
                item['spdx']==project['spdx'], 'license/notice is not bound to exact source leaf/component/SPDX')
    return leaves

def elf(data, relocatable=False):
    require(len(data)>=64 and data[:7]==b'\x7fELF\x02\x01\x01', 'expected ELF64 little-endian bytes')
    kind,machine = struct.unpack_from('<HH',data,16)
    require(machine==183 and kind in ((1,) if relocatable else (2,3)), 'wrong ELF architecture/type')
    offset=struct.unpack_from('<Q',data,32)[0]; size,count=struct.unpack_from('<HH',data,54)
    require(count<=65535 and (count==0 or size>=56) and offset+size*count<=len(data), 'invalid ELF program headers')
    require(relocatable or count>0, 'missing executable ELF program headers')
    loads=0
    for index in range(count):
        header=offset+index*size; segment=struct.unpack_from('<I',data,header)[0]
        require(segment not in (2,3), 'dynamic runtime ELF is not the static closure')
        if segment==1:
            file_offset=struct.unpack_from('<Q',data,header+8)[0]
            file_size,memory_size=struct.unpack_from('<QQ',data,header+32)
            require(file_offset+file_size<=len(data) and file_size<=memory_size, 'invalid ELF load segment')
            loads+=1
    require(relocatable or loads>0, 'missing executable ELF load segment')

def arm64_image(data):
    require(len(data)>=64 and data[56:60]==b'ARM\x64', 'expected raw arm64 Linux Image')
    text_offset,image_size,flags,res2,res3,res4=struct.unpack_from('<QQQQQQ',data,8)
    require(image_size>=len(data) and image_size<=MAX_FILE and (flags & ~0xe)==0 and
            res2==res3==res4==0 and text_offset<image_size,
            'invalid arm64 Linux Image header')

def archive_entries(data):
    require(data.startswith(b'!<arch>\n'), 'expected actual static archive')
    result=[]; names=b''; offset=8
    while offset<len(data):
        header=data[offset:offset+60]; require(len(header)==60 and header[58:]==b'`\n', 'invalid static archive header')
        size=int(header[48:58]); require(size>=0 and offset+60+size<=len(data), 'invalid static archive member size')
        raw=data[offset+60:offset+60+size]
        require(len(raw)==size, 'truncated static archive')
        name=header[:16].decode().strip()
        if name=='//': names=raw
        elif name not in ('/','/SYM64/'):
            if name.startswith('#1/'):
                length=int(name[3:]); require(0<length<=len(raw), 'invalid extended archive member name')
                name=raw[:length].rstrip(b'\0').decode(); raw=raw[length:]
            elif re.fullmatch('/[0-9]+',name):
                start=int(name[1:]); require(start<len(names), 'invalid archive member name')
                name=names[start:].split(b'/\n',1)[0].decode()
            else: name=name.rstrip('/')
            require(name and not re.search(r'[\x00-\x1f\x7f]',name), 'invalid static archive member name')
            result.append((name,offset,raw))
        offset+=60+size
        if size%2:
            require(offset<len(data) and data[offset:offset+1]==b'\n', 'invalid static archive padding')
            offset+=1
    return result

def archive_members(data, selected=None):
    result={}
    for name,offset,raw in archive_entries(data):
        if name in result:
            require(selected is not None and name not in selected, 'ambiguous duplicate archive member')
        else:result[name]=raw
    return result

def elf_sections(data):
    elf(data,True)
    offset=struct.unpack_from('<Q',data,40)[0]
    size,count,names_index=struct.unpack_from('<HHH',data,58)
    require(count>0 and size>=64 and names_index<count and offset+size*count<=len(data),
            'invalid relocatable ELF section table')
    headers=[struct.unpack_from('<IIQQQQIIQQ',data,offset+i*size) for i in range(count)]
    strings=headers[names_index]
    require(strings[1]==3 and strings[4]+strings[5]<=len(data), 'invalid ELF section names')
    names=data[strings[4]:strings[4]+strings[5]]
    result=set()
    for section in headers[1:]:
        name_offset=section[0]
        require(name_offset<len(names), 'invalid ELF section name offset')
        end=names.find(b'\0',name_offset)
        require(end>name_offset, 'unterminated ELF section name')
        name=names[name_offset:end].decode()
        require(not re.search(r'[\x00-\x1f\x7f]',name), 'invalid ELF section name')
        if section[1]!=8:
            require(section[4]+section[5]<=len(data), 'truncated ELF section')
        result.add((name,section[5]))
    return result

def lld_map_sections(data):
    lines=data.splitlines()
    require(lines and re.fullmatch(r'\s*VMA\s+LMA\s+Size\s+Align\s+Out\s+In\s+Symbol\s*',lines[0]),
            'missing actual LLD map columns')
    out_column=lines[0].index('Out'); in_column=lines[0].index('In',out_column+3)
    symbol_column=lines[0].index('Symbol',in_column+2)
    result={}
    for line in lines[1:]:
        if len(line)<=in_column or line[out_column:in_column].strip() or not line[in_column:symbol_column].strip():
            continue
        value=line[in_column:].strip()
        if ':(' not in value:continue
        if value.startswith('<internal>:'):continue
        match=re.fullmatch(r'(.+):\(([^()]*)\)',value)
        require(match is not None, 'unsupported LLD section row')
        columns=line[:out_column].split()
        require(len(columns)==4 and all(re.fullmatch(r'[0-9a-fA-F]+',part) for part in columns),
                'invalid LLD section dimensions')
        result.setdefault(match[1],set()).add((match[2],int(columns[2],16)))
    return result

def selected_archive_entries(data, member, map_sections, entries=None):
    candidates=[(offset,raw) for name,offset,raw in (entries if entries is not None else archive_entries(data)) if name==member]
    require(candidates, 'selected archive member missing')
    if len(candidates)==1:return candidates
    section_sets=[elf_sections(raw) for _,raw in candidates]
    selected=[]
    for index,candidate in enumerate(section_sets):
        other=set().union(*(sections for i,sections in enumerate(section_sets) if i!=index))
        observed=candidate & map_sections
        unique=(candidate-other) & map_sections
        require(not observed or unique, 'ambiguous selected archive occurrence')
        if unique:selected.append(candidates[index])
    require(selected, 'selected archive occurrence lacks section witness')
    return selected

def lld_map_inputs(data):
    lines=data.splitlines()
    require(lines and re.fullmatch(r'\s*VMA\s+LMA\s+Size\s+Align\s+Out\s+In\s+Symbol\s*',lines[0]),
            'missing actual LLD map columns')
    out_column=lines[0].index('Out'); in_column=lines[0].index('In',out_column+3)
    symbol_column=lines[0].index('Symbol',in_column+2)
    selected=set()
    for line in lines[1:]:
        if len(line)<=in_column or line[out_column:in_column].strip() or not line[in_column:symbol_column].strip():
            continue
        require(':(' in line[in_column:], 'unsupported LLD input row')
        name=line[in_column:].split(':(',1)[0]
        if name=='<internal>':continue
        require(re.fullmatch(r'[^\x00-\x1f\x7f]+\.a\([^()]+\)|[^\x00-\x1f\x7f]+\.o',name),
                'unsupported LLD map input')
        selected.add(name)
    require(selected, 'empty actual LLD selected input set')
    return selected

def link_closure(link, output, projects, fetch, tools=None):
    elf(output)
    require(link['outputSHA256']==digest(output), 'link output mismatch')
    require(tools is not None, 'missing authenticated linker toolchain')
    map_data=substantive(link['map'],fetch).decode()
    selected=lld_map_inputs(map_data)
    require(selected and selected=={r['mapInput'] for r in link['selectedInputs']},
            'link map/member ledger coverage mismatch')
    section_rows=lld_map_sections(map_data)
    require(selected==set(section_rows), 'link map section/input coverage mismatch')
    require(link['commands'] and link['responseFiles'], 'missing actual linker commands/response files')
    commands=[argv(record,fetch,tools) for record in link['commands']]
    require(any(any('-Map' in arg or '--Map' in arg for arg in command[1:]) for command in commands), 'linker argv lacks actual map capture')
    for record in link['responseFiles']:substantive(record,fetch)
    archive_cache={}; parsed_archives={}; expected={}; covered={}; archive_digests={}; ledger=set()
    for record in link['selectedInputs']:
        data=bound(record['file'],fetch)
        input_file=record['mapInput'].split('(',1)[0]
        require(pathlib.PurePosixPath(input_file).name==pathlib.PurePosixPath(record['file']['path']).name,
                'selected map/archive file identity mismatch')
        if 'member' in record:
            require(record['mapInput'].endswith('('+record['member']+')'), 'archive member/map mismatch')
            key=record['mapInput']; file_sha=record['file']['sha256']
            require(key not in archive_digests or archive_digests[key]==file_sha,
                    'selected map input binds different archives')
            archive_digests[key]=file_sha
            if key not in expected:
                if file_sha not in parsed_archives:parsed_archives[file_sha]=archive_entries(data)
                archive_cache[key]=selected_archive_entries(data,record['member'],section_rows[key],parsed_archives[file_sha])
                expected[key]={offset for offset,_ in archive_cache[key]}
            if len(archive_cache[key])>1:
                require('archiveOffset' in record, 'selected duplicate requires archive occurrence offset')
            offset=record.get('archiveOffset',archive_cache[key][0][0])
            require(offset in expected[key], 'selected archive occurrence offset mismatch')
            data=next(raw for entry_offset,raw in archive_cache[key] if entry_offset==offset)
            covered.setdefault(key,set()).add(offset)
            identity=(key,offset)
        else:
            require('archiveOffset' not in record, 'standalone input has archive offset')
            identity=(record['mapInput'],None)
        require(identity not in ledger, 'duplicate selected input ledger entry')
        ledger.add(identity)
        require(digest(data)==record['objectSHA256'], 'selected object mismatch'); elf(data,True)
        require(record['sourceFiles'], 'selected object has no compiled-source attribution')
        for source in record['sourceFiles']:
            require(source['project'] in projects and source['path'] in projects[source['project']], 'selected source missing')
            leaf=projects[source['project']][source['path']]
            require(leaf['gitMode']!='120000' and leaf['sha256']==source['sha256'], 'selected source attribution mismatch')
    require(expected==covered, 'selected archive occurrence ledger coverage mismatch')

def go_loader(loader, output, projects, fetch, tools=None):
    elf(output)
    require(digest(output)==loader['outputSHA256'] and loader['project'] in projects and
            loader['goRuntimeProject'] in projects, 'Go loader source/output mismatch')
    magic=b'\xff Go buildinf:'; offset=output.find(magic)
    require(offset>=0 and offset%16==0 and output.find(magic,offset+1)<0 and offset+32<=len(output), 'missing unique Go build info')
    require(output[offset+14]==8, 'wrong Go build info pointer size')
    require(output[offset+15]&2, 'unsupported pointer-based Go build info')
    def string(position):
        length=shift=0
        for _ in range(10):
            require(position<len(output), 'truncated Go build info'); byte=output[position]; position+=1
            length|=(byte&127)<<shift
            if byte<128:
                require(length<=MAX_METADATA and position+length<=len(output), 'oversized Go build info')
                return output[position:position+length],position+length
            shift+=7
        raise ValueError('invalid Go build info length')
    version,position=string(offset+32); info,_=string(position)
    require(version.decode()==loader['goVersion'] and len(info)>=32, 'Go compiler version/build info mismatch')
    info=info[16:-16].decode(); modules=[]
    for line in info.splitlines():
        fields=line.split('\t')
        if fields[0] in ('mod','dep'):
            require(len(fields)>=3, 'invalid Go module build info'); modules.append(fields[1:4])
        require(not line.startswith('=>'), 'unverified Go module replacement')
    expected=loader['modules']
    require(modules and len(expected)==len(modules) and
            {tuple(m) for m in modules}=={tuple(m['buildInfo']) for m in expected}, 'Go linked module coverage mismatch')
    for module in expected:
        require(module['project'] in projects and module['revision']==loader['moduleRevisions'][module['project']], 'Go linked module revision/source missing')
    require(loader['sourceFiles'] and loader['commands'] and loader['compiler'], 'missing Go compiled source/tool inputs')
    for source in loader['sourceFiles']:
        require(source['project'] in projects and source['path'] in projects[source['project']] and
                projects[source['project']][source['path']]['sha256']==source['sha256'], 'Go compiled source mismatch')
    require(tools is not None and loader['compiler']['sha256'] in tools.values(), 'missing authenticated Go compiler toolchain')
    substantive(loader['compiler'],fetch)
    for item in loader['commands']:argv(item,fetch,tools)
    trace=parse(substantive(loader['packageTrace'],fetch))
    require(isinstance(trace,list) and trace and {r['project'] for r in trace}==
            {m['project'] for m in expected}|{loader['goRuntimeProject']}, 'missing actual Go compiled package trace')
    for package in trace:
        require(package['sourceFiles'] and package['archive'], 'Go compiled package lacks source/archive trace')
        package_members=archive_members(substantive(package['archive'],fetch))
        require('__.PKGDEF' in package_members and package_members['__.PKGDEF'].startswith(b'go object '),
                'Go package trace lacks actual compiler archive metadata')
        for source in package['sourceFiles']:
            require(source['project']==package['project'] and source['project'] in projects and
                    source['path'] in projects[source['project']] and projects[source['project']][source['path']]['sha256']==source['sha256'], 'Go package trace source mismatch')

def verify(manifest_data, runtime, payloads, fetch, source_commit, require_authentication=True):
    manifest=parse(manifest_data)
    validate_schema(manifest)
    require(manifest_data==canonical(manifest) and manifest['kind']==KIND and manifest['schemaVersion']==1
            and manifest['sourceCommit']==source_commit and manifest['closureMode']=='new-source-build', 'wrong runtime provenance contract')
    require(runtime.get('kind')=='hostwright.runtime-license-inventory.v1' and runtime.get('schemaVersion')==1,
            'wrong runtime license inventory')
    assets=runtime.get('assets',[])
    require(len(assets)==3 and {a['identity'] for a in assets}==
            {'kata-linux-kernel','apple-vminit-oci','hostwright-netfilter-loader'}, 'runtime license asset coverage mismatch')
    require(runtime.get('status')=='qualified' and all(a.get('status')=='qualified' and
            a.get('blockers')==[] and a.get('licenseExpression') and
            'LicenseRef-' not in a['licenseExpression'] for a in assets), 'unresolved runtime license evidence')
    require(manifest['runtimeInventorySHA256']==digest(canonical(runtime)), 'runtime license inventory bytes mismatch')
    expected={path(r['path']):r for r in manifest['payloads']}
    require(len(expected)==len(manifest['payloads']) and set(expected)==set(payloads) and 0<len(expected)<=4096, 'runtime subject coverage mismatch')
    producer=manifest['producer']
    require(type(require_authentication) is bool, 'invalid authentication mode')
    producer_binding(producer,source_commit)
    for name,data in payloads.items():bound(expected[name],lambda _,data=data:data)
    if require_authentication:
        with tempfile.TemporaryDirectory() as temporary:
            temporary=pathlib.Path(temporary); item=temporary/'runtime-provenance.json'; item.write_bytes(manifest_data)
            authenticate(item,producer,source_commit)
            for index,(name,data) in enumerate(payloads.items()):
                item=temporary/('payload-'+str(index)); item.write_bytes(data); authenticate(item,producer,source_commit)
    projects={}
    project_commits={p['identity']:p['commit'] for p in manifest['sourceProjects']}
    for project in manifest['sourceProjects']:
        require(project['identity'] not in projects, 'duplicate source project')
        projects[project['identity']]=source_project(project,fetch,project_commits)
    require(projects, 'missing complete corresponding sources')
    tools=toolchain(manifest,fetch)
    oci=manifest['oci']; prefix=path(oci['prefix'])
    require(prefix=='share/hostwright/containerization/vminit' and
            manifest['kernel']['payloadPath'].startswith('share/hostwright/containerization/kernel/') and
            manifest['loader']['path']=='share/hostwright/containerization/guest/hostwright-netfilter',
            'wrong runtime asset namespace')
    visited={prefix+'/index.json',prefix+'/oci-layout',path(manifest['kernel']['payloadPath']),path(manifest['loader']['path'])}
    def blob(descriptor):
        require(re.fullmatch('sha256:[a-f0-9]{64}',descriptor['digest']) is not None, 'invalid immutable OCI descriptor')
        name=prefix+'/blobs/sha256/'+descriptor['digest'][7:]
        require(name in payloads and digest(payloads[name])==descriptor['digest'][7:] and
                len(payloads[name])==descriptor['size'], 'OCI descriptor/payload mismatch')
        visited.add(name)
        return payloads[name]
    require(parse(payloads[prefix+'/oci-layout'])=={'imageLayoutVersion':'1.0.0'}, 'wrong OCI layout')
    index=parse(payloads[prefix+'/index.json']); require(index.get('schemaVersion')==2 and
        index.get('mediaType')=='application/vnd.oci.image.index.v1+json' and len(index['manifests'])==1, 'ambiguous or wrong OCI index schema/media type')
    require(index['manifests'][0].get('mediaType') in ('application/vnd.oci.image.index.v1+json','application/vnd.oci.image.manifest.v1+json'), 'wrong OCI descriptor media type')
    image=parse(blob(index['manifests'][0]))
    if 'manifests' in image:
        require(image.get('schemaVersion')==2 and image.get('mediaType')=='application/vnd.oci.image.index.v1+json' and len(image['manifests'])==1 and
                image['manifests'][0].get('mediaType')=='application/vnd.oci.image.manifest.v1+json', 'ambiguous OCI platform manifest'); image=parse(blob(image['manifests'][0]))
    require(image.get('schemaVersion')==2 and image.get('mediaType')=='application/vnd.oci.image.manifest.v1+json' and
            image['config'].get('mediaType')=='application/vnd.oci.image.config.v1+json', 'wrong OCI manifest/config schema/media type')
    config=parse(blob(image['config'])); require(config.get('architecture')=='arm64' and config.get('os')=='linux', 'wrong OCI target')
    require(len(image['layers'])==1, 'unsupported multi-layer closure')
    # Additional layers require ordered overlay/whiteout verification before this profile can admit them.
    require(image['layers'][0].get('mediaType') in ('application/vnd.oci.image.layer.v1.tar','application/vnd.oci.image.layer.v1.tar+gzip'), 'unsupported OCI layer media type')
    layer=blob(image['layers'][0]); require(visited==set(payloads), 'unexpected or missing runtime closure payload'); extracted={}; regular={}
    compressed=image['layers'][0]['mediaType'].endswith('+gzip')
    require(compressed==(layer[:2]==b'\x1f\x8b'), 'OCI layer compression/media type mismatch')
    import gzip
    uncompressed=hashlib.sha256(); total=0
    with (gzip.GzipFile(fileobj=io.BytesIO(layer)) if compressed else io.BytesIO(layer)) as stream:
        while True:
            chunk=stream.read(1024*1024)
            if not chunk:break
            total+=len(chunk);require(total<=4*1024**3, 'oversized uncompressed OCI layer');uncompressed.update(chunk)
    require(config.get('rootfs')=={'type':'layers','diff_ids':['sha256:'+uncompressed.hexdigest()]}, 'OCI config/rootfs diff ID mismatch')
    with tarfile.open(fileobj=io.BytesIO(layer),mode='r:gz' if compressed else 'r:') as archive:
        members=archive.getmembers(); require(len(members)<=MAX_FILES, 'oversized OCI layer inventory')
        names=set()
        for member in members:
            name=path(member.name.rstrip('/')); require(name not in names, 'duplicate OCI layer member'); names.add(name)
            require(not name.startswith('proc/self/exe/'), 'OCI entry descends through the runtime symlink')
            if member.issym():
                require(name=='proc/self/exe' and member.linkname=='sbin/vminitd' and member.size==0,
                        'unsupported OCI layer symlink')
            else:
                require(member.isfile() or member.isdir(), 'unsupported OCI layer special entry')
            if member.isfile():
                require(member.size<=MAX_FILE, 'oversized OCI payload'); data=archive.extractfile(member).read()
                regular[name]=data
                if data.startswith(b'\x7fELF'): extracted[name]=data
    links={l['path']:l for l in oci['links']}
    require(len(links)==len(oci['links']), 'duplicate OCI link path')
    require(set(links)==set(extracted) and {'sbin/vminitd','sbin/vmexec'}<=set(links), 'OCI ELF/link closure coverage mismatch')
    files={f['path']:f for f in oci['files']}
    require(len(files)==len(oci['files']) and set(files)==set(regular), 'OCI regular file attribution coverage mismatch')
    for name,data in regular.items():
        record=files[name];require(record['sha256']==digest(data) and record['sizeBytes']==len(data), 'OCI file attribution bytes mismatch')
        if name in extracted:
            require(record['type']=='elf', 'wrong OCI file classification')
            components={s['project'] for item in links[name]['selectedInputs'] for s in item['sourceFiles']}
        else:
            require(record['type']=='source-copy', 'unsupported generated/unattributed non-ELF OCI file')
            source=record['source'];require(source['project'] in projects and source['path'] in projects[source['project']] and
                projects[source['project']][source['path']]['gitMode']!='120000' and
                projects[source['project']][source['path']]['sha256']==digest(data)==source['sha256'], 'non-ELF OCI source attribution mismatch')
            components={source['project']}
        require(set(record['components'])==components and len(record['components'])==len(components), 'OCI file component attribution mismatch')
    for name,data in extracted.items(): link_closure(links[name],data,projects,fetch,tools)
    kernel=manifest['kernel']; require(kernel['project'] in projects, 'kernel source project missing')
    kernel_data=payloads[path(kernel['payloadPath'])]; arm64_image(kernel_data)
    require(digest(kernel_data)==kernel['outputSHA256'] and kernel['patches'] is not None, 'kernel build output mismatch')
    kernel_project=next(p for p in manifest['sourceProjects'] if p['identity']==kernel['project'])
    require({(r['path'],r['sha256']) for r in kernel['patches']}==
            {(r['path'],r['sha256']) for r in kernel_project['patches']}, 'kernel applied patch/source inventory mismatch')
    compiler=next(t for t in manifest['toolchain'] if t['identity']=='compiler')
    require(kernel['compiler']['sha256']==compiler['executable']['sha256'], 'kernel compiler not bound to authenticated compiler toolchain')
    config=substantive(kernel['config'],fetch)
    require(b'CONFIG_ARM64=y' in config, 'kernel config lacks actual target configuration')
    substantive(kernel['compiler'],fetch);argv(kernel['commands'],fetch,tools)
    for record in kernel['patches']:substantive(record,fetch)
    loader=manifest['loader']; require(loader['path'] in payloads, 'loader payload missing')
    revisions={p['identity']:p['commit'] for p in manifest['sourceProjects']}
    if loader.get('format')=='go-buildinfo-v1':
        require(revisions.get(loader['project'])==source_commit, 'loader differs from accepted release source commit')
        require(loader['moduleRevisions']=={m['project']:revisions[m['project']] for m in loader['modules']}, 'Go module revision does not bind complete source commit')
        go_loader(loader,payloads[loader['path']],projects,fetch,tools)
        loader_components={loader['project'],loader['goRuntimeProject']}|{m['project'] for m in loader['modules']}
    else:
        attributed={s['project'] for record in loader['selectedInputs'] for s in record['sourceFiles']}
        require(any(revisions.get(p)==source_commit for p in attributed), 'loader differs from accepted release source commit')
        link_closure(loader,payloads[loader['path']],projects,fetch,tools)
        loader_components=attributed
    component_sets={'kata-linux-kernel':{kernel['project']},'hostwright-netfilter-loader':loader_components,
                    'apple-vminit-oci':{c for record in files.values() for c in record['components']}}
    source_records={p['identity']:p for p in manifest['sourceProjects']}
    require(set(manifest['licensing'])==set(component_sets), 'runtime licensing asset coverage mismatch')
    for asset in assets:
        mappings=manifest['licensing'][asset['identity']]
        require(len(mappings)==len(component_sets[asset['identity']]) and {m['project'] for m in mappings}==component_sets[asset['identity']], 'runtime licensing component coverage mismatch')
        expressions=[]
        for mapping in mappings:
            project=source_records[mapping['project']]
            require(mapping['spdx']==project['spdx'] and set(mapping['licenses'])=={r['path'] for r in project['licenses']} and
                    set(mapping['notices'])=={r['path'] for r in project['notices']}, 'runtime licensing exact source/SPDX mapping mismatch')
            expressions.append(spdx(mapping['spdx']))
        expressions=sorted(set(expressions)); expression=expressions[0] if len(expressions)==1 else '('+' AND '.join('('+e+')' for e in expressions)+')'
        require(asset['licenseExpression']==expression, 'runtime SPDX expression differs from actual component mapping')
    return {'kind':KIND,'sourceCommit':source_commit,'manifestSHA256':digest(manifest_data),'payloadCount':len(payloads)}

def verify_source_bundle(archive, source_commit, product_payloads=None):
    members=archive.getmembers()
    require(len(members)<=MAX_FILES, 'oversized provenance source bundle')
    files={}
    for member in members:
        name=path(member.name.rstrip('/'))
        require(name not in files, 'duplicate provenance bundle member')
        files[name]=member
    def fetch(name):
        name=path(name)
        require(name in files and files[name].isfile() and files[name].size<=MAX_FILE,
                'missing regular provenance evidence: '+name)
        return archive.extractfile(files[name]).read()
    runtime=parse(fetch('licenses/runtime-license-inventory.json'))
    data=fetch('runtime-provenance/manifest.json'); manifest=parse(data)
    source_payloads={r['path']:fetch('runtime-provenance/payloads/'+path(r['path'])) for r in manifest['payloads']}
    if product_payloads is not None:
        require(source_payloads==product_payloads, 'actual product/runtime source payload mismatch')
    return verify(data,runtime,source_payloads,fetch,source_commit)

if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser()
    parser.add_argument('--source-archive',type=pathlib.Path,required=True)
    parser.add_argument('--source-commit',required=True)
    parser.add_argument('--expected-archive-sha256',required=True)
    args=parser.parse_args()
    require(re.fullmatch('[a-f0-9]{40}',args.source_commit) is not None, 'invalid accepted source commit')
    require(not args.source_archive.is_symlink() and args.source_archive.is_file(), 'unsafe source archive')
    with args.source_archive.open('rb') as stream:
        require(hashlib.file_digest(stream,'sha256').hexdigest()==args.expected_archive_sha256, 'source archive hash mismatch')
    with tarfile.open(args.source_archive,'r:gz') as archive:
        print(json.dumps(verify_source_bundle(archive,args.source_commit),sort_keys=True))
