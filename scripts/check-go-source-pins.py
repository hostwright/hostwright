#!/usr/bin/env python3
"""Check the shipped guest module closure against its corresponding-source pins."""

import json
import os
from pathlib import Path
import subprocess
import sys


def json_stream(text):
    decoder = json.JSONDecoder()
    while text.strip():
        text = text.lstrip()
        value, end = decoder.raw_decode(text)
        yield value
        text = text[end:]


def validate_versions(packages, pins):
    expected = {}
    for pin in pins:
        name = pin['module']
        if name in expected:
            raise ValueError('duplicate source pin: ' + name)
        expected[name] = pin['version']
    actual = {}
    for package in packages:
        module = package.get('Module')
        if module is None or module.get('Main'):
            continue
        if module.get('Replace'):
            raise ValueError('unqualified module replacement: ' + module['Path'])
        actual[module['Path']] = module['Version']
    if actual != expected:
        mismatches = sorted(name for name in actual.keys() | expected.keys()
                            if actual.get(name) != expected.get(name))
        raise ValueError('module closure differs from runtime-go-sources.json: ' + ', '.join(mismatches))


def validate_origin(metadata, pin):
    if (metadata.get('Path') != pin['module'] or metadata.get('Version') != pin['version']
            or metadata.get('Origin', {}).get('Hash') != pin['commit']):
        raise ValueError('module source revision differs from its pin: ' + pin['module'])


def self_test():
    pin = dict(module='example.invalid/dependency', version='v1.0.0', commit='a' * 40)
    package = dict(Module=dict(Path=pin['module'], Version=pin['version']))
    metadata = dict(Path=pin['module'], Version=pin['version'], Origin=dict(Hash=pin['commit']))
    validate_versions([package], [pin])
    validate_origin(metadata, pin)
    rejected = [
        lambda: validate_versions([package], []),
        lambda: validate_versions([], [pin]),
        lambda: validate_versions([package], [pin, pin]),
        lambda: validate_versions([dict(Module=dict(package['Module'], Version='v2.0.0'))], [pin]),
        lambda: validate_versions([dict(Module=dict(package['Module'], Replace={"Path": "local"}))], [pin]),
        lambda: validate_origin(dict(metadata, Origin=dict(Hash='b' * 40)), pin),
        lambda: validate_origin(dict(metadata, Origin={}), pin),
    ]
    for check in rejected:
        try:
            check()
        except ValueError:
            continue
        raise AssertionError('unqualified dependency accepted')
    print('go-source-pins: matching inputs and seven rejection cases passed')


def main():
    if sys.argv[1:] == ['--self-test']:
        self_test()
        return
    if sys.argv[1:]:
        raise ValueError('usage: check-go-source-pins.py [--self-test]')
    root = Path(__file__).resolve().parents[1]
    pins = json.loads((root / 'scripts/release/runtime-go-sources.json').read_text())['modules']
    environment = dict(os.environ, GOOS='linux', GOARCH='arm64', CGO_ENABLED='0',
                       GOTOOLCHAIN='local', GOWORK='off', GOFLAGS='-mod=readonly')

    def go(*arguments):
        return subprocess.check_output(['go', *arguments], cwd=root / 'Guest/HostwrightNetfilter',
                                       env=environment, text=True)

    validate_versions(json_stream(go('list', '-deps', '-json', '.')), pins)
    for pin in pins:
        validate_origin(json.loads(go('mod', 'download', '-json', pin['module'] + '@' + pin['version'])), pin)
    print(f'go-source-pins: {len(pins)} shipped module versions and source revisions verified')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print('go-source-pins: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
