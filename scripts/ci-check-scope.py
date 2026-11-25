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
CODEQL_SWIFT_SUFFIXES = ('.swift', '.c', '.h', '.m', '.mm', '.modulemap')
CODEQL_SWIFT_INPUTS = {
    'Package.swift',
    'Package.resolved',
    '.github/workflows/security.yml',
    'scripts/ci-check-scope.py',
}


def documentation(path):
    return path in {'README.md', 'AGENTS.md', 'CHANGELOG.md', 'CONTRIBUTING.md'} or path.startswith(('docs/', 'ThirdPartyLicenses/'))


def choose(paths):
    if not paths or any(not isinstance(path, str) or not path for path in paths):
        return 'full'
    if all(documentation(path) for path in paths):
        return 'docs-qualification'
    if all(documentation(path) or path in NATIVE_REUSE for path in paths):
        return 'native-reuse-docs' if any(map(documentation, paths)) else 'native-reuse'
    return 'full'


def changed_paths(base, head):
    if any(not re.fullmatch('[a-f0-9]{40}', value) or value == '0'*40 for value in (base, head)):
        return None
    try:
        for commit in (base, head):
            subprocess.run(['git', 'cat-file', '-e', commit+'^{commit}'], check=True, capture_output=True, timeout=15)
        result = subprocess.run(
            ['git', 'diff', '--no-renames', '--name-only', '-z', base, head, '--'],
            check=True, capture_output=True, timeout=30,
        )
        return [path.decode('utf-8', 'strict') for path in result.stdout.split(b'\0') if path]
    except (subprocess.SubprocessError, UnicodeError):
        return None


def git_scope(event, base, head):
    if event not in ('pull_request', 'push'):
        return 'full'
    return choose(changed_paths(base, head))


def codeql_swift(event, base, head):
    if event != 'pull_request':
        return True
    paths = changed_paths(base, head)
    return paths is None or any(
        path in CODEQL_SWIFT_INPUTS
        or path.startswith('Sources/')
        or (not path.startswith('Tests/') and path.endswith(CODEQL_SWIFT_SUFFIXES))
        for path in paths
    )


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ('event', 'base', 'head'):
        parser.add_argument('--'+name, default='')
    parser.add_argument('--codeql-swift', action='store_true')
    args = parser.parse_args()
    if args.codeql_swift:
        print(str(codeql_swift(args.event, args.base, args.head)).lower())
    else:
        print(git_scope(args.event, args.base, args.head))
