import datetime, hashlib, json, os, platform, subprocess, time
from pathlib import Path
ROOT=Path('/SOURCE')
OUT=Path('/EVIDENCE')
HEAD='7bd3575fff351fd4f1b20c694619457ded99a1a6'
PLAN=Path('/REVIEW/issue272-focused-refresh-plan.json')
ENV={k:v for k,v in os.environ.items() if k in {'HOME','PATH','TMPDIR','DEVELOPER_DIR','SDKROOT','LANG','LC_ALL','USER','LOGNAME'}}
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def git(*args): return subprocess.check_output(['git',*args],cwd=ROOT,text=True).strip()
def snapshot():
    return {'head':git('rev-parse','HEAD'),'tree':git('rev-parse','HEAD^{tree}'),'status':git('status','--porcelain'),'fileSHA256':{p:digest(ROOT/p) for p in git('ls-files').splitlines() if (ROOT/p).is_file()}}
def save(name,data):
    with (OUT/name).open('x') as f: json.dump(data,f,indent=2); f.write('\n')
before=snapshot(); assert before['head']==HEAD and not before['status']
save('source-before.json',before)
save('environment.json',{'time':datetime.datetime.now(datetime.timezone.utc).isoformat(),'platform':platform.platform(),'machine':platform.machine(),'swift':subprocess.check_output(['swift','--version'],text=True,env=ENV),'xcode':subprocess.check_output(['xcodebuild','-version'],text=True,env=ENV),'shell':subprocess.check_output(['/bin/bash','--version'],text=True,env=ENV),'planSHA256':digest(PLAN),'scope':'Focused source-security assessment for issue272; not signed release qualification'})
def run(name,command):
    start=time.monotonic(); when=datetime.datetime.now(datetime.timezone.utc).isoformat()
    print(json.dumps({'start':name,'at':when}),flush=True)
    with (OUT/(name+'.log')).open('xb') as f:
        result=subprocess.run(command,cwd=ROOT,env=ENV,stdout=f,stderr=subprocess.STDOUT)
    r={'command':command,'workingDirectory':str(ROOT),'startedAt':when,'finishedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'exitCode':result.returncode,'durationSeconds':time.monotonic()-start,'logSHA256':digest(OUT/(name+'.log'))}
    save(name+'.json',r); print(json.dumps({'end':name,'exitCode':result.returncode,'seconds':r['durationSeconds']}),flush=True)
    return r
records=[]
for name in ['scripts/test-shell-assertions.py','scripts/release/test-homebrew-cask.py','scripts/release/test-staged-release.py','scripts/release/test-assemble-qualification.py','scripts/release/test-swift-test-results.py','scripts/release/test-supported-suite-matrix.py','scripts/release/test_qualify_vendor_tap.py']:
    records.append(run(Path(name).stem,['python3',name]))
    assert records[-1]['exitCode']==0, name
plan=json.loads(PLAN.read_text()); command=plan['command']; command[-1]=str(OUT/'security-selected.xml')
records.append(run('security-selected',command))
records.append(run('compiled-inventory',plan['inventoryCommand']))
if records[-2]['exitCode']==0:
    binaries=subprocess.check_output(['swift','build','--show-bin-path'],cwd=ROOT,env=ENV,text=True).strip()
    records.append(run('docker-proxy-process',['python3','scripts/test-docker-proxy.py',binaries+'/hostwright-docker-proxy']))
    records.append(run('enforced-integration',['/bin/bash','-x','scripts/integration.sh']))
after=snapshot(); save('source-after.json',after)
binaries={str(p.relative_to(ROOT)):digest(p) for p in (ROOT/'.build').glob('**/HostwrightPackageTests.xctest/Contents/MacOS/HostwrightPackageTests')}
result={'sourceUnchanged':before==after,'sourceCommit':HEAD,'sourceTree':before['tree'],'commands':records,'testBinarySHA256':binaries,'allCommandsPassed':all(r['exitCode']==0 for r in records)}
save('run-result.json',result)
assert before==after and result['allCommandsPassed'] and binaries
