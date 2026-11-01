#!/usr/bin/env python3
"""Resolve and download one immutable, successful native producer artifact."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import time
import urllib.parse
import urllib.request
import zipfile

REPO = 'hostwright/hostwright'
WORKFLOW = '.github/workflows/runtime-ingredients.yml'
JOB = 'Rebuild pinned kernel and vminit ingredients'
MAX_ZIP = 8 * 1024**3
MAX_EXPANDED = 20 * 1024**3
MAX_MEMBERS = 100000
DISK_RESERVE = 4 * 1024**3


def positive(value):
    if not isinstance(value, str) or not re.fullmatch('[1-9][0-9]*', value):
        raise ValueError('native checkpoint run and attempt must be positive integers')
    return int(value)


def select(run, jobs, artifacts, run_id, attempt):
    if (type(run_id) is not int or type(attempt) is not int or run_id<=0 or attempt<=0
            or type(run.get('id')) is not int or type(run.get('run_attempt')) is not int
            or run.get('id') != run_id or run.get('run_attempt') != attempt
            or run.get('repository', {}).get('full_name') != REPO
            or run.get('path', '').split('@', 1)[0] != WORKFLOW
            or run.get('head_branch') != 'main' or run.get('event') != 'workflow_dispatch'
            or run.get('status') != 'completed' or run.get('conclusion') != 'success'
            or not re.fullmatch('[a-f0-9]{40}', run.get('head_sha', ''))):
        raise ValueError('native checkpoint is not the exact successful trusted producer attempt')
    selected_jobs = [row for row in jobs if row.get('name') == JOB]
    if (len(selected_jobs) != 1 or selected_jobs[0].get('status') != 'completed'
            or selected_jobs[0].get('conclusion') != 'success'
            or selected_jobs[0].get('run_id') != run_id
            or selected_jobs[0].get('run_attempt') != attempt
            or type(selected_jobs[0].get('id')) is not int or selected_jobs[0]['id'] <= 0):
        raise ValueError('original native producer job is missing, ambiguous or unsuccessful')
    name = f'runtime-build-ingredients-{run["head_sha"]}-{run_id}-{attempt}'
    matches = [row for row in artifacts if row.get('name') == name]
    if len(matches) != 1:
        raise ValueError('exact native artifact is missing or ambiguous')
    artifact = matches[0]
    if (artifact.get('expired') is not False or type(artifact.get('id')) is not int
            or artifact['id'] <= 0 or type(artifact.get('size_in_bytes')) is not int
            or not 0 < artifact['size_in_bytes'] <= MAX_ZIP
            or not re.fullmatch('sha256:[a-f0-9]{64}', artifact.get('digest', ''))
            or artifact.get('workflow_run', {}).get('id') != run_id
            or artifact.get('workflow_run', {}).get('head_sha') != run['head_sha']):
        raise ValueError('native artifact identity, digest, size or lifetime is invalid')
    return dict(kind='hostwright.native-checkpoint-resolution.v1',
                producer=dict(commit=run['head_sha'], runID=run_id, attempt=attempt),
                artifact=dict(id=artifact['id'], name=name, sha256=artifact['digest'][7:],
                              sizeBytes=artifact['size_in_bytes'], jobID=selected_jobs[0]['id']),
                originalRun=run, originalJobs=jobs, originalArtifacts=artifacts)


def api(endpoint, paginate=False):
    argv = ['gh', 'api']
    if paginate: argv += ['--paginate', '--slurp']
    result = subprocess.run([*argv, f'repos/{REPO}/{endpoint}'], capture_output=True,
                            check=True, timeout=120)
    if len(result.stdout) > 32 * 1024**2:
        raise ValueError('oversized native producer API response')
    return json.loads(result.stdout)


class ArtifactRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, url):
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != 'https' or parsed.username or parsed.password or parsed.port not in (None, 443):
            raise ValueError('unsafe native artifact redirect')
        redirected = super().redirect_request(request, fp, code, message, headers, url)
        if parsed.hostname != 'api.github.com':
            redirected.remove_header('Authorization')
        return redirected


def download(resolution, target):
    artifact = resolution['artifact']
    token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if not token: raise ValueError('GitHub authentication is required for native artifact download')
    request = urllib.request.Request(
        f'https://api.github.com/repos/{REPO}/actions/artifacts/{artifact["id"]}/zip',
        headers={'Authorization': 'Bearer '+token, 'Accept': 'application/vnd.github+json',
                 'X-GitHub-Api-Version': '2022-11-28'})
    digest = hashlib.sha256(); total = 0; deadline = time.monotonic()+1800
    with urllib.request.build_opener(ArtifactRedirect()).open(request, timeout=60) as response, target.open('xb') as output:
        while True:
            if time.monotonic() >= deadline: raise TimeoutError('native artifact download deadline exceeded')
            block = response.read(1024**2)
            if not block: break
            total += len(block)
            if total > artifact['sizeBytes'] or total > MAX_ZIP:
                raise ValueError('native artifact exceeds its authenticated size bound')
            digest.update(block); output.write(block)
    if total != artifact['sizeBytes'] or digest.hexdigest() != artifact['sha256']:
        raise ValueError('native artifact ZIP differs from the selected immutable artifact')


def disk_admission(root, payload_bytes, evidence=None):
    usage = shutil.disk_usage(root)
    budget = dict(path=str(root), freeBytes=usage.free, payloadBytes=payload_bytes,
                  reserveBytes=DISK_RESERVE, requiredBytes=payload_bytes+DISK_RESERVE)
    if evidence is not None:
        with evidence.open('x') as stream: json.dump(budget, stream, sort_keys=True)
        print(json.dumps(budget, sort_keys=True), flush=True)
    if usage.free < budget['requiredBytes']:
        raise ValueError('insufficient native carrier disk space: '+json.dumps(budget, sort_keys=True))
    return budget


def extract(archive, output, disk_evidence=None):
    if output.exists() or output.is_symlink(): raise ValueError('native extraction root must be new')
    output.mkdir(mode=0o700)
    with zipfile.ZipFile(archive) as bundle:
        members = bundle.infolist()
        if not 0 < len(members) <= MAX_MEMBERS or sum(row.file_size for row in members) > MAX_EXPANDED:
            raise ValueError('native artifact extraction bound exceeded')
        disk_admission(output, sum(row.file_size for row in members), disk_evidence)
        seen = set()
        for member in members:
            name = member.filename.rstrip('/')
            path = PurePosixPath(name)
            mode = member.external_attr >> 16
            if (not name or '\\' in name or '\x00' in name or path.is_absolute()
                    or path.as_posix() != name or any(part in ('', '.', '..') for part in name.split('/'))
                    or name in seen or member.flag_bits & 1
                    or stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)):
                raise ValueError('unsafe or duplicate native artifact member')
            seen.add(name)
            if path.parts[0] not in ('payloads', 'evidence', 'runtime-native-fragment', 'checksums.sha256'):
                raise ValueError('unexpected native artifact namespace')
            target = output.joinpath(*path.parts)
            if member.is_dir(): target.mkdir(mode=0o700, parents=True, exist_ok=True); continue
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with bundle.open(member) as source, target.open('xb') as destination:
                total = 0
                while True:
                    block = source.read(1024**2)
                    if not block: break
                    total += len(block)
                    if total > member.file_size: raise ValueError('native member exceeded declared size')
                    destination.write(block)
                if total != member.file_size: raise ValueError('truncated native artifact member')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    if os.environ.get('GITHUB_REPOSITORY') != REPO:
        raise ValueError('unexpected native checkpoint repository')
    run_id, attempt = positive(os.environ.get('NATIVE_CHECKPOINT_RUN', '')), positive(os.environ.get('NATIVE_CHECKPOINT_ATTEMPT', ''))
    if os.environ.get('SDK_CHECKPOINT_RUN') or os.environ.get('SDK_CHECKPOINT_ATTEMPT'):
        raise ValueError('native and SDK checkpoint inputs are mutually exclusive')
    if not args.output.is_absolute() or args.output.exists() or args.output.is_symlink():
        raise ValueError('native checkpoint output must be a new absolute directory')
    run = api(f'actions/runs/{run_id}/attempts/{attempt}')
    jobs = [row for page in api(f'actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100', True) for row in page['jobs']]
    artifacts = [row for page in api(f'actions/runs/{run_id}/artifacts?per_page=100', True) for row in page['artifacts']]
    resolution = select(run, jobs, artifacts, run_id, attempt)
    args.output.mkdir(mode=0o700)
    (args.output/'resolution.json').write_text(json.dumps(resolution, sort_keys=True, separators=(',', ':'))+'\n')
    archive = args.output/'carrier.zip'
    disk_admission(args.output, resolution['artifact']['sizeBytes'], args.output/'download-space.json')
    download(resolution, archive)
    extract(archive, args.output/'carrier', args.output/'extraction-space.json')


if __name__ == '__main__':
    main()
