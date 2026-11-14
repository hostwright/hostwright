#!/usr/bin/env python3
"""Select source regressions from a complete Git diff; uncertainty runs the full gate."""
import argparse
import re
import subprocess

NATIVE_REUSE = {
    'scripts/release/native-reuse-inputs.py',
    'scripts/release/verify-native-reuse.py',
    'scripts/release/test-native-runtime-reuse.py',
    'scripts/release/verify-runtime-provenance.py',
    'scripts/release/test-runtime-provenance.py',
    'scripts/ci-check-scope.py',
    'scripts/test-ci-check-scope.py',
    '.github/workflows/ci.yml',
}


def documentation(path):
    return path in {'README.md', 'AGENTS.md', 'CHANGELOG.md', 'CONTRIBUTING.md'} or path.startswith(('docs/', 'ThirdPartyLicenses/'))


def choose(paths):
    if not paths or any(not isinstance(path, str) or not path for path in paths):
        return 'full'
    if all(documentation(path) for path in paths):
        return 'docs'
    if all(documentation(path) or path in NATIVE_REUSE for path in paths):
        return 'native-reuse'
    return 'full'


def git_scope(event, base, head):
    if event not in ('pull_request', 'push') or any(not re.fullmatch('[a-f0-9]{40}', value) or value == '0'*40 for value in (base, head)):
        return 'full'
    try:
        for commit in (base, head):
            subprocess.run(['git', 'cat-file', '-e', commit+'^{commit}'], check=True, capture_output=True, timeout=15)
        result = subprocess.run(['git', 'diff', '--name-only', '-z', base, head], check=True, capture_output=True, timeout=30)
        return choose([path.decode('utf-8', 'strict') for path in result.stdout.split(b'\0') if path])
    except (subprocess.SubprocessError, UnicodeError):
        return 'full'


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ('event', 'base', 'head'):
        parser.add_argument('--'+name, default='')
    args = parser.parse_args()
    print(git_scope(args.event, args.base, args.head))
