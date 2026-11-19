#!/usr/bin/env python3
"""Cap Swift source files at 800 lines and keep the oversized-file backlog current."""

import argparse
import os
from pathlib import Path
import subprocess

LIMIT = 800
BASELINE = Path('scripts/swift-source-file-size-baseline.tsv')


def git(*args):
    return subprocess.check_output(['git', *args])


def swift_paths(listing):
    return {os.fsdecode(path) for path in listing.split(b'\0') if path.endswith(b'.swift')}


def line_count(content):
    return content.count(b'\n') + bool(content and not content.endswith(b'\n'))


def oversized_sources():
    files = swift_paths(git('ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', 'Sources'))
    sizes = {path: line_count(Path(path).read_bytes()) for path in files if Path(path).is_file()}
    return sorted(((size, path) for path, size in sizes.items() if size > LIMIT),
                  key=lambda entry: (-entry[0], entry[1]))


def check_growth(base, oversized):
    base_files = swift_paths(git('ls-tree', '-r', '-z', '--name-only', base, '--', 'Sources'))
    problems = []
    for size, path in oversized:
        before = line_count(git('show', f'{base}:{path}')) if path in base_files else 0
        if size > max(before, LIMIT):
            problems.append(f'{path}: {size} lines, maximum {max(before, LIMIT)}')
    return problems


def baseline_covers(oversized):
    if not BASELINE.is_file():
        return False
    lines = BASELINE.read_text(encoding='utf-8').splitlines()
    if not lines or lines[0] != 'lines\tpath':
        return False
    try:
        entries = [(int(size), path) for size, path in (line.split('\t', 1) for line in lines[1:])]
    except ValueError:
        return False
    if entries != sorted(entries, key=lambda entry: (-entry[0], entry[1])):
        return False
    recorded = {path: size for size, path in entries}
    return (len(entries) == len(recorded) == len(oversized)
            and all(recorded.get(path, 0) >= size for size, path in oversized))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--base', help='Git revision to compare against')
    mode.add_argument('--write-baseline', action='store_true', help='refresh the tracked work order')
    args = parser.parse_args()
    os.chdir(os.fsdecode(git('rev-parse', '--show-toplevel').rstrip(b'\n')))

    oversized = oversized_sources()
    expected = 'lines\tpath\n' + ''.join(f'{size}\t{path}\n' for size, path in oversized)
    if args.write_baseline:
        BASELINE.write_text(expected, encoding='utf-8')
        return 0

    base = git('rev-parse', '--verify', '--end-of-options', f'{args.base}^{{commit}}').decode().strip()
    problems = check_growth(base, oversized)
    if not baseline_covers(oversized):
        problems.append('Refresh scripts/swift-source-file-size-baseline.tsv with --write-baseline.')
    for problem in problems:
        print(problem)
    if not problems:
        print(f'Swift source sizing passed. {len(oversized)} existing files over {LIMIT} lines.')
    return bool(problems)


if __name__ == '__main__':
    raise SystemExit(main())
