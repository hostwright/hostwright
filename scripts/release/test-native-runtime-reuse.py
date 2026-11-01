#!/usr/bin/env python3
"""Synthetic boundary tests; these fixtures never constitute release evidence."""

import copy
import importlib.util
import io
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


N = module('native_reuse_tests', 'verify-native-reuse.py')
I, R = N.I, N.R
P = module('native_prepare_tests', 'test-prepare-runtime-provenance.py')


def api_fixture(commit='a' * 40):
    run = dict(id=123, run_attempt=2, repository=dict(full_name=R.REPO), path=R.WORKFLOW,
               head_branch='main', event='workflow_dispatch', status='completed', conclusion='success', head_sha=commit)
    jobs = [dict(id=456, name=R.JOB, run_id=123, run_attempt=2, status='completed', conclusion='success')]
    artifacts = [dict(id=789, name=f'runtime-build-ingredients-{commit}-123-2', expired=False,
                      size_in_bytes=100, digest='sha256:'+'b'*64, workflow_run=dict(id=123, head_sha=commit))]
    return run, jobs, artifacts


class NativeResolverTests(unittest.TestCase):
    def test_exact_original_attempt_and_unique_artifact(self):
        result = R.select(*api_fixture(), 123, 2)
        self.assertEqual(result['producer'], dict(commit='a'*40, runID=123, attempt=2))
        self.assertEqual(result['artifact']['jobID'], 456)

    def test_rejects_wrong_producer_job_artifact_and_ambiguous_selection(self):
        mutations = [
            (0, 'id', 124), (0, 'run_attempt', 1), (0, 'head_branch', 'other'),
            (0, 'event', 'pull_request'), (0, 'conclusion', 'failure'),
            (0, 'repository', {'full_name':'other/repo'}), (0, 'path', 'other.yml'),
            (1, 'run_id', 124), (1, 'run_attempt', 1), (1, 'conclusion', 'failure'),
            (2, 'expired', True), (2, 'digest', 'sha256:missing'), (2, 'size_in_bytes', R.MAX_ZIP+1),
            (2, 'workflow_run', {'id':123, 'head_sha':'c'*40}),
        ]
        for index, key, value in mutations:
            with self.subTest(index=index, key=key):
                values = list(api_fixture())
                (values[index] if index == 0 else values[index][0])[key] = value
                with self.assertRaises(ValueError): R.select(*values, 123, 2)
        for index in (1, 2):
            values = list(api_fixture()); values[index] *= 2
            with self.assertRaises(ValueError): R.select(*values, 123, 2)
        for value in ('', '0', '-1', '1.0', ' 1', True):
            with self.assertRaises(ValueError): R.positive(value)

    def test_archive_extraction_rejects_unsafe_members(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for index, (name, mode) in enumerate([
                ('../outside', stat.S_IFREG), ('/outside', stat.S_IFREG),
                ('evidence/../outside', stat.S_IFREG), ('evidence/link', stat.S_IFLNK),
                ('unexpected/file', stat.S_IFREG), ('evidence/device', stat.S_IFCHR),
                ('evidence\\outside', stat.S_IFREG),
            ]):
                archive = root/f'{index}.zip'
                with zipfile.ZipFile(archive, 'w') as bundle:
                    member = zipfile.ZipInfo(name); member.external_attr = (mode|0o600)<<16
                    bundle.writestr(member, b'unsafe')
                with self.assertRaises(ValueError): R.extract(archive, root/f'out-{index}')
            archive = root/'valid.zip'
            with zipfile.ZipFile(archive, 'w') as bundle: bundle.writestr('evidence/file', b'bytes')
            R.extract(archive, root/'valid')
            self.assertEqual((root/'valid/evidence/file').read_bytes(), b'bytes')
            with mock.patch.object(R, 'MAX_EXPANDED', 1):
                with self.assertRaises(ValueError): R.extract(archive, root/'too-big')
            with mock.patch.object(R.shutil, 'disk_usage', return_value=mock.Mock(free=0)):
                with self.assertRaisesRegex(ValueError, 'disk space'): R.extract(archive, root/'no-space')
                self.assertEqual(list((root/'no-space').iterdir()), [])

    def test_download_binds_zip_digest_and_size(self):
        data = b'exact zip bytes'
        resolution = R.select(*api_fixture(), 123, 2)
        resolution['artifact'].update(sizeBytes=len(data), sha256=I.digest(data))
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(R.os.environ, GH_TOKEN='test-token'):
            for index, delivered in enumerate((data, data+b'extra', b'wrong')):
                opener = mock.Mock(); opener.open.return_value = io.BytesIO(delivered)
                with mock.patch.object(R.urllib.request, 'build_opener', return_value=opener):
                    if index == 0: R.download(resolution, Path(directory)/str(index))
                    else:
                        with self.assertRaises(ValueError): R.download(resolution, Path(directory)/str(index))

    def test_redirect_never_forwards_token_to_storage(self):
        handler = R.ArtifactRedirect()
        request = urllib.request.Request('https://api.github.com/artifact', headers={'Authorization':'Bearer test'})
        redirected = handler.redirect_request(request, None, 302, '', {}, 'https://storage.example.invalid/file')
        self.assertIsNone(redirected.get_header('Authorization'))
        for url in ('http://storage.example.invalid/file', 'https://user:pass@storage.example.invalid/file'):
            with self.assertRaises(ValueError): handler.redirect_request(request, None, 302, '', {}, url)

    def test_checkpoint_pairing_rejects_before_any_api_or_download(self):
        with tempfile.TemporaryDirectory() as directory:
            for values in (dict(NATIVE_CHECKPOINT_RUN='123'),dict(NATIVE_CHECKPOINT_ATTEMPT='2'),
                           dict(NATIVE_CHECKPOINT_RUN='123',NATIVE_CHECKPOINT_ATTEMPT='2',SDK_CHECKPOINT_RUN='11')):
                env=dict(GITHUB_REPOSITORY=R.REPO,**values)
                with mock.patch.dict(R.os.environ,env,clear=True), \
                     mock.patch.object(sys,'argv',['resolve-native-checkpoint.py','--output',directory+'/output']), \
                     mock.patch.object(R,'api') as api:
                    with self.assertRaises(ValueError):R.main()
                    api.assert_not_called()


class NativeProofTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.repo = cls.root/'repo'; cls.repo.mkdir()
        def git(*args): return subprocess.check_output(['git','-C',str(cls.repo),*args], stderr=subprocess.PIPE).decode().strip()
        cls.git = staticmethod(git)
        git('init','-q','-b','main'); git('config','user.name','Native reuse tests'); git('config','user.email','test@example.invalid')
        current_workflow = (ROOT/I.WORKFLOW).read_bytes()
        jobs = I.jobs(current_workflow)
        old_workflow = current_workflow.replace(jobs['native-checkpoint'].encode(), b'').replace(I.EMPTY_NATIVE.encode(), b'')
        current_verifier = (ROOT/I.VERIFIER).read_bytes()
        old_verifier = current_verifier.replace(I.HOOK.encode(), b'').replace(I.NEW_MODE.encode(), I.OLD_MODE.encode())
        names = [*I.FILES, *I.CONSUMERS, 'scripts/release/build-static-swift-sdk.sh',
                 'scripts/release/runtime-swift-sources.json', 'scripts/release/materialize-swift-sdk-sources.py']
        cls.old = {name:(ROOT/name).read_bytes() if (ROOT/name).is_file() else b'fixture\n' for name in names}
        cls.old.update({p.relative_to(ROOT).as_posix():p.read_bytes() for p in (HERE/'patches/swift-sdk').rglob('*') if p.is_file()})
        cls.old.update({I.WORKFLOW:old_workflow, I.VERIFIER:old_verifier,
                        'ThirdPartyLicenses/runtime-build-recipes/fixture':b'pinned native config\n',
                        'Guest/fixture':b'pinned guest source\n', 'contracts/v0.0.2/fixture':b'asset contract\n'})
        def write(files):
            for name, data in files.items():
                path=cls.repo/name; path.parent.mkdir(parents=True,exist_ok=True); path.write_bytes(data)
        write(cls.old)
        write({'main.c':b'int main() { return 0; }\n','LICENSE':b'Fixture license text\n','NOTICE':b'Fixture notice text\n'})
        git('add','.'); git('commit','-qm','Original native fixture'); cls.producer=git('rev-parse','HEAD')
        cls.new = dict(cls.old, **{I.WORKFLOW:current_workflow, I.VERIFIER:current_verifier})
        cls.new.update({name:(ROOT/name).read_bytes() for name in I.ADDITIONS})
        write(cls.new); git('add','.'); git('commit','-qm','Reuse consumer fixture'); cls.consumer=git('rev-parse','HEAD')
        cls.evidence=cls.root/'proof'; cls.evidence.mkdir()
        cls.comparison=I.prepare(cls.repo,cls.producer,cls.consumer,cls.evidence)

    def fetch(self, name): return (self.evidence/name).read_bytes()

    def test_complete_git_object_proof_and_exact_recipe(self):
        result=I.verify(self.comparison,self.fetch,self.producer,self.consumer)
        self.assertEqual(result, I.compare_files(self.old,self.new))
        self.assertEqual(len(result['sdkCompileInputs']['sha256']), 64)

    def test_every_closed_tree_rejects_changed_inputs_or_membership(self):
        for name in self.old:
            if name in (*I.CONSUMERS,I.VERIFIER,I.WORKFLOW): continue
            with self.subTest(name=name):
                changed=dict(self.new); changed[name]+=b'changed'
                with self.assertRaises(ValueError): I.compare_files(self.old,changed)
                del changed[name]
                with self.assertRaises(ValueError): I.compare_files(self.old,changed)
        for name in ('scripts/release/unnamed.py','Guest/new','ThirdPartyLicenses/new','contracts/v0.0.2/new'):
            with self.assertRaises(ValueError): I.compare_files(self.old,dict(self.new, **{name:b'new'}))

    def test_workflow_globals_jobs_steps_and_verifier_are_closed(self):
        raw=self.new[I.WORKFLOW]
        variants=[raw+b'env:\n  CC: altered\n', raw+b'jobs:\n',
                  raw.replace(b'permissions: {}',b'permissions:\n  contents: write'),
                  raw.replace(b'runs-on: ubuntu-24.04-arm',b'runs-on: other',1),
                  raw.replace(b'      - name: Install pinned Swift SDK build prerequisites',b'      - run: arbitrary-command\n      - name: Install pinned Swift SDK build prerequisites'),
                  raw.replace(b'          persist-credentials: false',b'          persist-credentials: true',1),
                  raw.replace(b'  native-checkpoint:',b'  other-checkpoint:')]
        for value in variants:
            with self.assertRaises(ValueError): I.compare_files(self.old,dict(self.new, **{I.WORKFLOW:value}))
        for value in (self.new[I.VERIFIER]+b'\n# unreviewed change\n', self.new[I.VERIFIER].replace(I.HOOK.encode(),b'')):
            with self.assertRaises(ValueError): I.compare_files(self.old,dict(self.new, **{I.VERIFIER:value}))

    def test_git_membership_mode_commit_and_ancestry_cannot_be_receipt_booleans(self):
        for alter in (
            lambda p:p['consumer']['files'].pop('Guest/fixture'),
            lambda p:p['consumer']['files']['Guest/fixture'].update(mode='100755'),
            lambda p:p['consumer'].update(commit='f'*40),
            lambda p:p.update(ancestry={}),
            lambda p:p['comparison']['unchanged'].update({'Guest/fixture':'f'*64}),
        ):
            proof=copy.deepcopy(self.comparison); alter(proof)
            with self.assertRaises(ValueError): I.verify(proof,self.fetch,self.producer,self.consumer)
        def corrupted(name):
            data=self.fetch(name)
            return data+b'changed' if '/blobs/' in name else data
        with self.assertRaises(ValueError): I.verify(self.comparison,corrupted,self.producer,self.consumer)

    def proof(self, native):
        files={p.relative_to(self.evidence).as_posix():p.read_bytes() for p in self.evidence.rglob('*') if p.is_file()}
        def record(name,data):
            files[name]=data
            return dict(path=name,sha256=I.digest(data),sizeBytes=len(data))
        sdk_producer=dict(commit='d'*40,runID=11,attempt=1)
        archive=b'original synthetic SDK archive'
        sdk_reuse=dict(kind='hostwright.swift-sdk-reuse-compatibility.v1',status='compatible-not-release-qualified',
                       sourceCommit=self.producer,producer=dict(commit=sdk_producer['commit']),
                       sourceInventory=dict(sdkArchiveSHA256=I.digest(archive)),compileInputs=self.comparison['comparison']['sdkCompileInputs'])
        members={'evidence/sdk-producer.json':I.canonical(sdk_producer), 'evidence/sdk-reuse.json':I.canonical(sdk_reuse),
                 'evidence/swift-static-sdk.tar.gz':archive, 'runtime-native-fragment/native-provenance.json':I.canonical(native),
                 'evidence/source-map.json':b'{"fixture":"original source map"}\n'}
        checksum=''.join(I.digest(data)+'  '+name+'\n' for name,data in sorted(members.items())).encode()
        members['checksums.sha256']=checksum
        subjects={key:dict(subject=record('subjects/'+key,members[name]),bundle=record('subjects/'+key+'.bundle',b'synthetic bundle'),
                           verification=record('subjects/'+key+'.verification',b'[]')) for key,name in N.SUBJECTS.items()}
        resolution=R.select(*api_fixture(self.producer),123,2)
        proof=dict(kind=N.KIND,schemaVersion=1,status='authenticated-unchanged-inputs-not-release-qualified',sourceCommit=self.consumer,
                   producer=resolution['producer'],artifact=resolution['artifact'],resolution=record('resolution.json',I.canonical(resolution)),
                   subjects=subjects,sdk={key:record('sdk/'+name,members['evidence/'+name]) for key,name in (
                       ('producer','sdk-producer.json'),('reuse','sdk-reuse.json'),('archive','swift-static-sdk.tar.gz'))},
                   inputComparison=copy.deepcopy(self.comparison))
        return proof,files

    def test_original_native_claim_and_sdk_chain_remain_bound(self):
        native=dict(sourceCommit=self.producer,status='prepared-not-release-qualified')
        proof,files=self.proof(native)
        self.assertEqual(N.validate(proof,files.__getitem__,self.consumer),native)
        for alter in (lambda p:p['producer'].update(attempt=1), lambda p:p['artifact'].update(id=999),
                      lambda p:p.update(sourceCommit=self.producer), lambda p:p['subjects'].pop('sourceMap'),
                      lambda p:p['sdk'].pop('archive')):
            changed=copy.deepcopy(proof); alter(changed)
            with self.assertRaises((ValueError,KeyError)): N.validate(changed,files.__getitem__,self.consumer)
        files[proof['sdk']['archive']['path']]+=b'changed'
        with self.assertRaises(ValueError): N.validate(proof,files.__getitem__,self.consumer)
        proof,files=self.proof(dict(native,sourceCommit=self.consumer))
        with self.assertRaisesRegex(ValueError,'rebased'): N.validate(proof,files.__getitem__,self.consumer)

    def test_composition_preserves_native_bytes_and_fresh_loader_and_explicit_mode(self):
        fixture=P.RuntimePreparationTests(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        fixture.commit=self.consumer; fixture.native_fragment['sourceCommit']=self.producer
        fixture.loader_fragment['sourceCommit']=self.consumer
        source_files={}; inventory=[]
        for row in self.git('ls-tree','-r',self.consumer).splitlines():
            metadata,name=row.split('\t'); mode,kind,blob=metadata.split()
            data=(self.repo/name).read_bytes();source_files[name]=data
            inventory.append(dict(path=name,gitMode=mode,gitBlobSHA1=blob,sha256=I.digest(data),sizeBytes=len(data)))
        def retained(name,data):
            fixture.write(fixture.loader,name,data)
            return dict(path=name,sha256=I.digest(data),sizeBytes=len(data))
        project=dict(identity='current-loader',commit=self.consumer,tree=self.git('rev-parse',self.consumer+'^{tree}'),spdx='MIT',
                     commitObject=retained('current/source.commit',I.git(self.repo,'cat-file','commit',self.consumer)),
                     archive=retained('current/source.tar.gz',P.F.tar(source_files)),
                     inventory=retained('current/source-inventory.json',I.canonical(inventory)),patches=[])
        for key,name in (('licenses','LICENSE'),('notices','NOTICE')):
            project[key]=[dict(retained('current/'+name,source_files[name]),sourcePath=name,component='current-loader',spdx='MIT')]
        fixture.loader_fragment['sourceProjects']=[project]
        for item in fixture.loader_fragment['loader']['selectedInputs']:
            for source in item['sourceFiles']:source['project']='current-loader'
        fixture.save_fragments()
        proof,files=self.proof(fixture.native_fragment)
        reuse=fixture.root/'reuse'; reuse.mkdir()
        for name,data in files.items(): fixture.write(reuse,name,data)
        fixture.write(reuse,'native-reuse.json',I.canonical(proof))
        manifest=P.P.prepare(fixture.native,fixture.loader,self.consumer,999,1,fixture.output,native_reuse_root=reuse)
        self.assertEqual(manifest['closureMode'],'authenticated-native-reuse')
        self.assertEqual(manifest['producer']['commit'],self.consumer)
        self.assertEqual(manifest['nativeReuse']['producer']['commit'],self.producer)
        self.assertEqual((fixture.output/'reuse/subjects/nativeManifest').read_bytes(),I.canonical(fixture.native_fragment))
        fetch=lambda name:(fixture.output/name).read_bytes()
        runtime=json.loads((fixture.output/'licenses/runtime-license-inventory.json').read_bytes())
        current_calls=[]; original_calls=[]
        def current_authentication(filename,producer,source):
            self.assertEqual(source,self.consumer)
            self.assertEqual(producer,dict(commit=self.consumer,runID=999,attempt=1))
            current_calls.append(Path(filename).read_bytes())
        def original_authentication(argv,**kwargs):
            self.assertIn('--bundle',argv)
            self.assertEqual(argv[argv.index('--source-digest')+1],self.producer)
            self.assertEqual(argv[argv.index('--signer-digest')+1],self.producer)
            data=Path(argv[3]).read_bytes();original_calls.append(data)
            cert=dict(issuer='https://token.actions.githubusercontent.com',buildSignerURI=f'https://github.com/{R.REPO}/{R.WORKFLOW}@refs/heads/main',
                      buildSignerDigest=self.producer,sourceRepositoryURI='https://github.com/'+R.REPO,
                      sourceRepositoryDigest=self.producer,sourceRepositoryRef='refs/heads/main',runnerEnvironment='github-hosted',
                      runInvocationURI=f'https://github.com/{R.REPO}/actions/runs/123/attempts/2')
            verified=[dict(verificationResult=dict(signature=dict(certificate=cert),verifiedTimestamps=[dict(type='transparency-log')],
                       statement=dict(subject=[dict(digest=dict(sha256=I.digest(data)))])))]
            return subprocess.CompletedProcess(argv,0,I.canonical(verified))
        with mock.patch.object(P.P.V,'authenticate',side_effect=current_authentication), \
             mock.patch.object(N.subprocess,'run',side_effect=original_authentication):
            P.P.V.verify(I.canonical(manifest),runtime,fixture.payloads,fetch,self.consumer)
        self.assertEqual(len(current_calls),1+len(fixture.payloads))
        self.assertEqual(set(original_calls),{files[row['subject']['path']] for row in proof['subjects'].values()})
        for changed in (dict(manifest,closureMode='new-source-build'),
                        {k:v for k,v in manifest.items() if k!='nativeReuse'}):
            with self.assertRaisesRegex(ValueError,'contract'):
                P.P.V.verify(I.canonical(changed),runtime,fixture.payloads,fetch,self.consumer,require_authentication=False)
        missing_license=manifest['sourceProjects'][0]['licenses'][0]['path']
        with self.assertRaises(ValueError):
            P.P.V.verify(I.canonical(manifest),runtime,fixture.payloads,
                         lambda name:b'altered' if name==missing_license else fetch(name),self.consumer,require_authentication=False)
        for key in ('kernel','sourceProjects','payloads'):
            changed=copy.deepcopy(manifest)
            if key=='kernel':changed[key]['project']='other'
            else:changed[key]=[]
            with self.assertRaises(ValueError):N.verify_composition(changed,fetch,self.consumer,False)
        fixture.loader_fragment['sourceCommit']=self.producer;fixture.save_fragments()
        with self.assertRaisesRegex(ValueError,'source/status'):
            P.P.prepare(fixture.native,fixture.loader,self.consumer,999,1,fixture.root/'stale-loader',native_reuse_root=reuse)
        with self.assertRaisesRegex(ValueError,'source/status'):
            P.P.prepare(fixture.native,fixture.loader,self.consumer,999,1,fixture.root/'no-proof')


class NativeAuthenticationTests(unittest.TestCase):
    def test_crypto_verifier_and_exact_certificate_producer_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            subject=Path(directory)/'subject';subject.write_bytes(b'original bytes');bundle=Path(directory)/'bundle';bundle.write_bytes(b'bundle')
            producer=dict(commit='a'*40,runID=123,attempt=2)
            cert=dict(issuer='https://token.actions.githubusercontent.com',buildSignerURI=f'https://github.com/{R.REPO}/{R.WORKFLOW}@refs/heads/main',
                      buildSignerDigest=producer['commit'],sourceRepositoryURI='https://github.com/'+R.REPO,
                      sourceRepositoryDigest=producer['commit'],sourceRepositoryRef='refs/heads/main',runnerEnvironment='github-hosted',
                      runInvocationURI=f'https://github.com/{R.REPO}/actions/runs/123/attempts/2')
            def result(certificate):
                return subprocess.CompletedProcess([],0,I.canonical([dict(verificationResult=dict(signature=dict(certificate=certificate),
                    verifiedTimestamps=[dict(type='transparency-log')],statement=dict(subject=[dict(digest=dict(sha256=I.digest(subject.read_bytes())))])))]))
            with mock.patch.object(N.subprocess,'run',return_value=result(cert)) as run:
                N.verify_attestation(subject,bundle,producer)
                argv=run.call_args.args[0]
                for flag in ('--bundle','--deny-self-hosted-runners','--source-digest','--signer-digest','--cert-identity','--cert-oidc-issuer'):
                    self.assertIn(flag,argv)
            for key in cert:
                with mock.patch.object(N.subprocess,'run',return_value=result(dict(cert,**{key:'wrong'}))):
                    with self.assertRaises(ValueError):N.verify_attestation(subject,bundle,producer)
            with mock.patch.object(N.subprocess,'run',side_effect=subprocess.CalledProcessError(1,['gh'])):
                with self.assertRaises(subprocess.CalledProcessError):N.verify_attestation(subject,bundle,producer)

    def test_carrier_requires_complete_authenticated_file_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'evidence').mkdir();(root/'evidence/file').write_bytes(b'original')
            (root/'checksums.sha256').write_text(I.digest(b'original')+'  evidence/file\n')
            N.verify_carrier(root)
            (root/'evidence/extra').write_bytes(b'not covered')
            with self.assertRaises(ValueError):N.verify_carrier(root)
            (root/'evidence/extra').unlink();(root/'evidence/file').write_bytes(b'changed')
            with self.assertRaises(ValueError):N.verify_carrier(root)
        for raw in (b'a'*64+b'  ../escape\n', (b'a'*64+b'  evidence/file\n')*2, b'not checksums'):
            with self.assertRaises(ValueError):N.checksums(raw)


if __name__=='__main__':unittest.main()
