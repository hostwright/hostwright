import ast
import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('sdk', Path(__file__).with_name('sdk_qualification_observer.py'))
sdk = importlib.util.module_from_spec(spec); spec.loader.exec_module(sdk)

class SDKBoundaryTests(unittest.TestCase):
    def status(self):
        return {'runtime': {'observed': True, 'adapter': 'AppleContainerizationRuntimeAdapter'}, 'services': [{'name': 'api', 'observed': {
            'resourceIdentifier': 'owned', 'lifecycle': 'running', 'allocation': {'cpuCount': 2, 'memoryBytes': 805306368}}}]}

    def test_sdk_admission_charges_vm_overhead_without_changing_guest_allocation(self):
        for cpu, memory, charged_cpu, charged_memory in [(1,536870912,2,671088640),(2,805306368,3,939524096)]:
            with self.subTest(cpu=cpu):
                row={'status':'committed','resource_vector_json':json.dumps({'cpu':charged_cpu,'memory':charged_memory})}
                self.assertEqual(sdk.validate_sdk_reservation(row,cpu,memory,'0.35.0'),{'cpu':charged_cpu,'memory':charged_memory})
                actual=self.status(); actual['services'][0]['observed']['allocation']={'cpuCount':cpu,'memoryBytes':memory}
                sdk.validate_status(actual,'api','owned',cpu,memory)
                with self.assertRaises(sdk.Rejected): sdk.validate_status(actual,'api','owned',charged_cpu,charged_memory)
                heartbeat=self.heartbeat(); heartbeat.update(cpuMax=str(cpu*100000)+' 100000',memoryMax=str(memory))
                sdk.validate_heartbeat('HWQSDK '+json.dumps(heartbeat),'a'*32,cpu,memory)
                with self.assertRaises(sdk.Rejected): sdk.validate_heartbeat('HWQSDK '+json.dumps(heartbeat),'a'*32,charged_cpu,charged_memory)

    def test_sdk_undercharged_or_uncommitted_reservations_rejected(self):
        for vector in ({'cpu':1,'memory':536870912},{'cpu':2,'memory':536870912},{'cpu':1,'memory':671088640},{'cpu':2.0,'memory':671088640}):
            with self.subTest(vector=vector), self.assertRaisesRegex(sdk.Rejected,'admission charge mismatch'):
                sdk.validate_sdk_reservation({'status':'committed','resource_vector_json':json.dumps(vector)},1,536870912,'0.35.0')
        with self.assertRaises(sdk.Rejected): sdk.validate_sdk_reservation({'status':'planned','resource_vector_json':'{"cpu":2,"memory":671088640}'},1,536870912,'0.35.0')
        for cpu,memory,framework in [(True,536870912,'0.35.0'),(1,0,'0.35.0'),(1,536870912,'0.36.0'),((1<<63)-1,536870912,'0.35.0'),(1,(1<<63)-1,'0.35.0')]:
            with self.assertRaises(sdk.Rejected): sdk.expected_sdk_admission(cpu,memory,framework)

    def test_actual_status_allocation_required(self):
        sdk.validate_status(self.status(), 'api', 'owned', 2, 805306368)
        for cpus, memory in [(1, 536870912), (2, 536870912)]:
            with self.assertRaises(sdk.Rejected): sdk.validate_status(self.status(), 'api', 'owned', cpus, memory)
        missing = self.status(); missing['services'][0]['observed'].pop('allocation')
        with self.assertRaises(sdk.Rejected): sdk.validate_status(missing, 'api', 'owned', 2, 805306368)

    def test_status_rejects_disconnected_provider_identity_and_ambiguity(self):
        for key, value in [('observed', False), ('adapter', 'AppleContainerApplyAdapter')]:
            obj = self.status(); obj['runtime'][key] = value
            with self.assertRaises(sdk.Rejected): sdk.validate_status(obj, 'api', 'owned', 2, 805306368)
        with self.assertRaises(sdk.Rejected): sdk.validate_status(self.status(), 'api', 'unrelated', 2, 805306368)
        obj = self.status(); obj['services'][0]['instances'] = [{}, {}]
        with self.assertRaises(sdk.Rejected): sdk.validate_status(obj, 'api', 'owned', 2, 805306368)

    def stats(self):
        return dict(schemaVersion=1, providerID='apple-containerization', resourceIdentifier='owned', capabilitySHA256='a'*64,
                    memoryLimitBytes=805306368, memoryUsageBytes=1000, cpuUsageMicroseconds=100, processCount=2)

    def test_actual_stats_and_complete_frame_sequence(self):
        obj = self.stats(); sdk.validate_stats(obj, 'owned', 'a'*64, 805306368)
        frames = [dict(schemaVersion=1, sequence=0, stream='stdout', payloadBase64=base64.b64encode(json.dumps(obj).encode()).decode(), endOfStream=False),
                  dict(schemaVersion=1, sequence=1, stream='control', payloadBase64='', endOfStream=True)]
        raw = '\n'.join(map(json.dumps, frames)); self.assertEqual(sdk.stats_payload(raw), obj)
        with self.assertRaises(sdk.Rejected): sdk.stats_payload(json.dumps(frames[0]))
        frames[1]['sequence'] = 2
        with self.assertRaises(sdk.Rejected): sdk.stats_payload('\n'.join(map(json.dumps, frames)))

    def test_stats_rejects_unavailable_memory_or_process_fallback(self):
        for key, value in [('memoryLimitBytes', 536870912), ('processCount', 0), ('cpuUsageMicroseconds', 0), ('memoryUsageBytes', 0), ('providerID', 'apple-container-cli')]:
            obj = self.stats(); obj[key] = value
            with self.assertRaises(sdk.Rejected): sdk.validate_stats(obj, 'owned', 'a'*64, 805306368)

    def heartbeat(self, sequence=1):
        nonce = 'a'*32; result = hashlib.sha256((nonce+':'+str(sequence)).encode()).hexdigest()
        return dict(nonce=nonce, sequence=sequence, monotonicNS=sequence*100, httpStatus=200,
                    bodySHA256=result, responseSHA256=result, cpuMax='200000 100000', memoryMax='805306368')

    def test_real_http_hash_cgroup_and_increasing_heartbeat(self):
        first = sdk.validate_heartbeat('HWQSDK '+json.dumps(self.heartbeat()), 'a'*32, 2, 805306368)
        sdk.validate_heartbeat('HWQSDK '+json.dumps(self.heartbeat(2)), 'a'*32, 2, 805306368, first)
        with self.assertRaises(sdk.Rejected): sdk.validate_heartbeat('HWQSDK '+json.dumps(self.heartbeat()), 'a'*32, 2, 805306368, first)

    def test_heartbeat_rejects_stale_nonce_wrong_hash_http_or_unlimited_cgroup(self):
        for key, value in [('nonce', 'b'*32), ('responseSHA256', 'b'*64), ('httpStatus', 500), ('cpuMax', 'max 100000'), ('memoryMax', 'max')]:
            obj = self.heartbeat(); obj[key] = value
            with self.assertRaises(sdk.Rejected): sdk.validate_heartbeat('HWQSDK '+json.dumps(obj), 'a'*32, 2, 805306368)
        with self.assertRaises(sdk.Rejected): sdk.validate_heartbeat('ready', 'a'*32, 2, 805306368)

    def test_workload_argument_preserves_program_without_control_characters(self):
        nonce = 'a'*32
        wrapper = sdk.workload_program(nonce)
        self.assertLessEqual(len(wrapper.encode('utf-8')), 4096)
        self.assertFalse(any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in wrapper))
        tree = ast.parse(wrapper)
        self.assertEqual(len(tree.body), 1)
        call = tree.body[0].value
        self.assertIsInstance(call, ast.Call)
        self.assertEqual(call.func.id, 'exec')
        self.assertEqual(len(call.args), 1)
        program = ast.literal_eval(call.args[0])
        compile(program, '<decoded-guest>', 'exec')
        self.assertEqual('exec(' + repr(program) + ')', wrapper)
        self.assertIn("nonce=" + repr(nonce), program)
        for proof in ('http.server.ThreadingHTTPServer', 'urllib.request.urlopen', 'hashlib.sha256(material.encode())',
                      'actual!=expected', 'instanceNonce=secrets.token_hex(32)', 'sequence+=1',
                      '/sys/fs/cgroup/cpu.max', '/sys/fs/cgroup/memory.max'):
            self.assertIn(proof, program)
        self.assertEqual(hashlib.sha256(program.encode()).hexdigest(), 'af7b5f6aba860fddd4b74af287b6a6b4ffa5465ce6d4b3b48e5cdb8db9070020')

    def test_program_bound_without_unsupported_sdk_features(self):
        nonce = 'a'*32; program = sdk.workload_program(nonce); compile(program, '<guest>', 'exec')
        obj = dict(version=3, services={'api': dict(image='pinned', command=['python3', '-u', '-c', program],
                                                   resources={'requests': {'cpus': 2, 'memory': '805306368B'}, 'limits': {'cpus': 2, 'memory': '805306368B'}})})
        sdk.validate_manifest(obj, 'api', nonce, 2, 805306368, 'pinned')
        for requests in (None, {'cpus':1,'memory':'805306368B'}, {'cpus':True,'memory':'805306368B'}):
            bad=copy.deepcopy(obj); bad['services']['api']['resources']['requests']=requests
            with self.assertRaises(sdk.Rejected): sdk.validate_manifest(bad,'api',nonce,2,805306368,'pinned')
        for key in ('ports', 'probes', 'healthCheck', 'mounts'):
            bad = copy.deepcopy(obj); bad['services']['api'][key] = ['unsupported']
            with self.assertRaises(sdk.Rejected): sdk.validate_manifest(bad, 'api', nonce, 2, 805306368, 'pinned')

    def test_preservation_rejects_unrelated_changes_and_new_files(self):
        original = {'scope': '/private/native', 'entries': [{'path': 'unrelated', 'sha256': 'a'}]}
        sdk.preserve_baseline(original, copy.deepcopy(original))
        for after in [{'scope': '/private/native', 'entries': []}, {'scope': '/private/native', 'entries': original['entries']+[{'path': 'unknown'}]}]:
            with self.assertRaises(sdk.Rejected): sdk.preserve_baseline(original, after)
        owned = copy.deepcopy(original); owned['entries'].append({'path': 'containers/owned/rootfs'})
        sdk.preserve_baseline(original, owned, ['containers/owned'])

    def test_duplicate_json_and_boolean_resources_rejected(self):
        with self.assertRaises(sdk.Rejected): sdk.decode('{"passed":true,"passed":false}')
        obj = self.status(); obj['services'][0]['observed']['allocation']['cpuCount'] = True
        with self.assertRaises(sdk.Rejected): sdk.validate_status(obj, 'api', 'owned', 1, 805306368)

    def test_secure_native_records_reject_corruption_and_preserve_complete_metadata(self):
        with tempfile.TemporaryDirectory(prefix='.hwq-sdk-records-', dir=Path.home()) as temporary:
            root = Path(temporary); directory = root/'state/records'; directory.mkdir(parents=True, mode=0o700)
            (root/'state').chmod(0o700)
            context = dict(resourceUUID='11111111-1111-4111-8111-111111111111', projectResourceUUID='22222222-2222-4222-8222-222222222222',
                           providerID='apple-containerization', resourceGeneration=1, projectGeneration=1, providerGeneration=1,
                           fencingToken='33333333-3333-4333-8333-333333333333')
            labels = {'dev.hostwright.'+label: str(context[key]) for key, label in [('resourceUUID','resource-uuid'), ('projectResourceUUID','project-uuid'),
                       ('providerID','provider-id'), ('resourceGeneration','resource-generation'), ('projectGeneration','project-generation'),
                       ('providerGeneration','provider-generation'), ('fencingToken','fencing-token')]}
            record = dict(resourceIdentifier='owned', resourceUUID=context['resourceUUID'], projectUUID=context['projectResourceUUID'], mutationContext=context,
                          labels=[dict(key=key,value=value) for key,value in labels.items()], cpuCount=1, memoryBytes=536870912, allocationVerified=True)
            path = directory/(hashlib.sha256(b'owned').hexdigest()+'.json'); path.write_text(json.dumps(record)); path.chmod(0o600)
            value = sdk.record_inventory(root); self.assertEqual(value[0]['record'], record)
            self.assertEqual(value[0]['scope'], 'native-persisted-configuration')
            record['cpuCount'] = 0; path.write_text(json.dumps(record))
            with self.assertRaises(sdk.Rejected): sdk.record_inventory(root)
            path.unlink(); path.symlink_to(root/'missing')
            with self.assertRaises(sdk.Rejected): sdk.record_inventory(root)

    def test_full_inventory_rejects_symlink_and_does_not_omit_empty_file(self):
        with tempfile.TemporaryDirectory(prefix='.hwq-sdk-files-', dir=Path.home()) as temporary:
            root = Path(temporary); empty = root/'empty'; empty.write_bytes(b''); empty.chmod(0o600)
            snapshot = sdk.filesystem_inventory(root)
            self.assertEqual(snapshot['entries'][0]['sha256'], hashlib.sha256(b'').hexdigest())
            (root/'link').symlink_to(empty)
            with self.assertRaises(sdk.Rejected): sdk.filesystem_inventory(root)

    def test_unmanaged_process_and_tart_identity_preservation(self):
        raw = '123 1 1024 Sun Sep 13 12:00:00 2026 /Applications/Unmanaged\n'
        before = sdk.unmanaged_processes(raw, ['/Applications/Unmanaged'])
        sdk.preserve_unmanaged_processes(before, copy.deepcopy(before))
        changed = copy.deepcopy(before); changed[0]['pid'] = 124
        with self.assertRaises(sdk.Rejected): sdk.preserve_unmanaged_processes(before, changed)
        tart = [{'Name':'lab', 'Source':'local', 'State':'stopped', 'Running':False}]
        sdk.preserve_tart(tart, copy.deepcopy(tart))
        changed = copy.deepcopy(tart); changed[0]['Running'] = True
        with self.assertRaises(sdk.Rejected): sdk.preserve_tart(tart, changed)


class SDKWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('sdk_harness', Path(__file__).with_name('authenticated-lifecycle.py'))
        cls.q = importlib.util.module_from_spec(spec); spec.loader.exec_module(cls.q)

    def beat(self, sequence, instance):
        value = SDKBoundaryTests().heartbeat(sequence); value['instanceNonce'] = instance*64
        return 'HWQSDK '+json.dumps(value)

    def test_restart_selects_only_current_instance_and_rejects_old_replay(self):
        previous = sdk.current_heartbeat(self.beat(10,'b'),'a'*32,2,805306368)
        current = sdk.current_heartbeat(self.beat(10,'b')+'\n'+self.beat(1,'c'),'a'*32,2,805306368,previous,True)
        self.assertEqual(current['sequence'],1)
        with self.assertRaises(sdk.Rejected): sdk.current_heartbeat(self.beat(11,'b'),'a'*32,2,805306368,previous,True)
        with self.assertRaises(sdk.Rejected): sdk.current_heartbeat(self.beat(1,'c'),'a'*32,2,805306368,previous)
        with self.assertRaises(sdk.Rejected): sdk.current_heartbeat(self.beat(1,'c')+'\n'+self.beat(10,'b')+'\n'+self.beat(2,'c'),'a'*32,2,805306368)

    def test_current_instance_rejects_old_run_nonce_and_missing_instance(self):
        raw = self.beat(1,'b').replace('"nonce": "'+('a'*32)+'"','"nonce": "'+('d'*32)+'"')
        with self.assertRaises(sdk.Rejected): sdk.current_heartbeat(raw,'a'*32,2,805306368)
        with self.assertRaises(sdk.Rejected): sdk.current_heartbeat('HWQSDK '+json.dumps(SDKBoundaryTests().heartbeat()),'a'*32,2,805306368)

    def test_streaming_inventory_defers_only_exact_owned_disk(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory(dir=Path.home()) as name:
            root=Path(name); root.chmod(0o700)
            owned=root/'owned'; owned.mkdir(mode=0o700)
            disk=owned/'disk'; disk.write_bytes(b'x'*2097152); disk.chmod(0o600)
            unrelated=root/'unrelated'; unrelated.write_bytes(b'original'); unrelated.chmod(0o600)
            before=sdk.filesystem_inventory(root,owned_prefixes=['owned'])
            with patch.object(sdk,'secure_read',side_effect=AssertionError('whole-file reading forbidden')):
                after=sdk.filesystem_inventory(root,owned_prefixes=['owned'])
            sdk.preserve_baseline(before,after,['owned'])
            unrelated.write_bytes(b'changed')
            with self.assertRaises(sdk.Rejected): sdk.preserve_baseline(before,sdk.filesystem_inventory(root,owned_prefixes=['owned']),['owned'])
            self.assertTrue(next(x for x in before['entries'] if x['path']=='owned/disk')['ownedContentDeferred'])

    def test_seed_receipt_is_real_exact_native_field_binding(self):
        # Guard the emitted SDK seeder keys against accidental harness aliases.
        source=Path(self.q.__file__).read_text()
        for field in ('OCITreeSHA256','descriptorDigest','variantDigest','dataRootPath'): self.assertIn(field,source)
        self.assertNotIn("receipt.get('passed')",source)

    def test_raw_ndjson_receipts_and_timeout_never_complete(self):
        from unittest.mock import patch
        import subprocess,time
        q=self.q
        with tempfile.TemporaryDirectory(dir=Path.home()) as name:
            h=q.Harness.__new__(q.Harness); h.evidence=Path(name); h.sequence=0; h.receipts=[]; h.env={}; h.observation_deadline=None
            raw=b'{"sequence":0}\n{"sequence":1}\n'
            with patch.object(q.subprocess,'run',return_value=subprocess.CompletedProcess(['bound'],0,raw,b'')):
                self.assertEqual(h.command(['bound'],raw=True),raw.decode())
            self.assertEqual(len(h.receipts),1)
            with patch.object(q.subprocess,'run',side_effect=subprocess.TimeoutExpired(['bound'],1,output=b'partial')):
                with self.assertRaises(q.Rejected): h.command(['bound'],raw=True)
            self.assertTrue(h.receipts[-1]['timedOut']); self.assertEqual(h.receipts[-1]['exitCode'],124)
            self.assertFalse(q.completion({},'cycles',h.receipts))
            h.observation_deadline=time.monotonic()-1
            with patch.object(q.subprocess,'run') as run:
                with self.assertRaises(q.Rejected): h.command(['bound'])
                run.assert_not_called()

    def test_sdk_missing_bindings_rejects_arbitrary_boolean(self):
        with self.assertRaisesRegex(self.q.Rejected,'SDK blocked'):
            self.q.validate_sdk_inputs(None,{'observer':{'passed':True}})

    def test_changed_observer_source_rejected_before_sdk_mutation(self):
        import types
        args=types.SimpleNamespace(source_root=str(Path.home()))
        with self.assertRaisesRegex(self.q.Rejected,'binding mismatch'):
            self.q.validate_sdk_inputs(args,{'sdk':{'harnessSHA256':'0'*64,'observerSHA256':'0'*64}})

    def test_sdk_manifest_rejects_boolean_cpu_limit(self):
        nonce='a'*32
        manifest={'version':3,'services':{'api':{'image':'pinned','command':['python3','-u','-c',sdk.workload_program(nonce)],'resources':{'limits':{'cpus':True,'memory':'536870912B'}}}}}
        with self.assertRaises(sdk.Rejected): sdk.validate_manifest(manifest,'api',nonce,1,536870912,'pinned')

    def test_stop_remove_requires_authenticated_actual_state(self):
        value=SDKBoundaryTests().status()
        with self.assertRaises(sdk.Rejected): sdk.validate_stopped_status(value,'api','owned')
        value['services'][0]['observed']['lifecycle']='stopped'
        sdk.validate_stopped_status(value,'api','owned')
        with self.assertRaises(sdk.Rejected): sdk.validate_stopped_status(value,'api')
        value['services'][0].pop('observed'); sdk.validate_stopped_status(value,'api')
        value['runtime']['observed']=False
        with self.assertRaises(sdk.Rejected): sdk.validate_stopped_status(value,'api')

    def test_observe_sdk_uses_charged_reservation_before_native_health(self):
        import sqlite3,types
        q=self.q; project_uuid='22222222-2222-4222-8222-222222222222'
        with tempfile.TemporaryDirectory(dir=Path.home()) as name:
            root=Path(name); database=root/'support/state/state.sqlite'; database.parent.mkdir(parents=True)
            with sqlite3.connect(database) as connection:
                connection.executescript("CREATE TABLE projects(id TEXT,name TEXT,resource_uuid TEXT); CREATE TABLE scheduler_reservations(project_uuid TEXT,status TEXT,resource_vector_json TEXT); CREATE TABLE ownership_records(project_id TEXT); CREATE TABLE network_port_reservations(project_uuid TEXT,lifecycle_state TEXT);")
                connection.execute('INSERT INTO projects VALUES(?,?,?)',('project','qualification',project_uuid))
                connection.execute('INSERT INTO scheduler_reservations VALUES(?,?,?)',(project_uuid,'committed','{"cpu":1,"memory":536870912}'))
            h=q.Harness.__new__(q.Harness); h.a=types.SimpleNamespace(state_root=str(root),project='qualification',cpus=1,memory_bytes=536870912)
            h.inventory=lambda:[{'project':'qualification','id':'../unsafe','nativeInventory':{'record':{}}}]
            h.unmanaged=lambda inventory:[]; h.baseline=[]; h.sdk_config={'framework':'0.35.0'}
            with self.assertRaisesRegex(q.sdk.Rejected,'admission charge mismatch'): h.observe_sdk('up')
            with sqlite3.connect(database) as connection:
                connection.execute('UPDATE scheduler_reservations SET resource_vector_json=?',('{"cpu":2,"memory":671088640}',))
            # Correct accounting reaches the next independent native identity gate.
            with self.assertRaisesRegex(q.Rejected,'unsafe owned SDK resource'): h.observe_sdk('up')

    def test_rm_rejects_leaked_ports_with_no_native_or_durable_ownership(self):
        import sqlite3,types
        q=self.q; project_uuid='22222222-2222-4222-8222-222222222222'
        with tempfile.TemporaryDirectory(dir=Path.home()) as name:
            root=Path(name); database=root/'support/state/state.sqlite'; database.parent.mkdir(parents=True)
            with sqlite3.connect(database) as connection:
                connection.executescript("CREATE TABLE projects(id TEXT,name TEXT,resource_uuid TEXT); CREATE TABLE scheduler_reservations(project_uuid TEXT,status TEXT); CREATE TABLE ownership_records(project_id TEXT); CREATE TABLE network_port_reservations(project_uuid TEXT,lifecycle_state TEXT);")
                connection.execute('INSERT INTO projects VALUES(?,?,?)',('project','qualification',project_uuid))
            h=q.Harness.__new__(q.Harness); h.a=types.SimpleNamespace(state_root=str(root),project='qualification')
            h.inventory=lambda:[]; h.unmanaged=lambda inventory:[]; h.baseline=[]; h.sdk_project_uuid=project_uuid
            for state in ('planned','published','removing'):
                with self.subTest(state=state):
                    with sqlite3.connect(database) as connection:
                        connection.execute('DELETE FROM network_port_reservations')
                        connection.execute('INSERT INTO network_port_reservations VALUES(?,?)',(project_uuid,state))
                    with self.assertRaisesRegex(q.Rejected,'SDK unsupported port reservation'): h.observe_sdk('rm')
            # Even if rm removed the project row, the previously validated UUID remains authoritative.
            with sqlite3.connect(database) as connection: connection.execute('DELETE FROM projects')
            with self.assertRaisesRegex(q.Rejected,'SDK unsupported port reservation'): h.observe_sdk('rm')

    def test_rm_rejects_changed_or_never_validated_project_uuid(self):
        import sqlite3,types
        q=self.q
        with tempfile.TemporaryDirectory(dir=Path.home()) as name:
            root=Path(name); database=root/'support/state/state.sqlite'; database.parent.mkdir(parents=True)
            with sqlite3.connect(database) as connection:
                connection.execute('CREATE TABLE projects(resource_uuid TEXT,name TEXT)')
                connection.execute('INSERT INTO projects VALUES(?,?)',('22222222-2222-4222-8222-222222222222','qualification'))
            h=q.Harness.__new__(q.Harness); h.a=types.SimpleNamespace(state_root=str(root),project='qualification')
            h.inventory=lambda:[]; h.unmanaged=lambda inventory:[]; h.baseline=[]
            with self.assertRaisesRegex(q.Rejected,'previously validated'): h.observe_sdk('rm')
            h.sdk_project_uuid='33333333-3333-4333-8333-333333333333'
            with self.assertRaisesRegex(q.Rejected,'UUID missing/changed'): h.observe_sdk('rm')

if __name__ == '__main__': unittest.main()
