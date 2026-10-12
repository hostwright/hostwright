#!/usr/bin/env python3
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


producer = load('qualify-kernel-candidate')
comparison = load('compare-kernel-candidates')
signature = load('verify-kernel-source-signature')


class KernelCandidateTests(unittest.TestCase):
    def test_config_exclusions_fail_closed(self):
        profile = {'requiredEnabled': ['CONFIG_INET'], 'requiredDisabled': ['CONFIG_CIFS']}
        valid = 'CONFIG_INET=y\n# CONFIG_CIFS is not set\n'
        producer.check_config(valid, profile)
        for bad in [valid.replace('# CONFIG_CIFS is not set', 'CONFIG_CIFS=m'),
                    valid.replace('CONFIG_INET=y', '# CONFIG_INET is not set'),
                    valid + 'CONFIG_CIFS=y\n', valid + 'CONFIG_INET=y\n', '']:
            with self.subTest(config=bad), self.assertRaises(ValueError):
                producer.check_config(bad, profile)

    def test_excluded_subsystems_cannot_produce_objects(self):
        profile = {'excludedObjectDirectories': ['fs/smb/client/']}
        producer.check_objects(['net/ipv6/tcp_ipv6.o'], profile)
        for path in ['fs/smb/client/cifs.o', 'fs/smb/client/cifs.ko']:
            with self.assertRaises(ValueError):
                producer.check_objects([path], profile)

    def test_pinned_profile_inputs_and_original_signature_default(self):
        profile = json.loads(producer.PROFILE.read_text())
        self.assertEqual(signature.ARCHIVE_SHA, signature.SOURCE_PINS['6.18.15'])
        self.assertEqual(signature.SOURCE_PINS[profile['version']], profile['downloads'][0]['sha256'])
        for item in profile['patches']:
            self.assertEqual(producer.sha(producer.ROOT / item['path']), item['sha256'])
        self.assertEqual(producer.sha(producer.ROOT / profile['seedConfig']), profile['seedConfigSHA256'])
        producer.check_config((producer.ROOT / profile['seedConfig']).read_text(), profile)

    def test_comparison_rejects_wrong_source_missing_tampered_or_different_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dirs = [root / 'first', root / 'second']
            for directory in dirs:
                directory.mkdir()
                for name in ['Image', 'kernel.config', 'objects.json', 'profile.json', 'signature.json']:
                    (directory / name).write_bytes(name.encode())
                result = {'status': 'built-candidate-only', 'sourceCommit': 'a' * 40,
                          'qualificationAccepted': False, 'shippedPinsChanged': False,
                          'kernelVersion': '6.18.55', 'kernelCommit': 'b' * 40,
                          'profileSHA256': producer.sha(directory / 'profile.json'), 'gccSHA256': 'c' * 64,
                          'attachments': {p.name: producer.sha(p) for p in directory.iterdir()}}
                (directory / 'result.json').write_text(json.dumps(result))
            self.assertFalse(comparison.compare(*dirs, 'a' * 40)['qualificationAccepted'])
            with self.assertRaises(ValueError):
                comparison.compare(*dirs, 'd' * 40)
            for mutate in [lambda r: r['attachments'].pop('Image'),
                           lambda r: r.update(gccSHA256='e' * 64),
                           lambda r: r.update(qualificationAccepted=True),
                           lambda r: r.update(profileSHA256='f' * 64)]:
                changed = copy.deepcopy(result)
                mutate(changed)
                (dirs[1] / 'result.json').write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    comparison.compare(*dirs, 'a' * 40)
            (dirs[1] / 'result.json').write_text(json.dumps(result))
            (dirs[1] / 'Image').write_bytes(b'different')
            with self.assertRaises(ValueError):
                comparison.compare(*dirs, 'a' * 40)
            result['attachments']['Image'] = producer.sha(dirs[1] / 'Image')
            (dirs[1] / 'result.json').write_text(json.dumps(result))
            with self.assertRaises(ValueError):
                comparison.compare(*dirs, 'a' * 40)


if __name__ == '__main__':
    unittest.main()
