#!/usr/bin/env python3
import argparse
import datetime
import json
import re


def require(value, message):
    if not value:
        raise ValueError(message)


def execution(row):
    return {key: row.get(key) for key in ('status', 'conclusion', 'started_at', 'completed_at',
                                         'steps', 'runner_id', 'runner_name', 'labels')}


def timestamp(value):
    require(isinstance(value, str), 'job execution timestamp missing')
    result = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(result.tzinfo is not None, 'job execution timestamp lacks timezone')
    return result


def validate(run, workflow, attempt=None, jobs=None, commit=None):
    require(run.get('path') == '.github/workflows/' + workflow
            and run.get('event') == 'workflow_dispatch' and run.get('head_branch') == 'main'
            and run.get('head_repository', {}).get('full_name') == 'hostwright/hostwright'
            and run.get('conclusion') == 'success' and run.get('status') == 'completed',
            'run is not the successful protected trusted workflow')
    if jobs is None:
        require(attempt is None or str(run.get('run_attempt')) == str(attempt),
                'workflow attempt differs')
        return
    require(workflow == 'trusted-release.yml' and isinstance(commit, str)
            and re.fullmatch('[a-f0-9]{40}', commit) and run.get('head_sha') == commit,
            'exact trusted signed-build source required')
    require(type(run.get('id')) is int and run['id'] > 0, 'invalid stage run identity')
    require(re.fullmatch('[1-9][0-9]*', str(attempt)) and type(run.get('run_attempt')) is int
            and int(attempt) <= run['run_attempt'], 'invalid signed-build attempt')
    rows = jobs.get('jobs')
    require(type(jobs.get('total_count')) is int and isinstance(rows, list)
            and 0 < len(rows) == jobs['total_count'] <= 100, 'job history is missing or truncated')
    names = {'Validate reviewed release inputs', 'Build, sign, notarize, and verify',
             'Attest the retained signed artifacts'}
    require({row.get('name') for row in rows} == names, 'unexpected trusted stage job set')
    effective, seen = {}, set()
    originals = {}
    for row in rows:
        require(row.get('run_id') == run.get('id') and row.get('head_sha') == commit
                and type(row.get('run_attempt')) is int and 0 < row['run_attempt'] <= run['run_attempt'],
                'job belongs to another run/source/attempt')
        identity = (row['name'], row['run_attempt'])
        require(identity not in seen, 'ambiguous duplicate job attempt')
        seen.add(identity)
        if row['run_attempt'] == int(attempt):
            originals[row['name']] = row
        current = effective.get(row['name'])
        if current is None or row['run_attempt'] > current['run_attempt']:
            effective[row['name']] = row
    require(all(row.get('status') == 'completed' and row.get('conclusion') == 'success'
                for row in effective.values()), 'an effective stage job did not succeed')
    build = effective['Build, sign, notarize, and verify']
    attest = effective['Attest the retained signed artifacts']
    for name in ('Validate reviewed release inputs', 'Build, sign, notarize, and verify'):
        original = originals.get(name)
        require(original is not None and original.get('status') == 'completed'
                and original.get('conclusion') == 'success', 'original source/build execution missing')
        require(timestamp(original['started_at']) <= timestamp(original['completed_at']),
                'original execution timing differs')
        for row in rows:
            if row['name'] == name and row['run_attempt'] > int(attempt):
                require(execution(row) == execution(original)
                        and timestamp(row['created_at']) >= timestamp(original['completed_at']),
                        'later source/build job is not the original carried-forward execution')
    original_build = originals['Build, sign, notarize, and verify']
    require(timestamp(originals['Validate reviewed release inputs']['completed_at'])
            <= timestamp(original_build['started_at'])
            and attest['run_attempt'] == run['run_attempt']
            and timestamp(attest['started_at']) >= timestamp(original_build['completed_at']),
            'source/build/attestation execution order differs')
    require(type(build.get('runner_id')) is int and build['runner_id'] > 0
            and build.get('runner_group_id') == 3 and build.get('runner_group_name') == 'hostwright-release'
            and set(build.get('labels', [])) == {'self-hosted', 'macOS', 'ARM64', 'hostwright-release'},
            'signed build did not use the restricted release runner group')
    require(original_build.get('runner_group_id') == build['runner_group_id']
            and original_build.get('runner_group_name') == build['runner_group_name'],
            'original signed build runner group differs')
    require('self-hosted' not in attest.get('labels', []), 'attestation must use a hosted runner')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('run')
    parser.add_argument('workflow')
    parser.add_argument('attempt', nargs='?')
    parser.add_argument('--jobs')
    parser.add_argument('--commit')
    args = parser.parse_args()
    try:
        with open(args.run) as stream:
            run = json.load(stream)
        jobs = None
        if args.jobs:
            with open(args.jobs) as stream:
                jobs = json.load(stream)
        validate(run, args.workflow, args.attempt, jobs, args.commit)
    except ValueError as error:
        raise SystemExit(str(error)) from error
