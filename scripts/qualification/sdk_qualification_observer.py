#!/usr/bin/env python3
"""Nonshipped SDK qualification validators. No observer boolean grants a pass."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import time
import uuid

class Rejected(RuntimeError):
    pass

def require(condition, reason):
    if not condition:
        raise Rejected(reason)

def pairs(items):
    obj = {}
    for key, value in items:
        require(key not in obj, 'duplicate JSON field')
        obj[key] = value
    return obj

def decode(raw):
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(Rejected('nonfinite JSON')))

def positive(value):
    return type(value) is int and value > 0

def expected_sdk_admission(cpus, memory, framework):
    require(framework == '0.35.0', 'SDK admission framework mismatch')
    require(positive(cpus) and positive(memory), 'invalid SDK admission service allocation')
    require(cpus <= (1 << 63)-2 and memory <= (1 << 63)-1-134217728, 'SDK admission charge overflow')
    return {'cpu': cpus+1, 'memory': memory+134217728}

def validate_sdk_reservation(reservation, cpus, memory, framework):
    expected = expected_sdk_admission(cpus, memory, framework)
    actual = decode(reservation['resource_vector_json'])
    require(reservation.get('status') == 'committed' and isinstance(actual, dict)
            and all(type(value) is int for value in actual.values()) and actual == expected,
            'SDK reservation admission charge mismatch')
    return expected

def digest(raw):
    return hashlib.sha256(raw).hexdigest()

def secure_read(path, private=True, limit=1048576):
    path = Path(path)
    require(path.is_absolute() and path.resolve() == path, 'noncanonical SDK path')
    for parent in [path.parent, *path.parent.parents]:
        info = parent.lstat()
        require(stat.S_ISDIR(info.st_mode) and not info.st_mode & 0o022 and info.st_uid in (0, os.getuid()), 'unsafe SDK parent')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and 0 <= before.st_size <= limit, 'unsafe/oversized SDK file')
        require(before.st_uid in (0, os.getuid()) and not before.st_mode & 0o022, 'untrusted SDK file')
        if private:
            require(before.st_uid == os.getuid() and stat.S_IMODE(before.st_mode) == 0o600, 'SDK file is not private')
        chunks, remaining = [], limit + 1
        while remaining:
            chunk = os.read(fd, min(1048576, remaining))
            if not chunk: break
            chunks.append(chunk); remaining -= len(chunk)
        raw = b''.join(chunks)
        after = os.fstat(fd)
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        require(identity(before) == identity(after) and len(raw) == before.st_size, 'SDK file changed during read')
        require(identity(path.lstat()) == identity(after), 'SDK path replaced during read')
        return raw, {'sha256': digest(raw), 'size': len(raw), 'uid': before.st_uid, 'mode': stat.S_IMODE(before.st_mode)}
    finally:
        os.close(fd)

def record_inventory(data_root):
    root = Path(data_root)
    directory = root/'state/records'
    if not directory.exists():
        require(not directory.is_symlink(), 'unsafe record directory')
        return []
    info = directory.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700, 'unsafe record directory')
    result, identifiers = [], set()
    for path in sorted(directory.iterdir()):
        require(re.fullmatch(r'[a-f0-9]{64}\.json', path.name), 'unexpected native record name')
        raw, metadata = secure_read(path)
        record = decode(raw)
        identifier = record.get('resourceIdentifier', '')
        require(identifier and path.name == digest(identifier.encode())+'.json' and identifier not in identifiers, 'native record identifier mismatch/duplicate')
        identifiers.add(identifier)
        context = record.get('mutationContext', {})
        for key in ('resourceUUID', 'projectUUID'):
            try: uuid.UUID(record[key])
            except (ValueError, KeyError, TypeError): raise Rejected('invalid native ownership UUID')
        labels = pairs((entry['key'], entry['value']) for entry in record.get('labels', []))
        mappings = {'resourceUUID': ('resourceUUID', 'resource-uuid'), 'projectUUID': ('projectResourceUUID', 'project-uuid')}
        for key, (context_key, label) in mappings.items():
            require(record[key] == context.get(context_key) == labels.get('dev.hostwright.'+label), 'native ownership/context/label mismatch')
        require(context.get('providerID') == labels.get('dev.hostwright.provider-id') == 'apple-containerization', 'native provider mismatch')
        for key, label in [('resourceGeneration', 'resource-generation'), ('projectGeneration', 'project-generation'), ('providerGeneration', 'provider-generation')]:
            require(positive(context.get(key)) and str(context[key]) == labels.get('dev.hostwright.'+label), 'native generation mismatch')
        try: uuid.UUID(context['fencingToken'])
        except (ValueError, KeyError, TypeError): raise Rejected('invalid native fence')
        require(context['fencingToken'] == labels.get('dev.hostwright.fencing-token'), 'native fencing mismatch')
        cpus, memory = record.get('cpuCount'), record.get('memoryBytes')
        if cpus is None and memory is None:
            require(record.get('allocationVerified') is not True, 'legacy allocation claimed verified')
        else:
            require(positive(cpus) and cpus <= (2**63-1)//100000 and positive(memory) and memory <= 2**63-1, 'invalid native allocation')
        result.append({'path': str(path), 'metadata': metadata, 'record': record, 'scope': 'native-persisted-configuration'})
    return result

def filesystem_inventory(root, maximum_bytes=2**63-1, owned_prefixes=()):
    """Quiescent full content inventory; never silently omits a file or large disk."""
    root = Path(root)
    require(root.is_absolute() and root.resolve() == root, 'unsafe filesystem scope')
    if not root.exists(): return {'scope': str(root), 'exists': False, 'entries': []}
    info = root.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700, 'native root not private')
    entries = []
    def fail(error): raise Rejected('native inventory enumeration failed: '+str(error))
    for directory, dirs, files in os.walk(root, followlinks=False, onerror=fail):
        for name in sorted(dirs + files):
            path = Path(directory)/name
            info = path.lstat()
            require(not stat.S_ISLNK(info.st_mode), 'native inventory symlink')
            if stat.S_ISDIR(info.st_mode):
                require(info.st_uid == os.getuid() and not info.st_mode & 0o022, 'native directory untrusted inside private root')
                entries.append({'path': str(path.relative_to(root)), 'type': 'directory', 'mode': stat.S_IMODE(info.st_mode), 'uid': info.st_uid})
            else:
                relative = str(path.relative_to(root))
                if any(relative == prefix or relative.startswith(prefix+'/') for prefix in owned_prefixes):
                    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.getuid() and not info.st_mode & 0o022, 'unsafe owned native file')
                    metadata = {'size': info.st_size, 'uid': info.st_uid, 'mode': stat.S_IMODE(info.st_mode), 'ownedContentDeferred': True}
                else:
                    metadata = streaming_hash(path, maximum_bytes)
                entries.append({'path': str(path.relative_to(root)), 'type': 'file', **metadata})
    return {'scope': str(root), 'exists': True, 'entries': sorted(entries, key=lambda x: x['path'])}

def preserve_baseline(before, after, owned_prefixes=()):
    """Only exact run-owned relative resource directories/log files may change."""
    require(before['scope'] == after['scope'], 'native baseline scope changed')
    original = {x['path']: x for x in before['entries']}
    current = {x['path']: x for x in after['entries']}
    def owned(path): return any(path == prefix or path.startswith(prefix+'/') for prefix in owned_prefixes)
    require(all(current.get(path) == entry for path, entry in original.items() if not owned(path)), 'preexisting native artifact changed')
    require(all(path in original or owned(path) for path in current), 'unexplained new native artifact')

def stats_payload(raw):
    frames = [decode(line) for line in raw.splitlines() if line.strip()]
    require(frames and all(frame.get('schemaVersion') == 1 and type(frame.get('sequence')) is int and frame['sequence'] == i for i, frame in enumerate(frames))
            and frames[-1].get('stream') == 'control' and frames[-1].get('endOfStream') is True
            and frames[-1].get('payloadBase64') == '', 'invalid/incomplete stats stream sequence')
    payload = b''
    for frame in frames[:-1]:
        require(frame.get('schemaVersion') == 1 and frame.get('stream') == 'stdout' and frame.get('endOfStream') is False, 'invalid stats stream shape')
        try: chunk = base64.b64decode(frame['payloadBase64'], validate=True)
        except (ValueError, KeyError): raise Rejected('invalid stats payload encoding')
        require(len(chunk) <= 65536, 'oversized stats chunk')
        payload += chunk
        require(len(payload) <= 1048576, 'oversized stats payload')
    return decode(payload)

def validate_stats(value, resource, capability, memory):
    require(value.get('schemaVersion') == 1 and value.get('providerID') == 'apple-containerization'
            and value.get('resourceIdentifier') == resource and value.get('capabilitySHA256') == capability, 'stats identity/capability mismatch')
    require(value.get('memoryLimitBytes') == memory and positive(value.get('processCount'))
            and positive(value.get('cpuUsageMicroseconds')) and positive(value.get('memoryUsageBytes')), 'actual SDK usage unavailable/mismatched')
    return value

def validate_status(value, service, resource, cpus, memory):
    require(value.get('runtime', {}).get('observed') is True
            and value['runtime'].get('adapter') == 'AppleContainerizationRuntimeAdapter', 'disconnected/wrong-provider SDK status')
    require(not value.get('drift'), 'SDK observed drift')
    services = [x for x in value.get('services', []) if x.get('name') == service]
    require(len(services) == 1 and not services[0].get('instances'), 'ambiguous SDK service')
    observed = services[0].get('observed', {})
    require(observed.get('resourceIdentifier') == resource and observed.get('lifecycle') == 'running', 'SDK status identity/state mismatch')
    allocation = observed.get('allocation', {})
    require(type(allocation.get('cpuCount')) is int and type(allocation.get('memoryBytes')) is int
            and allocation['cpuCount'] == cpus and allocation['memoryBytes'] == memory, 'actual SDK allocation missing/mismatched')
    return observed

def validate_heartbeat(raw, nonce, cpus, memory, previous=None):
    candidates = []
    for line in raw.splitlines():
        if not line.startswith('HWQSDK '): continue
        value = decode(line[7:])
        require(value.get('nonce') == nonce, 'stale or unrelated SDK heartbeat')
        require(positive(value.get('sequence')) and positive(value.get('monotonicNS')), 'invalid SDK heartbeat sequence/time')
        expected = digest((nonce+':'+str(value['sequence'])).encode())
        require(value.get('httpStatus') == 200 and value.get('bodySHA256') == expected and value.get('responseSHA256') == expected, 'guest HTTP/SHA operation failed')
        require(value.get('cpuMax') == f'{cpus*100000} 100000' and value.get('memoryMax') == str(memory), 'actual guest cgroup quota mismatch')
        if candidates:
            require(value['sequence'] > candidates[-1]['sequence'] and value['monotonicNS'] > candidates[-1]['monotonicNS'], 'heartbeat regressed')
        candidates.append(value)
    require(candidates, 'SDK heartbeat unavailable')
    final = candidates[-1]
    if previous:
        require(final['sequence'] > previous['sequence'], 'SDK heartbeat did not advance')
        require(final['monotonicNS'] > previous['monotonicNS'], 'SDK heartbeat clock regressed')
    return final

def workload_program(nonce):
    require(re.fullmatch(r'[a-f0-9]{32,128}', nonce), 'invalid qualification nonce')
    program = '''import hashlib,http.server,json,pathlib,threading,time,urllib.request,secrets
nonce=NONCE
instanceNonce=secrets.token_hex(32)
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  body=self.path.removeprefix('/').encode(); result=hashlib.sha256(body).hexdigest().encode()
  self.send_response(200); self.end_headers(); self.wfile.write(result)
 def log_message(self,*args): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',8080),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
sequence=0
while True:
 sequence+=1; material=nonce+':'+str(sequence); expected=hashlib.sha256(material.encode()).hexdigest()
 with urllib.request.urlopen('http://127.0.0.1:8080/'+material,timeout=2) as response:
  actual=response.read(1024).decode(); status=response.status
 if status!=200 or actual!=expected: raise RuntimeError('HTTP/SHA self-check failed')
 print('HWQSDK '+json.dumps(dict(nonce=nonce,instanceNonce=instanceNonce,sequence=sequence,monotonicNS=time.monotonic_ns(),httpStatus=status,bodySHA256=expected,responseSHA256=actual,cpuMax=pathlib.Path('/sys/fs/cgroup/cpu.max').read_text().strip(),memoryMax=pathlib.Path('/sys/fs/cgroup/memory.max').read_text().strip()),sort_keys=True),flush=True)
 time.sleep(1)
'''.replace('NONCE', repr(nonce))
    return 'exec(' + repr(program) + ')'


def validate_manifest(manifest, service_name, nonce, cpus, memory, reference):
    require(manifest.get('version') == 3 and len(manifest.get('services', {})) == 1, 'SDK requires one exact Manifest3 service')
    service = manifest['services'][service_name]
    require(service.get('image') == reference and service.get('command') == ['python3', '-u', '-c', workload_program(nonce)], 'SDK image/workload program binding mismatch')
    for key in ('ports', 'publishedSockets', 'mounts', 'healthcheck', 'healthCheck', 'probes', 'hooks', 'entrypoint', 'user', 'workingDirectory', 'init'):
        require(not service.get(key), 'unsupported SDK workload option: '+key)
    limits = service.get('resources', {}).get('limits', {})
    require(positive(limits.get('cpus')) and limits.get('cpus') == cpus and limits.get('memory') == str(memory)+'B', 'SDK admitted workload limits mismatch')
    requests = service.get('resources', {}).get('requests', {})
    require(requests == limits and set(limits) == {'cpus', 'memory'} and type(requests.get('cpus')) is int,
            'SDK qualification requires equal CPU/memory requests and limits')
    expected_sdk_admission(cpus, memory, '0.35.0')
    return service


def unmanaged_processes(raw, bound_paths):
    result = []
    for line in raw.splitlines():
        fields = line.split(None, 8)
        require(len(fields) == 9 and fields[0].isdigit() and fields[1].isdigit() and fields[2].isdigit(), 'invalid host process baseline')
        path = fields[8]
        if path in bound_paths:
            result.append({'pid': int(fields[0]), 'ppid': int(fields[1]), 'started': ' '.join(fields[3:8]), 'path': path})
    return sorted(result, key=lambda row: (row['path'], row['pid']))

def preserve_unmanaged_processes(before, after):
    require(before == after, 'preexisting unmanaged workload process identity changed')

def preserve_tart(before, after):
    def keyed(rows):
        result = {}
        for row in rows:
            require(isinstance(row, dict) and isinstance(row.get('Name'), str) and isinstance(row.get('Source'), str), 'invalid Tart baseline')
            key = (row['Source'], row['Name'])
            require(key not in result, 'duplicate Tart identity')
            result[key] = row
        return result
    require(keyed(before) == keyed(after), 'unmanaged Tart inventory changed')

def observe_owned(execute, cli, manifest, database, config_path, config_digest, service, expected_ownership, cpus, memory, capability, nonce, previous=None, require_new_instance=False):
    """Execute actual signed commands through the caller's receipt/provenance guard.

    execute(argv) must return raw stdout and reject nonzero exit. The caller owns
    root-protected staged artifact/source verification and the absolute deadline.
    This returns captured facts; it does not authorize or declare qualification.
    """
    config_raw, config_metadata = secure_read(config_path, limit=65536)
    require(config_metadata['sha256'] == config_digest, 'SDK configuration bytes changed')
    config = decode(config_raw)
    require(config.get('schema') == 1 and config.get('framework') == '0.35.0', 'SDK config framework/schema mismatch')
    records = record_inventory(config['dataRootPath'])
    own = [x for x in records if x['record']['resourceIdentifier'] == expected_ownership['resourceIdentifier']]
    require(len(own) == 1, 'exact owned SDK record unavailable')
    record = own[0]['record']; context = record['mutationContext']
    for key in ('resourceUUID', 'projectResourceUUID', 'resourceGeneration', 'projectGeneration', 'providerGeneration', 'fencingToken'):
        require(context.get(key) == expected_ownership.get(key), 'SDK durable owned identity/generation/fence changed')
    require(record.get('phase') == 'running', 'owned SDK persisted phase is not running')
    require(record.get('allocationVerified') is True and record.get('cpuCount') == cpus and record.get('memoryBytes') == memory,
            'owned SDK configuration is not verified/matching')
    resource = expected_ownership['resourceIdentifier']
    common = ['--state-db', database, '--runtime-provider', 'containerization']
    status_raw = execute([cli, 'status', manifest, *common, '--output', 'json'])
    observed = validate_status(decode(status_raw), service, resource, cpus, memory)
    deadline = time.monotonic()+5
    while True:
        logs_raw = execute([cli, 'logs', service, manifest, *common, '--tail', '100'])
        try:
            heartbeat = current_heartbeat(logs_raw, nonce, cpus, memory, previous, require_new_instance)
            break
        except Rejected as error:
            require(str(error) in ('current SDK heartbeat unavailable','restart reused old guest instance','SDK heartbeat did not advance') and time.monotonic() < deadline, str(error))
            time.sleep(min(0.2,max(0,deadline-time.monotonic())))
    stats_raw = execute([cli, 'stats', service, '--manifest', manifest, *common, '--timeout', '5', '--json'])
    stats = validate_stats(stats_payload(stats_raw), resource, capability, memory)
    log_path = Path(config['dataRootPath'])/'state/logs'/(digest(resource.encode())+'.log')
    native_log, log_metadata = secure_read(log_path, limit=8*1024*1024)
    native_heartbeat = current_heartbeat(native_log.decode(), nonce, cpus, memory)
    require(native_heartbeat['instanceNonce'] == heartbeat['instanceNonce'] and native_heartbeat['sequence'] >= heartbeat['sequence'], 'signed log heartbeat absent from native owned log')
    final_records = record_inventory(config['dataRootPath'])
    final_own = [x for x in final_records if x['record']['resourceIdentifier'] == resource]
    require(len(final_own) == 1 and final_own[0]['record'] == record, 'owned SDK record changed during observation')
    require(secure_read(config_path, limit=65536)[1] == config_metadata, 'SDK config changed during observation')
    return {'scope': 'per-owned-live-SDK-readback-and-native-persisted-configuration', 'configuration': config_metadata,
            'ownedRecord': own[0], 'nativeInventory': records, 'observedStatus': observed, 'actualStats': stats,
            'guestHTTPHashCgroupHeartbeat': heartbeat, 'nativeLog': log_metadata,
            'rawStatusSHA256': digest(status_raw.encode()), 'rawStatsSHA256': digest(stats_raw.encode()), 'rawLogsSHA256': digest(logs_raw.encode())}


def streaming_hash(path, maximum_bytes=2**63-1):
    """Hash quiescent native files through a bounded buffer, including large disks."""
    path = Path(path)
    require(path.is_absolute() and path.resolve() == path, 'unsafe streaming path')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_uid in (0, os.getuid()) and not before.st_mode & 0o022 and before.st_size <= maximum_bytes, 'unsafe streaming file')
        h = hashlib.sha256(); size = 0
        while True:
            chunk = os.read(fd, 1048576)
            if not chunk: break
            h.update(chunk); size += len(chunk)
        identity = lambda x: (x.st_dev,x.st_ino,x.st_size,x.st_mtime_ns,x.st_ctime_ns)
        require(identity(before) == identity(os.fstat(fd)) == identity(path.lstat()) and size == before.st_size, 'native file changed while hashing')
        return {'sha256': h.hexdigest(), 'size': size, 'uid': before.st_uid, 'mode': stat.S_IMODE(before.st_mode)}
    finally: os.close(fd)


def current_heartbeat(raw, nonce, cpus, memory, previous=None, require_new_instance=False):
    lines = [line for line in raw.splitlines() if line.startswith('HWQSDK ')]
    require(lines, 'current SDK heartbeat unavailable')
    values = [decode(line[7:]) for line in lines]
    require(all(x.get('nonce') == nonce and re.fullmatch(r'[a-f0-9]{64}', x.get('instanceNonce','')) for x in values), 'old nonce or missing guest instance proof')
    instance = values[-1]['instanceNonce']
    start = len(values)-1
    while start and values[start-1]['instanceNonce'] == instance: start -= 1
    require(not any(x['instanceNonce'] == instance for x in values[:start]), 'guest instance replay')
    if previous:
        if require_new_instance: require(instance != previous['instanceNonce'], 'restart reused old guest instance')
        else: require(instance == previous['instanceNonce'], 'guest instance changed without lifecycle restart')
    prior = previous if previous and previous['instanceNonce'] == instance else None
    return validate_heartbeat('\n'.join(lines[start:]), nonce, cpus, memory, prior)


def oci_tree_digest(root):
    inventory = filesystem_inventory(root)
    files = [x for x in inventory['entries'] if x['type'] == 'file']
    require(inventory['exists'] and 0 < len(files) <= 10000, 'OCI layout unavailable/oversized')
    rows = []
    for entry in files:
        relative = entry['path']
        if relative.startswith('blobs/sha256/'):
            require(relative == 'blobs/sha256/'+entry['sha256'], 'OCI blob name/content mismatch')
        rows.append(relative+'\0'+entry['sha256']+'\n')
    return digest(''.join(sorted(rows)).encode())


def validate_stopped_status(value, service, resource=None):
    require(value.get('runtime',{}).get('observed') is True and value['runtime'].get('adapter') == 'AppleContainerizationRuntimeAdapter', 'disconnected SDK stop/remove status')
    services = [x for x in value.get('services',[]) if x.get('name') == service]
    require(len(services) == 1 and not services[0].get('instances'), 'ambiguous SDK stopped service')
    observed = services[0].get('observed')
    if resource is None:
        require(observed is None, 'SDK removed resource still observed')
    else:
        require(isinstance(observed,dict) and observed.get('resourceIdentifier') == resource and observed.get('lifecycle') in ('stopped','created','exited'), 'SDK stopped status identity/state mismatch')
    return observed
