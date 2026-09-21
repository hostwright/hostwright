#!/usr/bin/env python3
"""Maintainer-only real lifecycle qualification. No identity/SQL fabrication.

Binding schemaVersion1: source exact clean commit; lane exact; artifacts with
absolute path, signedSHA256, payloadPath. release requires protected root-owned
stageRoot containing stage-inventory.json, inventorySHA256, verifierPath,
verifierSHA256, version, teamIdentifier. Existing hostwright-dist verify-release
must successfully verify signed/CMS sidecars, archive/package and actual payload.
CLI/daemon/all companion/dist executed bytes must equal signed archived payload bytes.

Apple: runtimeTool={path,sha256}; runtimeAppRoot private existing canonical dir;
qualification-root.json binds source,lane,runtimeToolSHA256,runtimeAppRoot and
environment CONTAINER_APP_ROOT; bind runtimeAppRootReceiptSHA256. vmIsolation
contains toolPath/toolSHA256/tartHome/name; Tart list must assert local stopped.
memory contains rssBudgetBytes/processPaths/processSHA256. scheduling tolerance
soakSchedulingToleranceSeconds is 0..2; observations must finish within30s, no
catch-up. health contains service/manifestSHA256/marker/hostPort/containerPort/
bodySHA256; target must be JSON Manifest3 with explicit loopback publication,
marker embedded in command and startup/readiness/liveness probes.
SDK: exact protected seed tool/config/OCI/assets and signed status/stats/logs
prove per-owned allocation plus internal guest HTTP/SHA/cgroup health. Preservation
covers private native files, explicit unmanaged host processes and full Tart rows;
it does not claim global VZ enumeration. No observer boolean grants a pass.
Daemon config is explicit distinct JSON Manifest3 with all elective actions
one-shot deferred >24hours. Existing roots are rejected before mutation.
Failed runs stop only the owned daemon; retained workloads require explicit
coordinator recovery/cleanup. A pass is not release publication authorization.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.request
import urllib.parse
import zipfile
import stat
import sdk_qualification_observer as sdk

LANES = {'apple-cli-1.0.0': ('apple-container-cli', '1.0.0'),
         'apple-cli-1.1.0': ('apple-container-cli', '1.1.0'),
         'containerization-0.35.0': ('apple-containerization', '0.35.0')}
HEX = re.compile(r'^[0-9a-f]{64}$')

class Rejected(RuntimeError):
    pass

def require(condition, reason):
    if not condition:
        raise Rejected(reason)

def sha(path):
    p = Path(path)
    require(p.is_file() and not p.is_symlink(), f'not a regular bound file: {p}')
    before = p.stat()
    digest = hashlib.sha256()
    with p.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1048576), b''):
            digest.update(chunk)
    value = digest.hexdigest()
    after = p.stat()
    identity = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns, item.st_ctime_ns)
    require(identity(before) == identity(after), f'file changed while hashing: {p}')
    return value

def bound(path, expected):
    require(isinstance(expected, str) and HEX.fullmatch(expected), 'invalid SHA256')
    require(sha(path) == expected, f'binding mismatch: {path}')

def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f'duplicate JSON key: {key}')
        result[key] = value
    return result

def decode(data):
    return json.loads(data, object_pairs_hook=unique_pairs, parse_constant=lambda value: (_ for _ in ()).throw(Rejected('nonfinite JSON constant')))

def load(path):
    return decode(Path(path).read_text())

def atomic(path, data):
    p = Path(path)
    temporary = p.with_suffix(p.suffix + '.tmp')
    temporary.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
    os.replace(temporary, p)

def manifest_project(path):
    text = Path(path).read_text()
    try:
        obj = decode(text)
        require(obj.get('version') == 3, 'Manifest 3 required')
        return obj['project']
    except json.JSONDecodeError:
        require('\t' not in text and not re.search(r'(^---|^\.\.\.|[&*]|<<:)', text, re.M),
                'use plain YAML or JSON for qualification')
        versions = re.findall(r'^version:\s*3\s*$', text, re.M)
        projects = re.findall(r'^project:\s*([A-Za-z0-9._-]+)\s*$', text, re.M)
        require(len(versions) == 1 and len(projects) == 1, 'ambiguous manifest header')
        return projects[0]

def validate_deferral(path, target, now):
    obj = load(path)
    require(obj.get('version') == 3 and obj.get('project') != target and obj.get('services'),
            'daemon config must be a distinct nonempty Manifest 3')
    policy = obj.get('maintenance', {})
    require(policy.get('timezone') == 'UTC', 'daemon maintenance timezone must be UTC')
    duration = policy.get('maximumDeferral', '')
    require(re.fullmatch(r'\d+s', duration) and int(duration[:-1]) >= 86400,
            'daemon maximumDeferral must be >=86400s')
    windows = policy.get('windows', [])
    require(windows, 'explicit daemon maintenance windows required')
    actions = set()
    ids = set()
    for window in windows:
        identifier = window.get('id', '')
        require(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', identifier) and identifier not in ids,
                'daemon maintenance window requires a unique valid id')
        ids.add(identifier)
        require('recurring' not in window and 'oneShot' in window, 'only one-shot deferral accepted')
        duration = window['oneShot'].get('duration', '')
        require(re.fullmatch(r'\d+s', duration) and 60 <= int(duration[:-1]) <= 86400,
                'daemon maintenance duration must be 60..86400s')
        starts = dt.datetime.fromisoformat(window['oneShot']['startsAt'].replace('Z', '+00:00'))
        require(starts.timestamp() > now + 86400, 'daemon deferral begins too soon')
        actions.update(window.get('actions', []))
    require({'create', 'start', 'restart', 'update', 'remove'} <= actions,
            'daemon deferral must cover every elective action')

def preflight(args, runner=subprocess.run):
    require(args.lane in LANES, 'unsupported exact lane')
    for root in (args.state_root, args.evidence):
        require(not Path(root).exists() and not Path(root).is_symlink(), 'ambiguous existing state/evidence')
        require(Path(root).is_absolute(), 'roots must be absolute')
    roots = [Path(args.state_root), Path(args.evidence)]
    require(not any(a == b or a in b.parents for a, b in ((roots[0], roots[1]), (roots[1], roots[0]))), 'state/evidence overlap')
    for root in roots:
        require(root.resolve() == root and root.parent.is_dir() and not any(p.is_symlink() for p in root.parents), 'unsafe root ancestry')
        require(Path(args.source_root).resolve() not in root.parents, 'evidence/state must be outside clean source')
    require(len(str(roots[0]/'support/run/control-v2.sock').encode()) < 100, 'state socket path too long')
    binding = load(args.binding)
    require(binding.get('schemaVersion') == 1 and binding.get('lane') == args.lane, 'wrong lane binding')
    source = binding.get('source', '')
    require(re.fullmatch(r'[0-9a-f]{40}', source), 'exact clean source commit required')
    head = runner(['git', '-C', args.source_root, 'rev-parse', 'HEAD'], capture_output=True, text=True, check=True, timeout=5).stdout.strip()
    dirty = runner(['git', '-C', args.source_root, 'status', '--porcelain', '--untracked-files=all'], capture_output=True, text=True, check=True, timeout=5).stdout
    require(head == source and not dirty, 'source mismatch or dirty source')
    artifacts = binding.get('artifacts', [])
    require(artifacts, 'artifact bindings required')
    seen = set()
    for artifact in artifacts:
        path = artifact['path']
        require(Path(path).is_absolute() and Path(path).resolve() == Path(path) and path not in seen, 'ambiguous artifact path')
        seen.add(path)
        bound(path, artifact['signedSHA256'])
        runner(['/usr/bin/codesign', '--verify', '--strict', path], check=True, capture_output=True)
    require(args.cli in seen and args.daemon in seen, 'CLI and daemon must be receipt-bound artifacts')
    tool = binding.get('runtimeTool', {})
    require(tool.get('path') == args.runtime_tool, 'runtime tool path mismatch')
    bound(args.runtime_tool, tool.get('sha256'))
    bound(args.manifest, args.manifest_sha256)
    bound(args.daemon_config, args.daemon_config_sha256)
    require(manifest_project(args.manifest) == args.project, 'manifest project mismatch')
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', args.project), 'invalid project')
    validate_deferral(args.daemon_config, args.project, time.time())
    if LANES[args.lane][0] == 'apple-container-cli':
        version = runner([args.runtime_tool, '--version'], capture_output=True, text=True, check=True, timeout=5).stdout
        require(set(re.findall(r'\b\d+\.\d+\.\d+\b', version)) == {LANES[args.lane][1]}, 'wrong runtime lane version')
    else:
        validate_sdk_inputs(args, binding, fresh=True)
    binding['_verifiedReleaseReport'] = verify_provenance(args, binding, runner)
    validate_runtime_root(binding)
    if LANES[args.lane][0] == 'apple-container-cli': validate_health_manifest(args, binding)
    stopped_vm(binding, runner)
    memory = binding['memory']
    require(isinstance(memory['rssBudgetBytes'], int) and memory['rssBudgetBytes'] > 0 and memory['processPaths'], 'explicit process memory budget/scope required')
    for path in memory['processPaths']:
        bound(path, memory['processSHA256'][path])
    require(0 <= binding['soakSchedulingToleranceSeconds'] <= 2, 'soak tolerance must be 0..2 seconds')
    return binding

def protected(path):
    p = Path(path)
    require(p.is_absolute() and p.resolve() == p, 'unsafe protected path')
    for item in (p, *p.parents):
        info = item.lstat()
        require(info.st_uid == 0 and not info.st_mode & 0o022 and not stat.S_ISLNK(info.st_mode),
                f'provenance input/tool must have protected root-owned ancestry: {item}')

def verify_corresponding_source(args, binding, proof, inventory, runner):
    source = inventory.get('correspondingSource')
    require(isinstance(source, dict)
            and source.get('kind') == 'hostwright.corresponding-source-stage.v1'
            and source.get('sourceCommit') == binding['source']
            and source.get('version') == proof['version']
            and source.get('sourceManifestKind') == 'hostwright.corresponding-source.new-runtime.v1'
            and source.get('sourceManifestSchemaVersion') == 1,
            'corresponding-source stage binding mismatch')
    source_root = Path(proof['stageRoot'])/'source'
    files = inventory.get('files')
    require(isinstance(files, dict), 'stage inventory file bindings missing')
    descriptors = {}
    for role in ('archive', 'manifest', 'checksums'):
        descriptor = source.get(role)
        require(isinstance(descriptor, dict), 'corresponding-source file descriptor missing')
        name = descriptor.get('fileName')
        require(isinstance(name, str) and name and Path(name).name == name
                and name not in descriptors, 'unsafe corresponding-source file name')
        path = source_root/name
        protected(path)
        bound(path, descriptor.get('sha256'))
        relative = 'source/'+name
        require(files.get(relative) == descriptor['sha256'], 'corresponding-source inventory mismatch')
        if 'sizeBytes' in descriptor:
            require(descriptor['sizeBytes'] == path.stat().st_size, 'corresponding-source size mismatch')
        descriptors[role] = path

    archive = descriptors['archive']
    manifest_path = descriptors['manifest']
    checksums = descriptors['checksums']
    expected_checksums = (
        source['archive']['sha256']+'  '+archive.name+'\n'
        +source['manifest']['sha256']+'  '+manifest_path.name+'\n'
    ).encode()
    require(checksums.read_bytes() == expected_checksums, 'corresponding-source checksum inventory mismatch')
    manifest = load(manifest_path)
    require(manifest.get('kind') == source['sourceManifestKind']
            and manifest.get('schemaVersion') == source['sourceManifestSchemaVersion']
            and manifest.get('releaseSourceRevision') == binding['source']
            and manifest.get('version') == proof['version'],
            'corresponding-source manifest binding mismatch')

    verifier = Path(args.source_root)/'scripts/release/corresponding-source.py'
    require(verifier.is_file() and not verifier.is_symlink(), 'corresponding-source verifier missing from clean source')
    result = runner([
        sys.executable, str(verifier), 'verify',
        '--archive', str(archive),
        '--expected-archive-sha256', source['archive']['sha256'],
        '--expected-manifest-sha256', source['manifest']['sha256'],
        '--expected-source', binding['source'],
        '--expected-version', proof['version'],
    ], capture_output=True, text=True, check=True, timeout=600)
    report = decode(result.stdout)
    require(report.get('archiveSHA256') == source['archive']['sha256']
            and report.get('manifestSHA256') == source['manifest']['sha256']
            and report.get('releaseSourceRevision') == binding['source']
            and report.get('version') == proof['version']
            and report.get('status') == 'prepared-not-release-qualified',
            'corresponding-source verifier returned different bindings')
    return report

def verify_provenance(args, binding, runner):
    proof = binding.get('release', {})
    require(proof, 'protected staged release provenance required')
    stage = Path(proof['stageRoot'])
    inventory_path = stage/'stage-inventory.json'
    protected(stage); protected(inventory_path); protected(proof['verifierPath'])
    bound(inventory_path, proof['inventorySHA256'])
    bound(proof['verifierPath'], proof['verifierSHA256'])
    inventory = load(inventory_path)
    require(inventory.get('kind') == 'hostwright.stage-inventory.v2'
            and inventory.get('sourceCommit') == binding['source']
            and inventory.get('version') == proof['version']
            and re.fullmatch(r'[1-9][0-9]*', str(inventory.get('buildRunID', '')))
            and re.fullmatch(r'[1-9][0-9]*', str(inventory.get('buildRunAttempt', ''))),
            'stage source/version/run mismatch')
    files = inventory['files']
    for relative, digest in files.items():
        require(not Path(relative).is_absolute() and '..' not in Path(relative).parts, 'unsafe stage inventory path')
        protected(stage/relative); bound(stage/relative, digest)
    verify_corresponding_source(args, binding, proof, inventory, runner)
    release_dir = stage/'release'
    require({'release/'+entry.name for entry in release_dir.iterdir()} <= set(files), 'stage inventory omits release/CMS inputs')
    result = runner([proof['verifierPath'], 'verify-release', '--release-dir', str(release_dir),
                     '--team-id', proof['teamIdentifier'], '--format', 'json'], capture_output=True, text=True, check=True, timeout=600)
    require(result.returncode == 0, 'live release verifier failed')
    report = decode(result.stdout)
    manifest = load(release_dir/'release-manifest.json')
    require(report.get('schemaVersion') == 1 and report.get('kind') == 'trustedReleaseVerification'
            and report.get('status') == 'passed' and report.get('sourceCommit') == binding['source']
            and report.get('packageVersion') == proof['version'] and report.get('signerTeamIdentifier') == proof['teamIdentifier'],
            'live release verifier source/version/signer mismatch')
    require(manifest['sourceCommit'] == binding['source'] and manifest['packageVersion'] == proof['version'], 'signed manifest source/version mismatch')
    for role in ('archive', 'package'):
        descriptor = manifest[role]
        require(report[role] == descriptor and files.get('release/'+descriptor['fileName']) == descriptor['sha256'], 'release archive/package mismatch')
        bound(release_dir/descriptor['fileName'], descriptor['sha256'])
    payload = {x['path']: x for x in manifest['payloadFiles']}
    require(len(payload) == len(manifest['payloadFiles']), 'duplicate signed payload path')
    with zipfile.ZipFile(release_dir/manifest['archive']['fileName']) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), 'duplicate archive entries')
        for artifact in binding['artifacts']:
            relative = artifact.get('payloadPath')
            require(relative in payload, 'selected executable absent from signed payload')
            entry = manifest['artifactID']+'/'+relative
            require(entry in names, 'selected executable absent from actual archive')
            actual = hashlib.sha256(archive.read(entry)).hexdigest()
            require(actual == payload[relative]['sha256'] == artifact['signedSHA256'] == sha(artifact['path']),
                    'selected extracted executable differs from signed release payload')
    require(proof['verifierPath'] in {x['path'] for x in binding['artifacts']}, 'trusted verifier must itself match signed payload')
    required = {'bin/'+name for name in ('hostwright', 'hostwrightd', 'hostwright-control', 'hostwright-dist', 'hostwright-containerization-helper', 'hostwright-network-helper', 'hostwright-network-provider-worker', 'hostwright-storage-helper')}
    require(required <= {x.get('payloadPath') for x in binding['artifacts']}, 'all CLI/daemon/companion/verifier payload bindings required')
    for artifact in binding['artifacts']:
        if artifact['payloadPath'] in required:
            require(Path(artifact['path']) == Path(args.cli).parent/Path(artifact['payloadPath']).name, 'executed companion must match selected installation bin directory')
    return report

def validate_runtime_root(binding):
    root = Path(binding['runtimeAppRoot'])
    require(root.is_absolute() and root.resolve() == root and root.is_dir() and not root.is_symlink(), 'unsafe runtimeAppRoot')
    info = root.stat()
    require(info.st_uid == os.getuid() and not info.st_mode & 0o077, 'runtimeAppRoot must be private and owned')
    bound(root/'qualification-root.json', binding['runtimeAppRootReceiptSHA256'])
    receipt = load(root/'qualification-root.json')
    require(receipt == {'source': binding['source'], 'lane': binding['lane'], 'runtimeToolSHA256': binding['runtimeTool']['sha256'],
                        'runtimeAppRoot': str(root), 'environment': 'CONTAINER_APP_ROOT'}, 'runtimeAppRoot binding mismatch')

def stopped_vm(binding, runner):
    vm = binding['vmIsolation']
    bound(vm['toolPath'], vm['toolSHA256'])
    home = Path(vm['tartHome'])
    require(home.is_absolute() and home.resolve() == home and home.is_dir(), 'unsafe TART_HOME')
    env = dict(os.environ, TART_HOME=str(home))
    result = runner([vm['toolPath'], 'list', '--format', 'json'], env=env, capture_output=True, text=True, check=True, timeout=5)
    rows = decode(result.stdout)
    selected = [x for x in rows if x.get('Name') == vm['name'] and x.get('Source') == 'local']
    require(len(selected) == 1 and selected[0].get('Running') is False and selected[0].get('State') == 'stopped', 'lab VM is running, missing or unknown')
    return {'vm': selected[0], 'rawInventory': rows, 'TART_HOME': str(home), 'toolSHA256': vm['toolSHA256']}

def validate_health_manifest(args, binding):
    manifest = load(args.manifest)  # Strict JSON avoids a second partial YAML parser.
    health = binding['health']
    require(health['manifestSHA256'] == args.manifest_sha256 and re.fullmatch(r'[0-9a-f]{32,128}', health['marker']), 'unique workload health marker binding required')
    service = manifest['services'][health['service']]
    require(health['marker'] in json.dumps(service.get('command', [])), 'marker must be embedded in exact workload command')
    require(all(service.get('probes', {}).get(kind) for kind in ('startup', 'readiness', 'liveness')), 'all real workload probes required')
    publication = f"127.0.0.1:{health['hostPort']}:{health['containerPort']}"
    require(publication in service.get('ports', []), 'health URL must match explicit manifest loopback publication')
    url = urllib.parse.urlsplit(args.health_url)
    require(url.hostname == '127.0.0.1' and url.port == health['hostPort'] and HEX.fullmatch(health['bodySHA256']), 'health URL/body binding mismatch')
    return health

def validate_status_health(status, own, health):
    services = [x for x in status.get('services', []) if x.get('name') == health['service']]
    require(len(services) == 1, 'authenticated target service unavailable')
    observed = services[0].get('observed', {})
    require(observed.get('resourceIdentifier') == own['id'] and observed.get('lifecycle') == 'running'
            and observed.get('health') == 'healthy', 'authenticated workload identity/health failed')
    require(not status.get('drift'), 'authenticated workload has drift')

def validate_body(body, health):
    require(health['marker'].encode() in body and hashlib.sha256(body).hexdigest() == health['bodySHA256'], 'unrelated HTTP200 or wrong workload health body')

def validate_owned_port(own, health, ports, provider):
    labels = own['nativeInventory']['configuration']['labels']
    require(len(ports) == 1 and ports[0]['resource_uuid'] == labels['dev.hostwright.resource-uuid']
            and ports[0]['fencing_token'] == labels['dev.hostwright.fencing-token']
            and ports[0]['lifecycle_state'] == 'active' and ports[0]['provider_id'] == provider
            and ports[0]['bind_address'] == '127.0.0.1' and ports[0]['container_port'] == health['containerPort'],
            'owned durable port UUID/fence/provider mismatch')

def timing_sample(scheduled, started, finished, tolerance, previous=None):
    require(0 <= tolerance <= 2 and scheduled <= started <= scheduled+tolerance
            and started <= finished < scheduled+30, 'missed soak checkpoint/deadline')
    require(previous is None or scheduled-previous['scheduled'] == 30 and started-previous['started'] >= 30-tolerance,
            'duplicate/catch-up soak sample')
    return {'scheduled': scheduled, 'started': started, 'finished': finished}

def parse_process_memory(raw, daemon_pid, scope, budget, require_scope=True):
    rows = []
    for line in raw.splitlines():
        fields = line.split(maxsplit=8)
        require(len(fields) == 9, 'missing process memory evidence')
        rows.append({'pid': int(fields[0]), 'ppid': int(fields[1]), 'rssBytes': int(fields[2])*1024,
                     'started': ' '.join(fields[3:8]), 'path': fields[8]})
    selected = [x for x in rows if x['pid'] == daemon_pid or x['path'] in scope]
    require(any(x['pid'] == daemon_pid for x in selected) and selected and all(x['rssBytes'] > 0 for x in selected), 'missing daemon/process memory evidence')
    require(not require_scope or set(scope) <= {x['path'] for x in selected}, 'missing required runtime/helper process measurement')
    require(sum(x['rssBytes'] for x in selected) <= budget, 'process RSS memory budget exceeded')
    return selected

def guard_input_files(args, binding, binding_digest):
    require(sha(args.binding) == binding_digest, 'artifact receipt changed')
    for artifact in binding['artifacts']:
        bound(artifact['path'], artifact['signedSHA256'])
    bound(args.runtime_tool, binding['runtimeTool']['sha256'])
    bound(args.daemon_config, args.daemon_config_sha256)
    bound(args.manifest, args.manifest_sha256)
    proof = binding['release']
    protected(proof['stageRoot']); protected(proof['verifierPath'])
    bound(Path(proof['stageRoot'])/'stage-inventory.json', proof['inventorySHA256'])
    bound(proof['verifierPath'], proof['verifierSHA256'])
    for relative, digest in load(Path(proof['stageRoot'])/'stage-inventory.json')['files'].items():
        protected(Path(proof['stageRoot'])/relative)
        bound(Path(proof['stageRoot'])/relative, digest)
    validate_runtime_root(binding)
    if LANES[args.lane][0] == 'apple-containerization': validate_sdk_inputs(args, binding)

def validate_sdk_inputs(args, binding, fresh=False):
    require(isinstance(binding.get('sdk'),dict), 'SDK blocked: concrete SDK bindings required')
    spec = binding['sdk']
    bound(__file__,spec['harnessSHA256']); bound(sdk.__file__,spec['observerSHA256'])
    bound(Path(args.source_root)/'scripts/qualification/authenticated-lifecycle.py',spec['harnessSHA256'])
    bound(Path(args.source_root)/'scripts/qualification/sdk_qualification_observer.py',spec['observerSHA256'])
    raw, metadata = sdk.secure_read(spec['configInputPath'], limit=65536)
    require(metadata['sha256'] == spec['configSHA256'], 'SDK config input changed')
    config = sdk.decode(raw)
    require(config.get('schema') == 1 and config.get('framework') == '0.35.0', 'SDK config framework mismatch')
    data = Path(config['dataRootPath'])
    state = Path(args.state_root)
    require(data.is_absolute() and data.resolve() == data and data.parent.is_dir() and data != state and state not in data.parents and data not in state.parents, 'unsafe/overlapping SDK data root')
    require(config['runtimeDirectoryPath'] == str(state/'support/run/helper'), 'SDK helper runtime must be private selected installed path')
    require(not any(x.is_symlink() for x in data.parents), 'SDK data ancestry symlink')
    parent = data.parent.stat()
    require(parent.st_uid == os.getuid() and stat.S_IMODE(parent.st_mode) == 0o700, 'SDK seed parent must be private')
    for other in (Path(args.evidence),Path(args.source_root),Path(spec['layoutPath']),Path(spec['configInputPath']),Path(config['initImageLayoutPath'])):
        require(data != other and data not in other.parents and other not in data.parents, 'SDK root overlaps qualification inputs')
    if fresh: bound(spec['inputArchivePath'],spec['inputArchiveSHA256'])
    if fresh: require(not data.exists() and not data.is_symlink(), 'SDK data root must be fresh before seeding')
    require(spec.get('frameworkRevision') == '44bec8b9933bc491d0cbf44abac90a1f6aaebf6b', 'SDK source revision mismatch')
    for path, digest in spec['assetSHA256'].items(): bound(path, digest)
    require(config['kernelPath'] in spec['assetSHA256'] and config['kernelSHA256'] == spec['assetSHA256'][config['kernelPath']] == '2fe4a58d2885d623bcb4d705900ac8c1d4f02371152da8126b3b00c8c47fc3a1', 'SDK kernel not pinned byte bound')
    require(not config.get('guestNetworkPolicyLoaderPath') and not config.get('guestNetworkPolicyLoaderSHA256'), 'qualification workload does not admit guest policy loader')
    init_digests = ('5708d65ba1914caa756a2e813831e17d7655042799310bc94efef82210c2dac6','04cd14f8e6ec9617611429aaf2a91a841b27ff9eae847acaca48430f58c5e57d','30d24816422f41337fae35f59a3c03ac13559fd42bd0d67321a7db4d57ac4988','e3b2b9d347c2e5834d9fe5b4d615f5c0632c485d785e64f5c6b4c9b179ac168f')
    for digest in init_digests:
        require(spec['assetSHA256'].get(str(Path(config['initImageLayoutPath'])/'blobs/sha256'/digest)) == digest, 'SDK init OCI asset omitted or unpinned')
    require(config['initImageDescriptorDigest'] == 'sha256:'+init_digests[0] and config['initImageVariantDigest'] == 'sha256:'+init_digests[1], 'SDK init descriptors mismatch')
    if fresh: require(sdk.oci_tree_digest(spec['layoutPath']) == spec['layoutSHA256'], 'SDK OCI input tree mismatch')
    require(spec['unmanagedProcessPaths'] and all(Path(x).is_absolute() for x in spec['unmanagedProcessPaths']), 'explicit unmanaged host workload process scope required')
    for path in spec['unmanagedProcessPaths']: bound(path,spec['unmanagedProcessSHA256'][path])
    require(HEX.fullmatch(spec['capabilitySHA256']), 'SDK capability binding required')
    sdk.validate_manifest(load(args.manifest), binding['health']['service'], spec['nonce'], args.cpus, args.memory_bytes, spec['reference'])
    require(binding['health']['manifestSHA256'] == args.manifest_sha256, 'SDK health manifest changed')
    protected(args.runtime_tool)
    stage = Path(binding['release']['stageRoot'])
    require(stage in Path(args.runtime_tool).parents, 'maintainer SDK seeder must be protected stage input')
    relative = str(Path(args.runtime_tool).relative_to(stage))
    require(load(stage/'stage-inventory.json')['files'].get(relative) == binding['runtimeTool']['sha256'], 'maintainer seeder absent from exact stage source inventory')
    return config

class Harness:
    def __init__(self, args, binding):
        self.a, self.binding = args, binding
        self.provider, self.version = LANES[args.lane]
        self.evidence = Path(args.evidence)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('HOSTWRIGHT_')}
        self.env.update(HOSTWRIGHT_APPLICATION_SUPPORT_DIR=str(Path(args.state_root)/'support'),
                        HOSTWRIGHT_CACHE_DIR=str(Path(args.state_root)/'cache'),
                        HOSTWRIGHT_LOG_DIR=str(Path(args.state_root)/'logs'),
                        CONTAINER_APP_ROOT=binding['runtimeAppRoot'],
                        PATH=str(Path(args.runtime_tool).parent)+':'+str(Path(args.cli).parent)+':/usr/bin:/bin:/usr/sbin:/sbin')
        self.sequence, self.daemon, self.receipts = 0, None, []
        self.observation_deadline = None
        self.checkpoint = {'status': 'incomplete', 'lane': args.lane, 'cycles': 0, 'soakSamples': 0,
                           'schedulingTolerance': binding['soakSchedulingToleranceSeconds'], 'bindingSHA256': sha(args.binding), 'source': binding['source'], 'daemonCleaned': False, 'verifiedActions': [], 'verifiedObservations': [], 'releaseVerification': binding['_verifiedReleaseReport']}

    def save(self):
        atomic(self.evidence/'checkpoint.json', self.checkpoint)

    def remaining(self, maximum):
        if self.observation_deadline is None: return maximum
        left = self.observation_deadline-time.monotonic()
        require(left > 0, 'observation deadline exceeded')
        return min(maximum, left)

    def command(self, argv, timeout=420, raw=False):
        timeout = self.remaining(timeout)
        self.sequence += 1
        stem = f'{self.sequence:04d}'
        start = time.time()
        timed_out = False
        try:
            result = subprocess.run(argv, env=self.env, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            timed_out = True
            result = subprocess.CompletedProcess(argv, 124, error.stdout or b'', error.stderr or b'')
        out, err = self.evidence/(stem+'.stdout'), self.evidence/(stem+'.stderr')
        out.write_bytes(result.stdout); err.write_bytes(result.stderr)
        receipt = {'argv': argv, 'startedAt': start, 'finishedAt': time.time(), 'exitCode': result.returncode,
                   'stdoutSHA256': sha(out), 'stderrSHA256': sha(err), 'timedOut': timed_out}
        atomic(self.evidence/(stem+'.receipt.json'), receipt)
        self.receipts.append(receipt)
        require(result.returncode == 0, f'command failed; see {stem}.receipt.json')
        if raw: return result.stdout.decode()
        return decode(result.stdout) if result.stdout.strip().startswith(b'{') or result.stdout.strip().startswith(b'[') else result.stdout.decode()

    def guard_bindings(self):
        head = subprocess.run(['git', '-C', self.a.source_root, 'rev-parse', 'HEAD'], capture_output=True, text=True, check=True, timeout=self.remaining(5)).stdout.strip()
        dirty = subprocess.run(['git', '-C', self.a.source_root, 'status', '--porcelain', '--untracked-files=all'], capture_output=True, text=True, check=True, timeout=self.remaining(5)).stdout
        require(head == self.binding['source'] and not dirty, 'source changed or became dirty during qualification')
        guard_input_files(self.a, self.binding, self.checkpoint['bindingSHA256'])
        vm_evidence = stopped_vm(self.binding, subprocess.run)
        self.checkpoint.setdefault('vmIsolationSamples', []).append(vm_evidence)
        for path in self.binding['memory']['processPaths']:
            bound(path, self.binding['memory']['processSHA256'][path])
        if self.provider != 'apple-container-cli':
            sdk.preserve_tart(self.sdk_tart_baseline, vm_evidence['rawInventory'])

    def inventory(self):
        if self.provider == 'apple-container-cli':
            raw = self.command([self.a.runtime_tool, 'list', '--all', '--format', 'json'])
            return sorted([{'id': x['id'], 'project': x['configuration'].get('labels', {}).get('dev.hostwright.project'),
                            'state': x['status']['state'], 'cpuCount': x['configuration']['resources']['cpus'],
                            'memoryBytes': x['configuration']['resources']['memoryInBytes'], 'nativeInventory': x} for x in raw], key=lambda x: x['id'])
        return self.sdk_inventory()

    def sdk_inventory(self):
        records = sdk.record_inventory(self.sdk_config['dataRootPath'])
        result = []
        for entry in records:
            r = entry['record']; labels = {x['key']: x['value'] for x in r['labels']}
            result.append({'id': r['resourceIdentifier'], 'project': labels.get('dev.hostwright.project'),
                           'state': r['phase'], 'cpuCount': r.get('cpuCount'), 'memoryBytes': r.get('memoryBytes'),
                           'scope': 'native-persisted-configuration', 'nativeInventory': entry})
        return sorted(result, key=lambda x:x['id'])

    def sdk_initial_baseline(self):
        self.sdk_config = validate_sdk_inputs(self.a, self.binding, fresh=True)
        self.sdk_tart_baseline = stopped_vm(self.binding, subprocess.run)['rawInventory']
        result = subprocess.run(['/bin/ps','-ww','-axo','pid=,ppid=,rss=,lstart=,comm='], capture_output=True, text=True, check=True, timeout=5)
        self.sdk_ps_raw = result.stdout
        self.sdk_process_baseline = sdk.unmanaged_processes(result.stdout, self.binding['sdk']['unmanagedProcessPaths'])
        self.sdk_preseed = sdk.filesystem_inventory(self.sdk_config['dataRootPath'])
        self.sdk_owned_paths = set(); self.sdk_previous = None

    def sdk_prepare(self):
        spec = self.binding['sdk']
        config_path = Path(self.a.state_root)/'support/config/containerization-helper.json'
        config_path.parent.mkdir(mode=0o700, parents=True)
        # Newly created parents must be private even if the caller's umask is permissive.
        for directory in (Path(self.a.state_root)/'support', config_path.parent): os.chmod(directory,0o700)
        (Path(self.a.state_root)/'support/run').mkdir(mode=0o700)
        raw, metadata = sdk.secure_read(spec['configInputPath'], limit=65536)
        require(metadata['sha256'] == spec['configSHA256'], 'SDK input changed before install')
        fd = os.open(config_path, os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd,'wb') as stream: stream.write(raw); stream.flush(); os.fsync(stream.fileno())
        self.sdk_config_path = str(config_path)
        atomic(self.evidence/'sdk-before-seed.json', {'nativeFilesystem':self.sdk_preseed,'unmanagedProcesses':self.sdk_process_baseline,'rawPS':self.sdk_ps_raw,'tart':self.sdk_tart_baseline})
        receipt = self.command([self.a.runtime_tool,'sdk-seed','--config',str(config_path),'--config-sha256',spec['configSHA256'],
                                '--layout',spec['layoutPath'],'--layout-sha256',spec['layoutSHA256'],'--reference',spec['reference'],
                                '--descriptor',spec['descriptor'],'--variant',spec['variant']], timeout=420)
        expected = {'kind':'hostwright.sdk-seed.v1','framework':'0.35.0','frameworkRevision':spec['frameworkRevision'],
                    'dataRootPath':self.sdk_config['dataRootPath'],'configurationSHA256':spec['configSHA256'],
                    'OCITreeSHA256':spec['layoutSHA256'],'reference':spec['reference'],'descriptorDigest':spec['descriptor'],'variantDigest':spec['variant']}
        require(all(receipt.get(k) == v for k,v in expected.items()), 'SDK seed receipt binding mismatch')
        require(not sdk.record_inventory(self.sdk_config['dataRootPath']), 'seed unexpectedly created runtime records')
        require(sdk.oci_tree_digest(spec['layoutPath']) == spec['layoutSHA256'], 'SDK OCI tree changed during seeding')
        for relative in ('state/records','state/logs','images/containers'):
            (Path(self.sdk_config['dataRootPath'])/relative).mkdir(mode=0o700,parents=True,exist_ok=True)
        os.chmod(Path(self.sdk_config['dataRootPath'])/'state',0o700)
        self.sdk_fs_baseline = sdk.filesystem_inventory(self.sdk_config['dataRootPath'])
        atomic(self.evidence/'sdk-after-seed.json', {'receipt':receipt,'nativeFilesystem':self.sdk_fs_baseline})

    def sdk_ready_baseline(self):
        spec = self.binding['sdk']; root = Path(self.sdk_config['dataRootPath'])
        current = sdk.filesystem_inventory(root)
        refs_path = root/'images/state.json'
        refs = sdk.decode(sdk.secure_read(refs_path,private=False)[0])
        require(set(refs) == {spec['reference'],self.sdk_config['initImageReference']}, 'unexpected SDK image reference after readiness')
        require(refs[spec['reference']]['digest'] == spec['descriptor'] and refs[self.sdk_config['initImageReference']]['digest'] == self.sdk_config['initImageDescriptorDigest'], 'SDK readiness image descriptors changed')
        old = {x['path']:x for x in self.sdk_fs_baseline['entries']}
        new = {x['path']:x for x in current['entries']}
        init_digests = [Path(path).name for path in spec['assetSHA256'] if '/blobs/sha256/' in path]
        allowed_files = {'images/content/blobs/sha256/'+x:x for x in init_digests}
        bootstrap = 'bootstrap/initfs-0.35.0-'+self.sdk_config['initImageVariantDigest'][7:]+'.ext4'
        allowed_dirs = {'state','state/records','state/logs','bootstrap','images/containers'}
        require(all(new.get(path) == entry for path,entry in old.items() if path != 'images/state.json'), 'seeded SDK native input changed during helper initialization')
        for path,entry in new.items():
            if path in old or path in allowed_dirs and entry['type'] == 'directory': continue
            if path in allowed_files:
                require(entry.get('sha256') == allowed_files[path], 'SDK init blob mismatch'); continue
            require(path == bootstrap and entry['type'] == 'file' and entry['size'] > 0, 'unexpected SDK initialization artifact: '+path)
        require(bootstrap in new and not sdk.record_inventory(root), 'SDK bootstrap/empty inventory unavailable')
        self.sdk_fs_baseline = current
        atomic(self.evidence/'sdk-before-lifecycle.json', {'nativeFilesystem':current,'imageReferences':refs,'bootstrapScope':'signed-helper-generated-initfs-from-bound-init-OCI','globalVZInventory':False})

    def sdk_preservation(self, final=False):
        current = sdk.filesystem_inventory(self.sdk_config['dataRootPath'], owned_prefixes=tuple(self.sdk_owned_paths))
        sdk.preserve_baseline(self.sdk_fs_baseline,current,tuple(self.sdk_owned_paths))
        if final:
            bound(self.binding['sdk']['inputArchivePath'],self.binding['sdk']['inputArchiveSHA256'])
            require(sdk.oci_tree_digest(self.binding['sdk']['layoutPath']) == self.binding['sdk']['layoutSHA256'], 'SDK OCI input changed before final verification')
            paths = {x['path'] for x in current['entries']}
            require(not any(path == prefix or path.startswith(prefix+'/') for path in paths for prefix in self.sdk_owned_paths), 'owned SDK filesystem resources retained after rm')
        raw = self.command(['/bin/ps','-ww','-axo','pid=,ppid=,rss=,lstart=,comm='],timeout=5,raw=True)
        sdk.preserve_unmanaged_processes(self.sdk_process_baseline,sdk.unmanaged_processes(raw,self.binding['sdk']['unmanagedProcessPaths']))
        sdk.preserve_tart(self.sdk_tart_baseline,stopped_vm(self.binding,subprocess.run)['rawInventory'])
        sdk.secure_read(self.sdk_config_path,limit=65536)
        bound(self.sdk_config_path,self.binding['sdk']['configSHA256'])
        atomic(self.evidence/f'sdk-preservation-{self.sequence:04d}.json', {'nativeFilesystem':current,'scope':'private-helper-filesystem-and-bound-unmanaged-host-processes-and-Tart','final':final,'rawPS':raw})
        return raw

    def observe_sdk(self, action):
        inventory = self.inventory()
        require(self.unmanaged(inventory) == self.baseline, 'unmanaged native SDK records changed')
        own = [x for x in inventory if x['project'] == self.a.project]
        running = action in ('up','restart','soak')
        require(len(own) == (0 if action == 'rm' else 1), 'owned SDK record count mismatch')
        database = Path(self.a.state_root)/'support/state/state.sqlite'
        with sqlite3.connect(database.as_uri()+'?mode=ro',uri=True) as connection:
            connection.row_factory = sqlite3.Row
            connection.execute('BEGIN')
            projects = [dict(x) for x in connection.execute('SELECT resource_uuid FROM projects WHERE name=?',(self.a.project,))]
            require(len(projects) <= 1, 'ambiguous SDK durable project identity')
            retained_uuid = getattr(self,'sdk_project_uuid',None)
            project_uuid = projects[0]['resource_uuid'] if projects else retained_uuid
            require(project_uuid is not None and (retained_uuid is None or project_uuid == retained_uuid), 'SDK durable project UUID missing/changed')
            try: sdk.uuid.UUID(project_uuid)
            except (ValueError,TypeError): raise Rejected('SDK durable project UUID invalid')
            require(action != 'rm' or retained_uuid is not None, 'SDK removal lacks previously validated project UUID')
            reservations = [dict(x) for x in connection.execute('SELECT * FROM scheduler_reservations WHERE project_uuid=?',(project_uuid,))]
            durable = [dict(x) for x in connection.execute('SELECT o.* FROM ownership_records o JOIN projects p ON p.id=o.project_id WHERE p.name=?',(self.a.project,))]
            ports = [dict(x) for x in connection.execute('SELECT * FROM network_port_reservations WHERE project_uuid=? AND lifecycle_state != ?',(project_uuid,'released'))]
        if action == 'rm': require(not durable, 'SDK durable ownership retained after rm')
        active = [x for x in reservations if x['status'] != 'released']
        require(len(active) == (1 if running else 0), 'SDK durable reservation retained/missing')
        require(not ports, 'SDK unsupported port reservation')
        if active: sdk.validate_sdk_reservation(active[0],self.a.cpus,self.a.memory_bytes,self.sdk_config['framework'])
        proof = None
        if own:
            resource = own[0]['id']; record = own[0]['nativeInventory']['record']
            require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}',resource), 'unsafe owned SDK resource identifier')
            token = sdk.digest(resource.encode())
            self.sdk_owned_paths.update(('state/records/'+token+'.json','state/logs/'+token+'.log','images/containers/'+resource))
            # Structural directories may appear, but their contents are still enumerated exactly.
            matches = [x for x in durable if x['resource_identifier'] == resource and x['runtime_adapter'] == 'AppleContainerizationRuntimeAdapter']
            require(len(matches) == 1, 'SDK exact durable ownership unavailable')
            row = matches[0]
            expected = {'resourceIdentifier':resource, 'resourceUUID':row['resource_uuid'],'projectResourceUUID':row['project_resource_uuid'],
                        'resourceGeneration':row['resource_generation'],'projectGeneration':row['project_generation'],
                        'providerGeneration':row['provider_generation'],'fencingToken':row['fencing_token']}
            require(all(record['mutationContext'].get(k) == v for k,v in expected.items() if k != 'resourceIdentifier'), 'SDK durable UUID/generation/fence mismatch')
            require(expected['projectResourceUUID'] == record['projectUUID'] == project_uuid, 'SDK qualification project UUID mismatch')
            self.sdk_project_uuid = project_uuid
            if running:
                proof = sdk.observe_owned(lambda argv:self.command(argv,timeout=5,raw=True),self.a.cli,self.a.manifest,str(database),
                                          self.sdk_config_path,self.binding['sdk']['configSHA256'],self.binding['health']['service'],expected,
                                          self.a.cpus,self.a.memory_bytes,self.binding['sdk']['capabilitySHA256'],self.binding['sdk']['nonce'],
                                          self.sdk_previous,require_new_instance=action in ('up','restart'))
                self.sdk_previous = proof['guestHTTPHashCgroupHeartbeat']
            else: require(record['phase'] in ('stopped','created','exited'), 'SDK record still running')
        if not running:
            status = self.command([self.a.cli,'status',self.a.manifest,'--state-db',str(database),'--runtime-provider','containerization','--output','json'])
            sdk.validate_stopped_status(status,self.binding['health']['service'],own[0]['id'] if own else None)
        raw_memory = self.sdk_preservation(final=action == 'rm')
        scope = sorted(set(self.binding['memory']['processPaths'])|{a['path'] for a in self.binding['artifacts']})
        selected = parse_process_memory(raw_memory,self.daemon.pid,scope,self.binding['memory']['rssBudgetBytes'],require_scope=False)
        require(not running or set(self.binding['memory']['processPaths']) <= {x['path'] for x in selected}, 'SDK required process measurement absent')
        identity = next(x['started'] for x in selected if x['pid'] == self.daemon.pid)
        require(self.checkpoint.setdefault('daemonStartIdentity',identity) == identity,'owned daemon start identity changed')
        atomic(self.evidence/f'observation-{self.sequence:04d}.json',{'action':action,'inventory':inventory,'reservations':reservations,'proof':proof,'observedAt':time.time()})
        atomic(self.evidence/f'memory-{self.sequence:04d}.json',{'processes':selected,'raw':raw_memory,'hostVMStat':self.command(['/usr/bin/vm_stat'],timeout=5)})
        self.checkpoint.setdefault('memorySamples',[]).append(selected)
        self.checkpoint['verifiedObservations'].append(action); self.save()

    def lifecycle(self, action):
        require(self.daemon is not None and self.daemon.poll() is None, 'owned daemon exited')
        self.guard_bindings()
        bound(self.a.manifest, self.a.manifest_sha256)
        base = [self.a.cli, action, self.a.manifest, '--runtime-provider', 'apple-cli' if self.provider == 'apple-container-cli' else 'containerization', '--output', 'json']
        plan = self.command(base+['--dry-run'])
        require(plan.get('schemaVersion') == 1 and plan.get('command') == action
                and plan.get('projectName') == self.a.project and plan.get('providerID') == self.provider
                and plan.get('manifestSHA256') == self.a.manifest_sha256 and HEX.fullmatch(plan.get('planSHA256', '')), 'preview binding mismatch')
        if action in ('up', 'restart'):
            decoded = [json.loads(n['desiredSpecificationJSONRedacted']) for n in plan['nodes'] if n.get('desiredSpecificationJSONRedacted')]
            desired = [x for x in decoded if 'cpuCount' in x]
            require(desired and all(x.get('cpuCount') == self.a.cpus and int(x.get('memoryBytes', 0)) == self.a.memory_bytes for x in desired), 'preview allocation mismatch')
        bound(self.a.manifest, self.a.manifest_sha256)
        result = self.command(base+['--confirm-plan', plan['planSHA256']])
        require(result.get('kind') == 'lifecycle-result' and result.get('status') == 'succeeded'
                and result.get('checkpoint') == 'verified' and result.get('planSHA256') == plan['planSHA256'], 'unverified lifecycle receipt')
        self.checkpoint['verifiedActions'].append(action)
        self.save()

    def observe(self, action):
        require(self.daemon is not None and self.daemon.poll() is None, 'owned daemon exited')
        self.guard_bindings()
        if self.provider != 'apple-container-cli': return self.observe_sdk(action)
        inventory = self.inventory()
        require(self.unmanaged(inventory) == self.baseline, 'unmanaged ownership/configuration inventory changed')
        own = [x for x in inventory if x['project'] == self.a.project]
        running = action in ('up', 'restart', 'soak')
        require((len(own) == 1 if running else len(own) == 0 if action == 'rm' else len(own) <= 1), 'owned inventory count mismatch')
        if running:
            require(own[0]['state'].lower() == 'running' and own[0]['cpuCount'] == self.a.cpus and own[0]['memoryBytes'] == self.a.memory_bytes, 'actual runtime allocation/state mismatch')
            health = self.binding['health']
            native = own[0]['nativeInventory']['configuration']
            require(any(p.get('hostAddress') == '127.0.0.1' and p.get('hostPort') == health['hostPort']
                        and p.get('containerPort') == health['containerPort'] and p.get('proto') == 'tcp'
                        for p in native.get('publishedPorts', [])), 'owned native port publication mismatch')
            with urllib.request.urlopen(self.a.health_url, timeout=self.remaining(5)) as response:
                require(response.status == 200, 'health status failed')
                body = response.read(1048577)
                require(len(body) <= 1048576, 'health body too large')
                validate_body(body, health)
        else:
            require(all(x['state'].lower() in ('stopped', 'created', 'exited') for x in own), 'owned resource still running')
        database = Path(self.a.state_root)/'support/state/state.sqlite'
        with sqlite3.connect(database.as_uri()+'?mode=ro', uri=True) as connection:
            connection.row_factory = sqlite3.Row
            ports = [dict(x) for x in connection.execute('SELECT * FROM network_port_reservations WHERE host_port=? AND lifecycle_state != ?',(self.binding['health']['hostPort'], 'released'))]
            rows = [dict(x) for x in connection.execute('SELECT r.* FROM scheduler_reservations r JOIN projects p ON p.resource_uuid=r.project_uuid WHERE p.name=?', (self.a.project,))]
        active = [x for x in rows if x['status'] != 'released']
        require(len(active) == (1 if running else 0), 'durable active reservation mismatch')
        if running:
            validate_owned_port(own[0], self.binding['health'], ports, self.provider)
        if active:
            require(active[0]['status'] == 'committed' and json.loads(active[0]['resource_vector_json']) == {'cpu': self.a.cpus, 'memory': self.a.memory_bytes}, 'reservation allocation vector mismatch')
        atomic(self.evidence/f'observation-{self.sequence:04d}.json', {'action': action, 'inventory': inventory, 'reservations': rows, 'observedAt': time.time()})
        status = self.command([self.a.cli, 'status', self.a.manifest, '--runtime-provider', 'apple-cli', '--output', 'json'])
        if running: validate_status_health(status, own[0], self.binding['health'])
        raw_memory = self.command(['/bin/ps', '-ww', '-axo', 'pid=,ppid=,rss=,lstart=,comm='], timeout=5)
        scope = sorted(set(self.binding['memory']['processPaths']) | {a['path'] for a in self.binding['artifacts']})
        selected = parse_process_memory(raw_memory, self.daemon.pid, scope, self.binding['memory']['rssBudgetBytes'], require_scope=False)
        require(not running or set(self.binding['memory']['processPaths']) <= {x['path'] for x in selected}, 'missing required runtime process measurement')
        daemon_identity = next(x['started'] for x in selected if x['pid'] == self.daemon.pid)
        require(self.checkpoint.setdefault('daemonStartIdentity', daemon_identity) == daemon_identity, 'owned daemon PID start identity changed')
        atomic(self.evidence/f'memory-{self.sequence:04d}.json', {'processes': selected, 'raw': raw_memory, 'sampledAt': time.time(), 'hostVMStat': self.command(['/usr/bin/vm_stat'], timeout=5)})
        self.checkpoint.setdefault('memorySamples', []).append(selected)
        self.checkpoint['verifiedObservations'].append(action)
        self.save()

    def unmanaged(self, inventory):
        result = []
        for container in inventory:
            if container['project'] == self.a.project:
                continue
            if self.provider == 'apple-container-cli':
                result.append({'id': container['id'], 'state': container['state'], 'configuration': container['nativeInventory']['configuration']})
            else:
                result.append(container)
        return result

    def cleanup(self):
        if self.daemon is not None:
            if self.daemon.poll() is None:
                self.daemon.send_signal(signal.SIGTERM)
                try: self.daemon.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    self.daemon.kill(); self.daemon.wait(timeout=10)
            self.checkpoint['daemonCleaned'] = self.daemon.poll() is not None
            self.daemon_output.close()
            self.save()

    def run(self):
        # Observation is read-only and precedes even private-root creation.
        # command() logs need evidence; pre-mutation observer runs without logging.
        if self.provider == 'apple-container-cli':
            raw = subprocess.run([self.a.runtime_tool, 'list', '--all', '--format', 'json'], env=self.env, capture_output=True, check=True)
            initial = decode(raw.stdout)
            require(not any(x['configuration'].get('labels', {}).get('dev.hostwright.project') == self.a.project for x in initial), 'ambiguous existing owned resources')
        else:
            self.sdk_initial_baseline()
        Path(self.a.state_root).mkdir(mode=0o700, parents=False)
        self.evidence.mkdir(mode=0o700, parents=False)
        self.save()
        try:
            if self.provider != 'apple-container-cli':
                self.guard_bindings()
                self.sdk_prepare()
            self.baseline = self.unmanaged(self.inventory())
            self.guard_bindings()
            self.command([self.a.cli, 'daemon', 'bootstrap-identities', '--output', 'json'])
            self.daemon_output = (self.evidence/'daemon.log').open('wb')
            self.daemon = subprocess.Popen([self.a.daemon, '--foreground', '--config', self.a.daemon_config], env=self.env, stdout=self.daemon_output, stderr=subprocess.STDOUT)
            self.checkpoint['daemonPID'] = self.daemon.pid; self.save()
            deadline = time.monotonic()+30
            while not (Path(self.a.state_root)/'support/run/control-v2.sock').exists():
                require(self.daemon.poll() is None and time.monotonic() < deadline, 'owned daemon failed readiness')
                time.sleep(.25)
            providers = self.command([self.a.cli, 'runtime', 'providers', '--json'])
            require(any(p.get('providerID') == self.provider and p.get('state') == 'available' for p in providers.get('providers', [])), 'authenticated exact provider unavailable')
            require(self.unmanaged(self.inventory()) == self.baseline, 'daemon changed baseline during readiness')
            if self.provider != 'apple-container-cli': self.sdk_ready_baseline()
            if self.a.mode == 'cycles':
                for cycle in range(10):
                    for action in ('up', 'restart', 'down', 'rm'):
                        self.lifecycle(action); self.observe(action)
                    self.checkpoint['cycles'] = cycle+1; self.save()
            else:
                self.lifecycle('up')
                origin = time.monotonic()
                samples = []
                tolerance = self.binding['soakSchedulingToleranceSeconds']
                for sample in range(61):
                    scheduled = origin+sample*30
                    require(time.monotonic() <= scheduled+tolerance, 'missed soak checkpoint; no catch-up allowed')
                    time.sleep(max(0, scheduled-time.monotonic()))
                    started = time.monotonic()
                    self.observation_deadline = scheduled+30
                    self.observe('soak')
                    finished = time.monotonic()
                    samples.append(timing_sample(scheduled, started, finished, tolerance, samples[-1] if samples else None))
                    self.observation_deadline = None
                    self.checkpoint.update(soakSamples=sample+1, soakElapsedSeconds=finished-origin, soakTiming=samples)
                    self.save()
                for action in ('down', 'rm'):
                    self.lifecycle(action); self.observe(action)
        except BaseException as error:
            self.checkpoint['failure'] = str(error)
            self.save()
            raise
        finally:
            self.cleanup()
        self.guard_bindings()
        self.checkpoint['sourceCleanBefore'] = True
        self.checkpoint['sourceCleanAfter'] = True
        self.guard_bindings()
        if self.provider != 'apple-container-cli': self.sdk_preservation(final=True)
        final_inventory = self.inventory()
        require(not any(x['project'] == self.a.project for x in final_inventory) and self.unmanaged(final_inventory) == self.baseline, 'final owned/unmanaged inventory mismatch')
        atomic(self.evidence/'final-inventory.json', final_inventory)
        self.guard_bindings()
        self.checkpoint['finalBindingsVerified'] = True
        self.checkpoint['status'] = 'passed' if completion(self.checkpoint, self.a.mode, self.receipts) else 'incomplete'
        self.save()
        require(self.checkpoint['status'] == 'passed', 'qualification incomplete')
        atomic(self.evidence/'complete.json', dict(self.checkpoint, harnessSHA256=sha(__file__), releaseQualification=False, stateRoot=self.a.state_root, manifestSHA256=self.a.manifest_sha256, runtimeToolSHA256=sha(self.a.runtime_tool)))

def completion(checkpoint, mode, receipts):
    actions = ['up', 'restart', 'down', 'rm'] * 10 if mode == 'cycles' else ['up', 'down', 'rm']
    observations = actions if mode == 'cycles' else ['soak'] * 61 + ['down', 'rm']
    timing = checkpoint.get('soakTiming', [])
    if mode == 'soak':
        if len(timing) != 61: return False
        try:
            for index, sample in enumerate(timing):
                timing_sample(sample['scheduled'], sample['started'], sample['finished'], checkpoint['schedulingTolerance'], timing[index-1] if index else None)
        except (Rejected, KeyError): return False
    vm_samples = checkpoint.get('vmIsolationSamples', [])
    if any(sample.get('vm', {}).get('State') != 'stopped' or sample.get('vm', {}).get('Running') is not False for sample in vm_samples): return False
    return bool(len(checkpoint.get('memorySamples', [])) == len(observations)
                and len(checkpoint.get('vmIsolationSamples', [])) >= len(observations)
                and checkpoint.get('releaseVerification') and checkpoint.get('verifiedActions') == actions and checkpoint.get('verifiedObservations') == observations
                and checkpoint.get('finalBindingsVerified') and checkpoint.get('memorySamples') and checkpoint.get('daemonCleaned') and receipts and all(r.get('exitCode') == 0 for r in receipts)
                and (checkpoint.get('cycles') == 10 if mode == 'cycles' else
                     checkpoint.get('soakSamples', 0) >= 61 and checkpoint.get('soakElapsedSeconds', 0) >= 1800))

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for name in ('binding', 'source-root', 'state-root', 'project', 'manifest', 'manifest-sha256', 'daemon-config', 'daemon-config-sha256', 'evidence', 'runtime-tool', 'cli', 'daemon'):
        parser.add_argument('--'+name, required=True)
    parser.add_argument('--health-url', help='Required for Apple lanes; SDK health is guest HTTP/SHA evidence through signed logs')
    parser.add_argument('--lane', choices=LANES, required=True)
    parser.add_argument('--mode', choices=('cycles', 'soak'), required=True)
    parser.add_argument('--cpus', type=int, required=True)
    parser.add_argument('--memory-bytes', type=int, required=True)
    args = parser.parse_args()
    require(sys.platform == 'darwin', 'real qualification requires macOS')
    require(args.cpus > 0 and args.memory_bytes > 0, 'positive allocation required')
    if LANES[args.lane][0] == 'apple-container-cli':
        require(args.health_url and re.fullmatch(r'http://127\.0\.0\.1:\d+/[^\s]*', args.health_url), 'explicit loopback health URL required')
    else: require(args.health_url is None, 'SDK health uses internal guest HTTP through signed logs; host health URL is unsupported')
    Harness(args, preflight(args)).run()

if __name__ == '__main__':
    try: main()
    except (Rejected, sdk.Rejected, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f'qualification rejected/incomplete: {error}', file=sys.stderr)
        sys.exit(1)
