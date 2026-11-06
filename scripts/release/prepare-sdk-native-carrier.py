#!/usr/bin/env python3
"""Recover a selected SDK closure from an authenticated original native carrier."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import posixpath
import re
import shutil
import tarfile

HERE = Path(__file__).resolve().parent
KIND = "hostwright.sdk-native-carrier-recovery.v1"
MEMBERS_KIND = "hostwright.sdk-native-carrier-members.v1"
ORIGINAL_SDK_ROOT = "/workspace/runtime-build/swift-sdks/"


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


N = module("native_reuse_authentication", "verify-native-reuse.py")
S = module("sdk_compile_comparison", "verify-sdk-reuse.py")
P = module("prepared_sdk_sources", "prepare-reviewed-native-sources.py")
V = P.V


def record(root, name, data):
    return N.I.record(root, name, data)


def sdk_identity(name, prefix=ORIGINAL_SDK_ROOT):
    if not isinstance(name, str) or not name.startswith(prefix):
        return None
    relative = name[len(prefix):]
    match = re.fullmatch(r"(.+\.a)\(([^()]+)\)", relative)
    filename, member = match.groups() if match else (relative, None)
    V.path(filename)
    V.require(filename.split('/')[0].endswith('.artifactbundle'), "SDK member is outside its artifact bundle")
    if member is not None:
        V.path(member)
    else:
        V.require(filename.endswith('.o'), "unsupported standalone SDK member")
    return relative


def archive_members(archive, wanted):
    """Read only selected real archive members; never extract SDK symlinks."""
    paths = {}
    for identity in wanted:
        match = re.fullmatch(r"(.+\.a)\(([^()]+)\)", identity)
        filename, member = match.groups() if match else (identity, None)
        paths.setdefault(filename, set()).add(member)
    result = set()
    with tarfile.open(archive, 'r:gz') as bundle:
        entries = {}
        expanded = 0
        for count, item in enumerate(bundle, 1):
            V.require(count <= 100000 and item.size <= 2 * 1024**3, "oversized SDK archive")
            name = V.path(item.name.rstrip('/'))
            V.require(name not in entries, "duplicate SDK archive path")
            entries[name] = item
            expanded += item.size
            V.require(expanded <= 8 * 1024**3, "oversized expanded SDK archive")
        def resolve(name):
            original_bundle = name.split('/')[0]
            for _ in range(32):
                parts = name.split('/')
                for index in range(1, len(parts) + 1):
                    prefix = '/'.join(parts[:index])
                    entry = entries.get(prefix)
                    if entry is not None and entry.issym():
                        V.require(not entry.linkname.startswith('/') and '\\' not in entry.linkname,
                                  "external SDK archive symlink")
                        name = posixpath.normpath(posixpath.join(posixpath.dirname(prefix), entry.linkname, *parts[index:]))
                        V.path(name)
                        V.require(name.split('/')[0] == original_bundle, "SDK archive symlink escapes its bundle")
                        break
                else:
                    V.require(name in entries and entries[name].isfile(), "selected SDK member is not a regular archive file")
                    return entries[name]
            raise ValueError("cyclic SDK archive symlink")
        for name in paths:
            item = resolve(name)
            data = bundle.extractfile(item).read()
            V.require(len(data) == item.size, "truncated SDK archive member")
            if paths[name] == {None}:
                V.elf(data, True)
                result.add((name, V.digest(data)))
            else:
                V.require(None not in paths[name], "conflicting SDK member kind")
                for member, _offset, raw in V.archive_entries(data):
                    if member in paths[name]:
                        V.elf(raw, True)
                        result.add((name + '(' + member + ')', V.digest(raw)))
    V.require(set(wanted) <= {name for name, _sha in result}, "selected SDK member is absent from original archive")
    return result


def select_rows(native, source_map, archive, fetch, header_candidates=None):
    V.require(isinstance(source_map, list) and source_map, "missing original source map")
    by_hash = {}
    for row in source_map:
        by_hash.setdefault(row['objectSHA256'], []).append(row)
    selected, identities = {}, set()
    for link in native['oci']['links']:
        for actual in link['selectedInputs']:
            identity = sdk_identity(actual['mapInput'])
            if identity is None:
                continue
            candidates = []
            for row in by_hash.get(actual['objectSHA256'], []):
                joined = N.rebase(row, 'evidence/source-map/')
                joined.pop('mapInput', None)
                joined['sourceFiles'] = sorted(joined['sourceFiles'], key=lambda item: (item['project'], item['path']))
                observed = {key: value for key, value in actual.items() if key not in ('file', 'mapInput', 'archiveOffset', 'member')}
                if joined == observed:
                    candidates.append(row)
            V.require(candidates and len({V.canonical(row) for row in candidates}) == 1,
                      "original SDK member has no unambiguous original source attribution")
            row = candidates[0]
            V.require(all(item['project'].startswith('swift-sdk/') for item in V.native_source_files(row, fetch)),
                      "original SDK object has non-SDK source attribution")
            selected[V.canonical(row)] = row
            identities.add((identity, row['objectSHA256']))
    V.require(identities, "original native carrier has no selected SDK members")
    actual_members = archive_members(archive, {name for name, _sha in identities})
    V.require(identities <= actual_members, "original selected SDK object differs from actual SDK archive")
    header_rows = []
    for row in source_map if header_candidates is None else header_candidates:
        if V.canonical(row) not in selected and any(item['project'].startswith('swift-sdk/')
                                                  for item in V.native_source_files(row, fetch)):
            header_rows.append(row)
    return list(selected.values()), header_rows, [dict(identity=name, objectSHA256=sha) for name, sha in sorted(identities)]


def validate_sdk_chain(producer, reuse, native_producer, archive_sha, comparison):
    V.require(set(producer) == {'commit', 'runID', 'attempt'} and re.fullmatch('[a-f0-9]{40}', producer['commit'])
              and type(producer['runID']) is int and producer['runID'] > 0
              and type(producer['attempt']) is int and producer['attempt'] > 0, "invalid original SDK producer")
    V.require(reuse['kind'] == S.KIND and reuse['status'] == 'compatible-not-release-qualified'
              and reuse['producer'] == {'commit': producer['commit']} and reuse['sourceCommit'] == native_producer['commit']
              and reuse['sourceInventory']['sdkArchiveSHA256'] == archive_sha
              and reuse['compileInputs'] == comparison['compileInputs'], "original SDK producer/archive/compile chain changed")


def header_inventories(prepared, catalog, rows, map_root):
    projects = P.prepared_sdk_projects(prepared, catalog)
    commits = {row['identity']: row['commit'] for row in projects}
    declarations = {row['identity']: row for row in catalog['sdk']}
    _, selected = P.selected_sources(rows, map_root)
    V.require({name for name in selected if name.startswith('swift-sdk/')} <= set(commits),
              "selected SDK compiler source project is missing")
    result = {}
    for project in projects:
        leaves = V.source_project(project, lambda name: N.safe(prepared, name).read_bytes(), commits)
        for name, sha in selected.get(project['identity'], {}).items():
            P.in_scope(declarations[project['identity']], name)
            V.require(name in leaves and leaves[name]['gitMode'] != '120000' and leaves[name]['sha256'] == sha,
                      "SDK compiler source differs from verified patched project")
        destination = project['identity'][len('swift-sdk/'):]
        result['header-sources/' + destination + '/source-inventory.json'] = V.canonical(list(leaves.values()))
    return result


def transport_checksums(root, proof):
    V.require('recovery.json' not in proof['files'] and 'checksums.sha256' not in proof['files'],
              "SDK transport files cannot be self-declared recovery inputs")
    entries = dict(proof['files'], **{'recovery.json': N.file_digest(N.safe(root, 'recovery.json'))})
    for name, sha in entries.items():
        V.path(name)
        V.require(re.fullmatch('[a-f0-9]{64}', sha), "invalid SDK transport file digest")
    return ''.join(sha + '  ' + name + '\n' for name, sha in sorted(entries.items())).encode()


def verify_transport(root, proof):
    V.require(N.safe(root, 'checksums.sha256').read_bytes() == transport_checksums(root, proof),
              "SDK transport checksum coverage or ordering changed")
    actual = set()
    for path in root.rglob('*'):
        V.require(not path.is_symlink() and (path.is_dir() or path.is_file()), "unsafe SDK recovery member")
        if path.is_file():
            actual.add(path.relative_to(root).as_posix())
    V.require(actual == set(proof['files']) | {'recovery.json', 'checksums.sha256'}, "SDK recovery file coverage changed")
    for name, sha in proof['files'].items():
        V.require(N.file_digest(N.safe(root, name)) == sha, "SDK recovery member bytes changed")


def prepare(carrier, resolution_path, repo, source, output):
    V.require(carrier.is_dir() and not carrier.is_symlink() and output.is_absolute()
              and output.parent.is_dir() and not output.exists() and not output.is_symlink()
              and not output.resolve().is_relative_to(carrier.resolve()), "unsafe SDK carrier recovery roots")
    resolution = json.loads(resolution_path.read_bytes())
    producer = resolution['producer']
    V.require(N.R.select(resolution['originalRun'], resolution['originalJobs'], resolution['originalArtifacts'],
                        producer['runID'], producer['attempt']) == resolution, "original carrier resolution changed")
    output.mkdir(mode=0o700)
    subjects = {key: N.authenticate_subject(carrier, name, producer, output, key) for key, name in N.SUBJECTS.items()}
    checksums = N.verify_carrier(carrier)
    native = json.loads(N.safe(carrier, N.SUBJECTS['nativeManifest']).read_bytes())
    V.require(native['sourceCommit'] == producer['commit'] and native['status'] == 'prepared-not-release-qualified',
              "original native producer claim changed")
    sdk_producer = json.loads(N.safe(carrier, 'evidence/sdk-producer.json').read_bytes())
    reuse = json.loads(N.safe(carrier, 'evidence/sdk-reuse.json').read_bytes())
    comparison = S.compare(repo, sdk_producer['commit'], source)
    validate_sdk_chain(sdk_producer, reuse, producer, checksums['evidence/swift-static-sdk.tar.gz'], comparison)
    for name in ('sdk-producer.json', 'sdk-reuse.json', 'swift-static-sdk.tar.gz'):
        shutil.copyfile(N.safe(carrier, 'evidence/' + name), output / name)
    archive = output / 'swift-static-sdk.tar.gz'
    (output / 'swift-static-sdk.sha256').write_text(N.file_digest(archive) + '  swift-static-sdk.tar.gz\n')
    source_map = json.loads(N.safe(carrier, N.SUBJECTS['sourceMap']).read_bytes())
    map_root = carrier / 'evidence/source-map'
    sdk_rows, headers, members = select_rows(native, source_map, archive, lambda name: N.safe(map_root, name).read_bytes())
    retained = P.retain_source_map(sdk_rows + headers, map_root, output)
    mapping = dict(kind='hostwright.sdk-object-sources.v1', status='partial-not-release-qualified',
                   sourceMap=retained[:len(sdk_rows)], headerInputs=retained[len(sdk_rows):], unresolved=[],
                   carrierMembers=dict(kind=MEMBERS_KIND, sdkArchiveSHA256=N.file_digest(archive), members=members))
    record(output, 'sdk-object-sources.json', V.canonical(mapping))
    projects = [row for row in native['sourceProjects'] if row['identity'].startswith('swift-sdk/')]
    prepared = output / 'prepared-sdk'
    prepared.mkdir(mode=0o700)
    retained_projects = P.retain_prepared_projects(projects, carrier / 'runtime-native-fragment', prepared, 'original')
    record(prepared, 'projects.json', V.canonical(retained_projects))
    pins = json.loads(S._blob(repo, source, S.PINS))
    expected_pins = {'swift-sdk/' + row['destination']: row['commit'] for row in pins}
    V.require(all(expected_pins.get(row['identity']) == row['commit'] for row in projects), "prepared SDK source differs from current pins")
    catalog = json.loads(S._blob(repo, source, 'scripts/release/runtime-native-source-licenses.json'))
    for name, data in header_inventories(prepared, catalog, retained, output).items():
        record(output, name, data)
    proof = dict(kind=KIND, status='authenticated-selected-sdk-not-release-qualified', preparedForSource=source,
                 carrierProducer=producer, artifact=resolution['artifact'], subjects=subjects,
                 resolution=record(output, 'resolution.json', V.canonical(resolution)),
                 originalSDKProducer=sdk_producer, compileComparison=comparison,
                 scope=dict(selectedSDKRows=len(sdk_rows), selectedMemberBindings=len(members),
                            headerOnlyRows=len(headers), preparedSDKProjects=len(projects), fullSDKInventoryAvailable=False))
    proof['files'] = {item.relative_to(output).as_posix(): N.file_digest(item)
                      for item in output.rglob('*') if item.is_file()}
    record(output, 'recovery.json', V.canonical(proof))
    record(output, 'checksums.sha256', transport_checksums(output, proof))
    return proof


def verify(root, repo, source):
    proof = json.loads(N.safe(root, 'recovery.json').read_bytes())
    V.require(proof['kind'] == KIND and proof['status'] == 'authenticated-selected-sdk-not-release-qualified'
              and proof['preparedForSource'] == source, "SDK recovery source/type mismatch")
    verify_transport(root, proof)
    fetch = lambda name: N.safe(root, name).read_bytes()
    resolution = json.loads(V.bound(proof['resolution'], fetch))
    producer = proof['carrierProducer']
    V.require(N.R.select(resolution['originalRun'], resolution['originalJobs'], resolution['originalArtifacts'],
                        producer['runID'], producer['attempt']) == resolution and resolution['producer'] == producer
              and resolution['artifact'] == proof['artifact'], "SDK carrier resolution mismatch")
    V.require(set(proof['subjects']) == set(N.SUBJECTS), "SDK original subject coverage mismatch")
    subjects = {}
    for key, records in proof['subjects'].items():
        subjects[key] = V.bound(records['subject'], fetch)
        V.bound(records['bundle'], fetch)
        V.bound(records['verification'], fetch)
        N.verify_attestation(N.safe(root, records['subject']['path']), N.safe(root, records['bundle']['path']), producer)
    checksums = N.checksums(subjects['checksums'])
    for key in ('nativeManifest', 'sourceMap'):
        V.require(checksums[N.SUBJECTS[key]] == V.digest(subjects[key]), "SDK original subjects conflict")
    for name in ('sdk-producer.json', 'sdk-reuse.json', 'swift-static-sdk.tar.gz'):
        V.require(checksums['evidence/' + name] == N.file_digest(N.safe(root, name)), "SDK original carrier file changed")
    native = json.loads(subjects['nativeManifest'])
    V.require(native['sourceCommit'] == producer['commit'], "SDK original native source claim changed")
    sdk_producer = json.loads(fetch('sdk-producer.json'))
    comparison = S.compare(repo, sdk_producer['commit'], source)
    V.require(proof['compileComparison'] == comparison and proof['originalSDKProducer'] == sdk_producer, "SDK current compile comparison changed")
    validate_sdk_chain(sdk_producer, json.loads(fetch('sdk-reuse.json')), producer,
                       N.file_digest(root / 'swift-static-sdk.tar.gz'), comparison)
    # Retained source-map documents keep their original bytes; only bound paths are rebased.
    original_fetch = lambda name: fetch('source-map/' + name)
    original_map = json.loads(subjects['sourceMap'])
    retained_map = json.loads(fetch('sdk-object-sources.json'))
    original_by_row = {V.canonical(N.rebase(row, 'source-map/')): row for row in original_map}
    header_candidates = []
    for row in retained_map['headerInputs']:
        V.require(V.canonical(row) in original_by_row, "header-only input is not an original authenticated row")
        header_candidates.append(original_by_row[V.canonical(row)])
    V.require(len({V.canonical(row) for row in header_candidates}) == len(header_candidates), "duplicate header-only input")
    rows, headers, members = select_rows(native, original_map, root / 'swift-static-sdk.tar.gz', original_fetch, header_candidates)
    expected_map = dict(kind='hostwright.sdk-object-sources.v1', status='partial-not-release-qualified', unresolved=[],
                        sourceMap=N.rebase(rows, 'source-map/'), headerInputs=N.rebase(headers, 'source-map/'),
                        carrierMembers=dict(kind=MEMBERS_KIND, sdkArchiveSHA256=N.file_digest(root / 'swift-static-sdk.tar.gz'), members=members))
    V.require(retained_map == expected_map, "SDK subset no longer matches original attribution")
    projects = [row for row in native['sourceProjects'] if row['identity'].startswith('swift-sdk/')]
    V.require(json.loads(fetch('prepared-sdk/projects.json')) == N.rebase(projects, 'original/'), "original prepared SDK projects changed")
    pins = json.loads(S._blob(repo, source, S.PINS))
    expected_pins = {'swift-sdk/' + row['destination']: row['commit'] for row in pins}
    V.require(all(expected_pins.get(row['identity']) == row['commit'] for row in projects), "SDK source pins changed")
    catalog = json.loads(S._blob(repo, source, 'scripts/release/runtime-native-source-licenses.json'))
    prepared = root / 'prepared-sdk'
    for name, data in header_inventories(prepared, catalog, retained_map['sourceMap'] + retained_map['headerInputs'], root).items():
        V.require(fetch(name) == data, "derived SDK header inventory changed")
    V.require(proof['scope'] == dict(selectedSDKRows=len(rows), selectedMemberBindings=len(members), headerOnlyRows=len(headers),
                                   preparedSDKProjects=len(projects), fullSDKInventoryAvailable=False), "SDK partial scope changed")
    return proof


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--carrier', type=Path)
    parser.add_argument('--resolution', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--verify', type=Path)
    parser.add_argument('--repo-root', type=Path, required=True)
    parser.add_argument('--source-commit', required=True)
    args = parser.parse_args()
    os.umask(0o077)
    if args.verify:
        V.require(not any((args.carrier, args.resolution, args.output)), "verification cannot prepare a carrier")
        result = verify(args.verify, args.repo_root, args.source_commit)
    else:
        V.require(all((args.carrier, args.resolution, args.output)), "missing SDK carrier preparation inputs")
        result = prepare(args.carrier, args.resolution, args.repo_root, args.source_commit, args.output)
    print(json.dumps(dict(status=result['status'], preparedForSource=result['preparedForSource'], scope=result['scope']), sort_keys=True))
