#!/usr/bin/env python3
"""Compare independently produced candidate bytes and their source bindings."""

import argparse
import hashlib
import json
from pathlib import Path


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def compare(first, second, commit):
    results = []
    required = {'Image', 'kernel.config', 'objects.json', 'profile.json', 'signature.json'}
    for directory in [first, second]:
        result = json.loads((directory / 'result.json').read_text())
        if (result['sourceCommit'] != commit or result['status'] != 'built-candidate-only'
                or result['qualificationAccepted'] is not False or result['shippedPinsChanged'] is not False):
            raise ValueError('Candidate source or qualification binding differs')
        if not required.issubset(result['attachments']):
            raise ValueError('Candidate evidence is incomplete')
        for name, expected in result['attachments'].items():
            path = directory / name
            if Path(name).name != name or path.is_symlink() or sha(path) != expected:
                raise ValueError('Candidate evidence checksum differs')
        if result['profileSHA256'] != sha(directory / 'profile.json'):
            raise ValueError('Candidate profile binding differs')
        results.append(result)
    for key in ['kernelVersion', 'kernelCommit', 'profileSHA256', 'gccSHA256']:
        if results[0][key] != results[1][key]:
            raise ValueError(f'Independent build inputs differ: {key}')
    for name in ['Image', 'kernel.config', 'objects.json', 'profile.json']:
        if sha(first / name) != sha(second / name):
            raise ValueError(f'Independent kernel rebuilds differ: {name}')
    return {'status': 'independent-candidate-rebuilds-match', 'sourceCommit': commit,
            'imageSHA256': sha(first / 'Image'), 'qualificationAccepted': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--first', type=Path, required=True)
    parser.add_argument('--second', type=Path, required=True)
    parser.add_argument('--source-commit', required=True)
    args = parser.parse_args()
    print(json.dumps(compare(args.first, args.second, args.source_commit), sort_keys=True))
