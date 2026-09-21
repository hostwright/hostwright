import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import tarfile
import zipfile
import hashlib

spec = importlib.util.spec_from_file_location('qualification', Path(__file__).with_name('authenticated-lifecycle.py'))
q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(q)

class BoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='hqa-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # Resolve macOS /var symlink because live paths must be canonical.
        self.root = self.root.resolve()
        self.source = self.root/'source'; self.source.mkdir()
        verifier = self.source/'scripts/release/corresponding-source.py'
        verifier.parent.mkdir(parents=True)
        verifier.write_text('# corresponding-source verifier fixture\n')
        self.cli = self.root/'hostwright'; self.cli.write_text('signed-cli-fixture')
        self.daemon = self.root/'hostwrightd'; self.daemon.write_text('signed-daemon-fixture')
        self.tool = self.root/'container'; self.tool.write_text('runtime-fixture')
        self.manifest = self.root/'manifest.json'; self.manifest.write_text(json.dumps({'version': 3, 'project': 'qualification'}))
        self.config = self.root/'daemon.json'
        self.config.write_text(json.dumps({'version': 3, 'project': 'qualification-idle', 'services': {'idle': {'image': 'example'}}, 'maintenance': {'timezone': 'UTC', 'maximumDeferral': '86400s', 'windows': [{'id': 'qualification-idle', 'actions': ['create', 'start', 'restart', 'update', 'remove'], 'oneShot': {'startsAt': '2099-01-01T00:00:00Z', 'duration': '60s'}}]}}))
        self.binding = self.root/'binding.json'
        self.receipt = {'schemaVersion': 1, 'source': 'a'*40, 'lane': 'apple-cli-1.1.0', 'artifacts': [{'path': str(p), 'signedSHA256': q.sha(p)} for p in (self.cli, self.daemon)], 'runtimeTool': {'path': str(self.tool), 'sha256': q.sha(self.tool)}}
        self.write_receipt()
        self.args = SimpleNamespace(lane='apple-cli-1.1.0', state_root=str(self.root/'s'), evidence=str(self.root/'e'), source_root=str(self.source), binding=str(self.binding), cli=str(self.cli), daemon=str(self.daemon), runtime_tool=str(self.tool), manifest=str(self.manifest), manifest_sha256=q.sha(self.manifest), daemon_config=str(self.config), daemon_config_sha256=q.sha(self.config), project='qualification')
        self.calls = []
        self.setup_provenance()
        self.protection = mock.patch.object(q, 'protected')
        self.protection.start()
        self.addCleanup(self.protection.stop)

    def setup_provenance(self):
        self.control = self.root/'hostwright-control'; self.control.write_text('control-fixture')
        self.verifier = self.root/'hostwright-dist'; self.verifier.write_text('verifier-fixture')
        helpers = []
        for name in ('hostwright-containerization-helper', 'hostwright-network-helper', 'hostwright-network-provider-worker', 'hostwright-storage-helper'):
            helper = self.root/name; helper.write_text(name+' fixture'); helpers.append(helper)
        self.receipt['artifacts'] = [{'path': str(p), 'signedSHA256': q.sha(p), 'payloadPath': 'bin/'+p.name}
                                     for p in (self.cli, self.daemon, self.control, self.verifier, *helpers)]
        stage = self.root/'stage'; stage.mkdir(); release = stage/'release'; release.mkdir()
        archive = release/'release.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            for artifact in self.receipt['artifacts']:
                z.writestr('artifact/'+artifact['payloadPath'], Path(artifact['path']).read_bytes())
        package = release/'release.pkg'; package.write_bytes(b'package fixture')
        self.release_manifest = {'artifactID': 'artifact', 'sourceCommit': 'a'*40, 'packageVersion': '0.0.2',
                                 'archive': {'fileName': archive.name, 'sha256': q.sha(archive)},
                                 'package': {'fileName': package.name, 'sha256': q.sha(package)},
                                 'payloadFiles': [{'path': a['payloadPath'], 'sha256': a['signedSHA256']} for a in self.receipt['artifacts']]}
        (release/'release-manifest.json').write_text(json.dumps(self.release_manifest))
        (release/'release-manifest.json.cms').write_bytes(b'CMS fixture, verifier process mocked only')
        source = stage/'source'; source.mkdir()
        source_manifest = {
            'kind': 'hostwright.corresponding-source.new-runtime.v1',
            'schemaVersion': 1,
            'releaseSourceRevision': 'a'*40,
            'version': '0.0.2',
            'status': 'prepared-not-release-qualified',
            'publicationRoute': 'same-github-release-alongside-binaries',
            'upstreamSignatureVerified': True,
            'preparedSourceState': {'head': 'a'*40, 'clean': True, 'gitStatusSHA256': '0'*64},
        }
        source_manifest_path = source/'source-manifest.json'
        source_manifest_path.write_text(json.dumps(source_manifest, sort_keys=True, separators=(',', ':'))+'\n')
        source_archive = source/('hostwright-0.0.2-'+'a'*12+'-corresponding-source.tar.gz')
        with tarfile.open(source_archive, 'w:gz') as bundle:
            bundle.add(source_manifest_path, arcname='source-manifest.json')
        source_checksums = source/'SOURCE_SHA256SUMS'
        source_checksums.write_text(q.sha(source_archive)+'  '+source_archive.name+'\n'+q.sha(source_manifest_path)+'  source-manifest.json\n')
        inventory = stage/'stage-inventory.json'
        source_descriptor = {
            'kind': 'hostwright.corresponding-source-stage.v1',
            'sourceCommit': 'a'*40,
            'version': '0.0.2',
            'sourceManifestKind': source_manifest['kind'],
            'sourceManifestSchemaVersion': 1,
            'archive': {'fileName': source_archive.name, 'sha256': q.sha(source_archive), 'sizeBytes': source_archive.stat().st_size},
            'manifest': {'fileName': source_manifest_path.name, 'sha256': q.sha(source_manifest_path), 'sizeBytes': source_manifest_path.stat().st_size},
            'checksums': {'fileName': source_checksums.name, 'sha256': q.sha(source_checksums)},
        }
        staged_files = {'release/'+p.name: q.sha(p) for p in release.iterdir()}
        staged_files.update({'source/'+p.name: q.sha(p) for p in source.iterdir()})
        inventory.write_text(json.dumps({'kind': 'hostwright.stage-inventory.v2', 'sourceCommit': 'a'*40, 'version': '0.0.2',
                                         'buildRunID': '123', 'buildRunAttempt': '1', 'files': staged_files,
                                         'correspondingSource': source_descriptor}))
        self.receipt['release'] = {'stageRoot': str(stage), 'inventorySHA256': q.sha(inventory), 'verifierPath': str(self.verifier), 'verifierSHA256': q.sha(self.verifier), 'version': '0.0.2', 'teamIdentifier': 'ABCDE12345', 'correspondingSource': source_descriptor}
        runtime = self.root/'runtime'; runtime.mkdir(mode=0o700)
        self.receipt['runtimeAppRoot'] = str(runtime)
        runtime_receipt = runtime/'qualification-root.json'
        runtime_receipt.write_text(json.dumps({'source': 'a'*40, 'lane': self.receipt['lane'], 'runtimeToolSHA256': q.sha(self.tool), 'runtimeAppRoot': str(runtime), 'environment': 'CONTAINER_APP_ROOT'}))
        self.receipt['runtimeAppRootReceiptSHA256'] = q.sha(runtime_receipt)
        self.receipt['vmIsolation'] = {'toolPath': str(self.tool), 'toolSHA256': q.sha(self.tool), 'tartHome': str(runtime), 'name': 'other-lab'}
        self.receipt['memory'] = {'rssBudgetBytes': 1024*1024, 'processPaths': [str(self.tool)], 'processSHA256': {str(self.tool): q.sha(self.tool)}}
        self.receipt['soakSchedulingToleranceSeconds'] = 1
        marker = 'f'*32
        self.manifest.write_text(json.dumps({'version': 3, 'project': 'qualification', 'services': {'web': {'command': ['serve', marker], 'ports': ['127.0.0.1:18080:8080'], 'probes': {k: {'http': {'port': 8080, 'path': '/'}} for k in ('startup', 'readiness', 'liveness')}}}}))
        self.args.manifest_sha256 = q.sha(self.manifest); self.args.health_url = 'http://127.0.0.1:18080/'
        self.receipt['health'] = {'manifestSHA256': q.sha(self.manifest), 'service': 'web', 'marker': marker, 'hostPort': 18080, 'containerPort': 8080, 'bodySHA256': hashlib.sha256(marker.encode()).hexdigest()}
        self.write_receipt()

    def write_receipt(self):
        self.binding.write_text(json.dumps(self.receipt))

    def runner(self, argv, **kwargs):
        self.calls.append(argv)
        if 'verify-release' in argv:
            stdout = json.dumps(dict(self.release_manifest, schemaVersion=1, kind='trustedReleaseVerification', status='passed', signerTeamIdentifier='ABCDE12345'))
        elif '--expected-archive-sha256' in argv:
            source = self.receipt['release']['correspondingSource']
            stdout = json.dumps({'archiveSHA256': source['archive']['sha256'],
                                 'manifestSHA256': source['manifest']['sha256'],
                                 'releaseSourceRevision': self.receipt['source'],
                                 'version': self.receipt['release']['version'],
                                 'status': 'prepared-not-release-qualified'})
        elif 'list' in argv:
            stdout = json.dumps([{'Name': 'other-lab', 'Source': 'local', 'State': 'stopped', 'Running': False}])
        else:
            stdout = self.receipt['source']+'\n' if 'rev-parse' in argv else 'container CLI 1.1.0\n' if '--version' in argv else ''
        return SimpleNamespace(stdout=stdout, returncode=0)

    def reject(self, pattern):
        with self.assertRaisesRegex(q.Rejected, pattern): q.preflight(self.args, self.runner)
        self.assertFalse(Path(self.args.evidence).exists())

    def test_valid_preflight_is_nonmutating(self):
        q.preflight(self.args, self.runner)
        self.assertFalse(Path(self.args.state_root).exists())
        self.assertFalse(Path(self.args.evidence).exists())
        self.assertTrue(all('bootstrap-identities' not in call for call in self.calls))

    def test_artifact_mismatch_rejected_before_mutation(self):
        self.cli.write_text('replaced')
        self.reject('binding mismatch')
        self.assertFalse(Path(self.args.state_root).exists())

    def test_manifest_mismatch_rejected_before_mutation(self):
        self.manifest.write_text('{}')
        self.reject('binding mismatch')

    def test_existing_even_empty_state_rejected(self):
        Path(self.args.state_root).mkdir()
        self.reject('ambiguous existing')
        self.assertEqual(self.calls, [])

    def test_wrong_binding_lane_rejected(self):
        self.receipt['lane'] = 'apple-cli-1.0.0'; self.write_receipt()
        self.reject('wrong lane')
        self.assertEqual(self.calls, [])

    def test_runtime_version_mismatch_rejected(self):
        self.args.lane = self.receipt['lane'] = 'apple-cli-1.0.0'; self.write_receipt()
        self.reject('wrong runtime lane')

    def test_dirty_source_rejected(self):
        def dirty(argv, **kwargs):
            return SimpleNamespace(stdout='a'*40+'\n' if 'rev-parse' in argv else ' M tracked\n')
        with self.assertRaisesRegex(q.Rejected, 'dirty source'): q.preflight(self.args, dirty)
        self.assertFalse(Path(self.args.state_root).exists())

    def test_sdk_without_qualified_adapter_is_blocked(self):
        self.args.lane = self.receipt['lane'] = 'containerization-0.35.0'; self.write_receipt()
        self.reject('SDK blocked')

    def test_uncovered_daemon_maintenance_rejected(self):
        data = q.load(self.config); data['maintenance']['windows'][0]['actions'] = ['create']
        self.config.write_text(json.dumps(data)); self.args.daemon_config_sha256 = q.sha(self.config)
        self.reject('every elective action')

    def test_completion_requires_exact_verified_action_sequence(self):
        cp = {'daemonCleaned': True, 'cycles': 10, 'finalBindingsVerified': True, 'memorySamples': [['real sample']]*40, 'vmIsolationSamples': [{'vm': {'State': 'stopped', 'Running': False}}]*40, 'releaseVerification': {'status': 'passed'}}
        receipt = [{'exitCode': 0}]
        self.assertFalse(q.completion(cp, 'cycles', receipt))
        cp.update(verifiedActions=['up', 'restart', 'down', 'rm']*10, verifiedObservations=['up', 'restart', 'down', 'rm']*10)
        self.assertTrue(q.completion(cp, 'cycles', receipt))
        self.assertFalse(q.completion(cp, 'cycles', [{'exitCode': 1}]))
        cp['daemonCleaned'] = False
        self.assertFalse(q.completion(cp, 'cycles', receipt))

    def test_soak_cannot_complete_early_or_without_final_removal(self):
        cp = {'daemonCleaned': True, 'finalBindingsVerified': True, 'memorySamples': [['real sample']]*63, 'vmIsolationSamples': [{'vm': {'State': 'stopped', 'Running': False}}]*63, 'releaseVerification': {'status': 'passed'}, 'schedulingTolerance': 1, 'soakTiming': [{'scheduled': i*30, 'started': i*30, 'finished': i*30+1} for i in range(61)], 'soakSamples': 61, 'soakElapsedSeconds': 1799, 'verifiedActions': ['up', 'down', 'rm'], 'verifiedObservations': ['soak']*61+['down', 'rm']}
        self.assertFalse(q.completion(cp, 'soak', [{'exitCode': 0}]))
        cp['soakElapsedSeconds'] = 1800
        self.assertTrue(q.completion(cp, 'soak', [{'exitCode': 0}]))
        cp['verifiedActions'].pop()
        self.assertFalse(q.completion(cp, 'soak', [{'exitCode': 0}]))

    def test_provenance_swap_source_cannot_relabel_old_executables(self):
        self.receipt['source'] = 'b'*40
        stage = Path(self.receipt['release']['stageRoot'])/'stage-inventory.json'
        data = q.load(stage); data['sourceCommit'] = 'b'*40; stage.write_text(json.dumps(data))
        self.receipt['release']['inventorySHA256'] = q.sha(stage); self.write_receipt()
        self.reject('corresponding-source stage binding mismatch')

    def test_corresponding_source_artifact_mismatch_rejected(self):
        source = self.receipt['release']['correspondingSource']
        archive = Path(self.receipt['release']['stageRoot'])/'source'/source['archive']['fileName']
        archive.write_bytes(b'tampered corresponding source')
        self.reject('binding mismatch')

    def test_selected_actual_executable_must_equal_archive_payload(self):
        self.cli.write_bytes(b'other validly signed source executable')
        self.receipt['artifacts'][0]['signedSHA256'] = q.sha(self.cli); self.write_receipt()
        self.reject('differs from signed release payload')

    def test_user_writable_provenance_is_rejected(self):
        self.protection.stop()
        with self.assertRaisesRegex(q.Rejected, 'protected root-owned'): q.protected(self.root)

    def test_duplicate_json_metadata_is_rejected(self):
        self.binding.write_text('{"schemaVersion":1,"lane":"apple-cli-1.1.0","lane":"apple-cli-1.0.0"}')
        self.reject('duplicate JSON key')

    def test_running_or_unknown_vm_cannot_pass(self):
        for state in ('running', 'unknown'):
            def running(argv, **kwargs):
                return SimpleNamespace(stdout=json.dumps([{'Name': 'other-lab', 'Source': 'local', 'State': state, 'Running': state == 'running'}]), returncode=0)
            with self.assertRaisesRegex(q.Rejected, 'running, missing or unknown'): q.stopped_vm(self.receipt, running)

    def test_runtime_app_root_receipt_tamper_is_rejected(self):
        (Path(self.receipt['runtimeAppRoot'])/'qualification-root.json').write_text('{}')
        self.reject('binding mismatch')

    def test_final_manifest_and_cms_sidecar_tamper_is_rejected(self):
        digest = q.sha(self.binding)
        self.manifest.write_text('{}')
        with self.assertRaisesRegex(q.Rejected, 'binding mismatch'): q.guard_input_files(self.args, self.receipt, digest)
        # Separate CMS input mutation must also fail the final staged-file guard.
        self.args.manifest_sha256 = q.sha(self.manifest)
        cms = Path(self.receipt['release']['stageRoot'])/'release/release-manifest.json.cms'
        cms.write_bytes(b'replaced CMS')
        with self.assertRaisesRegex(q.Rejected, 'binding mismatch'): q.guard_input_files(self.args, self.receipt, digest)

    def test_arbitrary_sdk_passed_bool_never_unlocks_lane(self):
        self.receipt.update(lane='containerization-0.35.0', observer={'passed': True, 'realRuntime': True})
        self.args.lane = self.receipt['lane']; self.write_receipt()
        self.reject('SDK blocked')

    def test_http200_without_workload_marker_is_rejected(self):
        with self.assertRaisesRegex(q.Rejected, 'unrelated HTTP200'): q.validate_body(b'healthy unrelated server', self.receipt['health'])
        q.validate_body(self.receipt['health']['marker'].encode(), self.receipt['health'])

    def test_unhealthy_or_wrong_resource_authenticated_status_rejected(self):
        status = {'services': [{'name': 'web', 'observed': {'resourceIdentifier': 'owned', 'lifecycle': 'running', 'health': 'healthy'}}], 'drift': []}
        q.validate_status_health(status, {'id': 'owned'}, self.receipt['health'])
        for field, value in (('health', 'unhealthy'), ('resourceIdentifier', 'other')):
            changed = json.loads(json.dumps(status)); changed['services'][0]['observed'][field] = value
            with self.assertRaisesRegex(q.Rejected, 'identity/health failed'): q.validate_status_health(changed, {'id': 'owned'}, self.receipt['health'])

    def test_wrong_manifest_owned_port_is_rejected(self):
        self.receipt['health']['hostPort'] = 18081
        with self.assertRaisesRegex(q.Rejected, 'publication'): q.validate_health_manifest(self.args, self.receipt)

    def test_memory_missing_scope_or_over_budget_rejected(self):
        raw = '100 1 1024 Sun Sep 13 12:00:00 2026 /daemon\n101 1 1024 Sun Sep 13 12:00:00 2026 /runtime\n'
        q.parse_process_memory(raw, 100, ['/runtime'], 3*1024*1024)
        for text, budget in (('', 9999999), (raw.splitlines()[0], 9999999), (raw, 1024)):
            with self.assertRaises(q.Rejected): q.parse_process_memory(text, 100, ['/runtime'], budget)

    def test_soak_stall_missed_deadline_and_catchup_rejected(self):
        previous = q.timing_sample(0, 0, 1, 1)
        for scheduled, started, finished in ((30, 90, 91), (30, 30, 61), (0, 0, 1)):
            with self.assertRaises(q.Rejected): q.timing_sample(scheduled, started, finished, 1, previous)

    def test_wrong_owned_port_uuid_or_fence_is_rejected(self):
        own = {'nativeInventory': {'configuration': {'labels': {'dev.hostwright.resource-uuid': 'owned-uuid', 'dev.hostwright.fencing-token': 'owned-fence'}}}}
        port = {'resource_uuid': 'owned-uuid', 'fencing_token': 'owned-fence', 'lifecycle_state': 'active', 'provider_id': 'apple-container-cli', 'bind_address': '127.0.0.1', 'container_port': 8080}
        q.validate_owned_port(own, self.receipt['health'], [port], 'apple-container-cli')
        for field in ('resource_uuid', 'fencing_token'):
            wrong = dict(port); wrong[field] = 'other'
            with self.assertRaisesRegex(q.Rejected, 'UUID/fence'): q.validate_owned_port(own, self.receipt['health'], [wrong], 'apple-container-cli')

    def test_stage_version_and_package_hash_mismatch_rejected(self):
        self.receipt['release']['version'] = '0.0.3'; self.write_receipt()
        self.reject('stage source/version')
        self.receipt['release']['version'] = '0.0.2'; self.write_receipt()
        (Path(self.receipt['release']['stageRoot'])/'release/release.pkg').write_bytes(b'other package')
        self.reject('binding mismatch')

    def test_unmanaged_native_configuration_mutation_is_visible(self):
        harness = object.__new__(q.Harness); harness.a = self.args; harness.provider = 'apple-container-cli'
        original = {'id': 'unmanaged', 'project': 'other', 'state': 'running', 'nativeInventory': {'configuration': {'image': 'digest-a', 'mounts': ['/a'], 'labels': {}}}}
        changed = json.loads(json.dumps(original)); changed['nativeInventory']['configuration']['mounts'] = ['/b']
        self.assertNotEqual(harness.unmanaged([original]), harness.unmanaged([changed]))

    def test_completion_requires_every_memory_and_vm_sample(self):
        actions = ['up', 'restart', 'down', 'rm']*10
        cp = {'daemonCleaned': True, 'cycles': 10, 'finalBindingsVerified': True, 'releaseVerification': {'status': 'passed'}, 'verifiedActions': actions, 'verifiedObservations': actions, 'memorySamples': [[]]*39, 'vmIsolationSamples': [{'vm': {'State': 'stopped', 'Running': False}}]*40}
        self.assertFalse(q.completion(cp, 'cycles', [{'exitCode': 0}]))
        cp['memorySamples'] = [[]]*40; cp['vmIsolationSamples'] = []
        self.assertFalse(q.completion(cp, 'cycles', [{'exitCode': 0}]))

    def test_omitted_cms_inventory_input_rejected(self):
        inventory = Path(self.receipt['release']['stageRoot'])/'stage-inventory.json'
        obj = q.load(inventory); del obj['files']['release/release-manifest.json.cms']
        inventory.write_text(json.dumps(obj)); self.receipt['release']['inventorySHA256'] = q.sha(inventory); self.write_receipt()
        self.reject('omits release/CMS')

if __name__ == '__main__': unittest.main()
