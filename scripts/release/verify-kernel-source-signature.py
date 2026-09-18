#!/usr/bin/env python3
"""Verify retained kernel.org source bytes with the pinned stable signing identity."""
import argparse,hashlib,json,lzma,os,pathlib,re,stat,subprocess,sys,tempfile
FINGERPRINT='647F28654894E3BD457199BE38DBBDC86092693E'
ARCHIVE_SHA='7c716216c3c4134ed0de69195701e677577bbcdd3979f331c182acd06bf2f170'
def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as stream:
  for chunk in iter(lambda:stream.read(1024*1024),b''):h.update(chunk)
 return h.hexdigest()
def valid_status(status,exit_status):
 signatures=[line.split() for line in status.splitlines() if line.startswith('[GNUPG:] VALIDSIG ')]
 if exit_status!=0 or len(signatures)!=1 or signatures[0][2]!=FINGERPRINT or signatures[0][-1]!=FINGERPRINT:
  raise ValueError('kernel source signature did not verify against the pinned kernel.org fingerprint')
 if any('[GNUPG:] '+name in status for name in ['BADSIG','ERRSIG','REVKEYSIG','EXPKEYSIG','EXPSIG']):raise ValueError('invalid kernel source signing status')
def select_executable(system,requested=None):
 paths={'darwin':'/opt/homebrew/bin/gpg','linux':'/usr/bin/gpg'}
 if system not in paths:raise ValueError('unsupported kernel verification executable')
 selected=pathlib.Path(requested) if requested is not None else pathlib.Path(paths[system])
 if not selected.is_absolute() or '..' in selected.parts:raise ValueError('kernel verification executable requires an absolute path')
 return selected
def trusted_executable(path,expected_sha256=None):
 default=str(path) in {'/opt/homebrew/bin/gpg','/usr/bin/gpg'}
 if not default and not re.fullmatch('[a-f0-9]{64}',expected_sha256 or ''):raise ValueError('private GPG executable requires an exact SHA256 pin')
 resolved=path.resolve(strict=True)
 if not default and resolved!=path:raise ValueError('private GPG path must contain no symlink')
 if str(path)=='/opt/homebrew/bin/gpg':
  if not resolved.is_relative_to('/opt/homebrew/Cellar/gnupg') or resolved.name!='gpg':raise ValueError('Homebrew GPG target escapes the trusted package path')
 elif str(path)=='/usr/bin/gpg' and resolved!=path:raise ValueError('Linux GPG executable must remain at the trusted system path')
 for candidate in [resolved,*resolved.parents]:
  metadata=candidate.stat()
  if metadata.st_uid not in {0,os.getuid()} or metadata.st_mode & 0o022:raise ValueError('unsafe kernel verification executable ownership or permissions')
 metadata=resolved.stat()
 if not stat.S_ISREG(metadata.st_mode) or not metadata.st_mode & 0o111:raise ValueError('kernel verification executable is not a regular executable')
 if expected_sha256 is not None and sha(resolved)!=expected_sha256:raise ValueError('GPG executable differs from the exact toolchain pin')
 return str(resolved)
def main():
 p=argparse.ArgumentParser();p.add_argument('--inputs',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--gpg');p.add_argument('--gpg-sha256');a=p.parse_args()
 if (a.gpg is None)!=(a.gpg_sha256 is None):raise ValueError('GPG path and SHA256 must be supplied together')
 a.gpg=trusted_executable(select_executable(sys.platform,a.gpg),a.gpg_sha256)
 source=a.inputs/'linux-6.18.15.tar.xz';signature=a.inputs/'linux-6.18.15.tar.sign';key=a.inputs/'gregkh-pinned-public-key.asc'
 for f in [source,signature,key]:
  if f.is_symlink() or not f.is_file():raise ValueError('unsafe signature input')
 if sha(source)!=ARCHIVE_SHA:raise ValueError('kernel source checksum differs from qualified source pin')
 if a.output.exists():raise ValueError('signature receipt output already exists')
 with tempfile.TemporaryDirectory(prefix='hw-gpg-',dir='/tmp') as home:
  subprocess.run([a.gpg,'--batch','--no-autostart','--homedir',home,'--import',str(key)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  command=[a.gpg,'--batch','--no-auto-key-retrieve','--homedir',home,'--status-fd','1','--verify',str(signature),'-']
  with tempfile.TemporaryFile() as stdout,tempfile.TemporaryFile() as stderr:
   process=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=stdout,stderr=stderr)
   try:
    with lzma.open(source,'rb') as stream:
     for chunk in iter(lambda:stream.read(1024*1024),b''):process.stdin.write(chunk)
    process.stdin.close();code=process.wait();stdout.seek(0);stderr.seek(0);status=stdout.read().decode();diagnostics=stderr.read().decode()
   except BaseException:
    process.kill();process.wait();raise
  valid_status(status,code)
  receipt=dict(kind='hostwright.kernel-source-signature.v1',archiveSHA256=ARCHIVE_SHA,signatureSHA256=sha(signature),publicKeySHA256=sha(key),fingerprint=FINGERPRINT,signatureVerified=True,status=status,diagnostics=diagnostics,exitStatus=code,identitySource='https://www.kernel.org/signature.html',verificationExecutable=a.gpg,verificationExecutableSHA256=sha(pathlib.Path(a.gpg)))
  with a.output.open('x') as output:output.write(json.dumps(receipt,sort_keys=True,separators=(',',':'))+'\n')
  print(json.dumps(dict(signatureVerified=True,fingerprint=FINGERPRINT,receipt=str(a.output)),sort_keys=True))
if __name__=='__main__':main()
