#!/usr/bin/env bash
set -euo pipefail

readonly schema='hostwright.phase09.gate13.qualification.manifest.v1'
readonly gate=13
readonly branch='feat/v0.0.2-phase-09'
readonly live_parent='/Volumes/T9/hostwright/qualification'
readonly repository_root='/Users/dev/Documents/hostwright-phase09'
readonly harness_path='/Users/dev/Documents/hostwright-phase09/scripts/phase09-gate13-qualification.sh'
readonly matrix_path='contracts/v0.0.2/phase09-gate13-compatibility-matrix-v1.json'
readonly xctest_observer_source='Tools/Phase09XCTestObserver.m'
readonly test_count=20
readonly frozen_matrix_digest='682d67e855704e8a0229e263f9a6638550c17cdad5e4bc858a381c2e3ce9aa85'
readonly state_header=$'gate\tcell\tstatus\tsource_digest\tconfig_digest\ttoolchain_digest\tstarted_at\tfinished_at\tstdout_sha256\tstderr_sha256\tstructured_result_sha256'
readonly ownership_header=$'recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity'
readonly approved_signing_identity='Developer ID Application: Dev Trivedi (993YC3JY4Q)'
readonly approved_signing_fingerprint='A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB'
readonly approved_signing_team_id='993YC3JY4Q'
readonly test_signing_identity='Hostwright Phase09 Test CMS Signer (P09TEST001)'
readonly test_signing_fingerprint='C0DEC0DEC0DEC0DEC0DEC0DEC0DEC0DEC0DEC0DE'
readonly test_signing_team_id='P09TEST001'
readonly test_signing_certificate_sha256='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
readonly git_path='/usr/bin/git'
readonly awk_path='/usr/bin/awk'
readonly python_path='/usr/bin/python3'
readonly security_path='/usr/bin/security'
readonly openssl_path='/usr/bin/openssl'
readonly shasum_path='/usr/bin/shasum'
readonly jq_path='/usr/bin/jq'
readonly swift_path='/usr/bin/swift'
readonly xcodebuild_path='/usr/bin/xcodebuild'
readonly xcrun_path='/usr/bin/xcrun'
readonly bash_path='/bin/bash'

export PATH='/usr/bin:/bin'

root=''
parent=''
evidence_parent=''
source_commit=''
source_digest_value=''
config_digest_value=''
toolchain_digest_value=''
dependency_digest_value=''
dependency_canonical_digest_value=''
signing_identity=''
signing_fingerprint=''
signing_team_id=''
signing_certificate_sha256=''
root_lock_created=0
gate_lock_created=0
run_succeeded=0
run_active=0
diagnostic_status=0
diagnostic_observed=''

die() {
  printf '%s\n' "$1" >&2
  exit "${2:-70}"
}

now() { /bin/date -u +%Y-%m-%dT%H:%M:%SZ; }
sha() { "$shasum_path" -a 256 "$1" | "$awk_path" '{ print $1 }'; }
stream_sha() { "$shasum_path" -a 256 | "$awk_path" '{ print $1 }'; }
canonical_json_digest() { "$jq_path" -cS . "$1" | stream_sha; }
lowercase() { printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]'; }
uppercase() { printf '%s' "$1" | /usr/bin/tr '[:lower:]' '[:upper:]'; }
testing() { [[ "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" == '1' ]]; }

path_parent() {
  local path="$1" parent="${1%/*}"
  [[ "$parent" == "$path" ]] && parent='.'
  printf '%s\n' "$parent"
}

secure_fs() {
  local operation="$1"
  shift
  "$python_path" - "$operation" "$@" 3<&0 <<'PY'
import ctypes
import fcntl
import os
import secrets
import stat
import subprocess
import sys

O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
O_CLOEXEC = getattr(os, "O_CLOEXEC", 0)
O_CREAT = os.O_CREAT
O_EXCL = os.O_EXCL
RENAME_SWAP = 0x00000002
RENAME_EXCL = 0x00000004
RENAME_NOFOLLOW_ANY = 0x00000010
libc = ctypes.CDLL(None, use_errno=True)
renameatx_np = getattr(libc, "renameatx_np", None)
if renameatx_np is not None:
    renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameatx_np.restype = ctypes.c_int

def fail(message):
    raise RuntimeError(message)

def private_regular(value):
    return stat.S_ISREG(value.st_mode) and value.st_nlink == 1 and value.st_uid == os.getuid() and stat.S_IMODE(value.st_mode) == 0o600

def private_directory(value):
    return stat.S_ISDIR(value.st_mode) and value.st_uid == os.getuid() and stat.S_IMODE(value.st_mode) == 0o700

def identity(value):
    return (value.st_dev, value.st_ino)

directory_bindings = {}

def directory_binding(value):
    if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.getuid() or stat.S_IMODE(value.st_mode) not in (0o700, 0o755):
        fail("directory identity or mode is invalid")
    return (value.st_dev, value.st_ino, value.st_uid, stat.S_IMODE(value.st_mode))

def bind_directory(fd):
    binding = directory_binding(os.fstat(fd))
    directory_bindings[fd] = binding
    return binding

def assert_directory(fd):
    expected = directory_bindings.get(fd)
    if expected is None or directory_binding(os.fstat(fd)) != expected:
        fail("directory identity or mode changed")

def split_path(path):
    if not path.startswith("/") or path.endswith("/") or os.path.normpath(path) != path:
        fail("path must be absolute and name a file")
    parent, name = path.rsplit("/", 1)
    if not parent:
        parent = "/"
    if not name or name in (".", ".."):
        fail("path must name a file")
    return parent, name

def maybe_test_interpose_directory(path):
    if os.environ.get("HOSTWRIGHT_PHASE09_HARNESS_TESTING") != "1" or os.environ.get("HOSTWRIGHT_PHASE09_HARNESS_TEST_DIRECTORY_RACE") != "1":
        return None
    target = os.environ.get("HOSTWRIGHT_PHASE09_HARNESS_TEST_DIRECTORY_RACE_PATH", "")
    replacement = os.environ.get("HOSTWRIGHT_PHASE09_HARNESS_TEST_DIRECTORY_RACE_TARGET", "")
    if path != target:
        return None
    if not replacement.startswith("/") or path in ("/", replacement):
        fail("test directory race paths are invalid")
    backup = path + ".hostwright-directory-race-original"
    if os.path.lexists(backup):
        fail("test directory race backup already exists")
    os.rename(path, backup)
    try:
        os.symlink(replacement, path)
    except Exception:
        os.rename(backup, path)
        raise
    return backup

def open_directory(path):
    directory = path
    if not directory.startswith("/") or os.path.normpath(directory) != directory:
        fail("directory is not canonical")
    backup = maybe_test_interpose_directory(directory)
    fd = None
    try:
        fd = os.open("/", os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        for component in (part for part in directory.split("/") if part):
            next_fd = os.open(component, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        bind_directory(fd)
        return fd
    except Exception:
        if fd is not None:
            os.close(fd)
        raise
    finally:
        if backup is not None:
            try:
                os.unlink(directory)
                os.rename(backup, directory)
            except Exception:
                fail("test directory race path could not be restored")

def lock_directory(directory_fd):
    assert_directory(directory_fd)
    try:
        fcntl.flock(directory_fd, fcntl.LOCK_EX)
    except OSError as error:
        raise OSError(error.errno, "could not lock private directory")
    assert_directory(directory_fd)

def lock_file(file_fd):
    try:
        fcntl.flock(file_fd, fcntl.LOCK_EX)
    except OSError as error:
        raise OSError(error.errno, "could not lock private file")

def make_temp(directory_fd, prefix):
    for _ in range(128):
        name = ".%s.%s.%s" % (prefix, os.getpid(), secrets.token_hex(8))
        try:
            fd = os.open(name, os.O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600, dir_fd=directory_fd)
        except FileExistsError:
            continue
        value = os.fstat(fd)
        if not private_regular(value):
            os.close(fd)
            os.unlink(name, dir_fd=directory_fd)
            fail("temporary file identity or mode is invalid")
        return name, fd, value
    fail("could not create an exclusive temporary")

def make_private_directory(directory_fd, prefix):
    for _ in range(128):
        name = ".%s.%s.%s" % (prefix, os.getpid(), secrets.token_hex(8))
        try:
            os.mkdir(name, 0o700, dir_fd=directory_fd)
        except FileExistsError:
            continue
        directory = None
        try:
            directory = os.open(name, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, dir_fd=directory_fd)
            value = os.fstat(directory)
            if not private_directory(value):
                fail("private directory identity or mode is invalid")
        finally:
            if directory is not None:
                os.close(directory)
        return name
    fail("could not create an unpredictable private directory")

def rename_atomic(source_fd, source_name, destination_fd, destination_name, flags):
    if renameatx_np is None:
        fail("atomic no-replace rename is unavailable")
    assert_directory(source_fd)
    assert_directory(destination_fd)
    result = renameatx_np(source_fd, source_name.encode(), destination_fd, destination_name.encode(), flags | RENAME_NOFOLLOW_ANY)
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))

def verify_published(directory_fd, name, expected):
    assert_directory(directory_fd)
    fd = os.open(name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC, dir_fd=directory_fd)
    try:
        value = os.fstat(fd)
        path_value = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if not private_regular(value) or identity(value) != expected or identity(path_value) != expected:
            fail("published file identity or mode changed")
    finally:
        os.close(fd)

def verify_source_binding(directory_fd, name, source_file, expected):
    assert_directory(directory_fd)
    source_value = os.fstat(source_file)
    path_value = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if not private_regular(source_value) or identity(source_value) != expected or not private_regular(path_value) or identity(path_value) != expected:
        fail("source pathname identity changed")

def read_all(file_fd):
    chunks = []
    while True:
        chunk = os.read(file_fd, 1024 * 1024)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)

def maybe_test_interpose_source(directory_fd, name):
    if os.environ.get("HOSTWRIGHT_PHASE09_HARNESS_TESTING") != "1":
        return
    if os.environ.get("HOSTWRIGHT_PHASE09_HARNESS_TEST_SOURCE_RACE") != "1":
        return
    target = os.environ.get("HOSTWRIGHT_PHASE09_HARNESS_TEST_SOURCE_RACE_TARGET", "")
    if not target.startswith("/"):
        fail("test source race target is not absolute")
    os.unlink(name, dir_fd=directory_fd)
    mode = os.environ.get("HOSTWRIGHT_PHASE09_HARNESS_TEST_SOURCE_RACE_MODE", "symlink")
    if mode == "symlink":
        os.symlink(target, name, dir_fd=directory_fd)
    elif mode == "regular":
        with open(target, "rb") as replacement:
            replacement_data = replacement.read()
        replacement_fd = os.open(name, os.O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600, dir_fd=directory_fd)
        try:
            write_all(replacement_fd, replacement_data)
            os.fsync(replacement_fd)
        finally:
            os.close(replacement_fd)
    elif mode == "hardlink":
        os.link(target, name, dst_dir_fd=directory_fd, follow_symlinks=False)
    else:
        fail("test source race mode is invalid")

def write_all(fd, data):
    offset = 0
    while offset < len(data):
        offset += os.write(fd, data[offset:])

def write_new(destination, data):
    directory, name = split_path(destination)
    directory_fd = open_directory(directory)
    lock_directory(directory_fd)
    temporary_name = None
    try:
        temporary_name, temporary_fd, temporary_value = make_temp(directory_fd, "write")
        try:
            write_all(temporary_fd, data)
            os.fsync(temporary_fd)
            value = os.fstat(temporary_fd)
            if not private_regular(value) or identity(value) != identity(temporary_value):
                fail("temporary file identity changed")
        finally:
            os.close(temporary_fd)
        rename_atomic(directory_fd, temporary_name, directory_fd, name, RENAME_EXCL)
        temporary_name = None
        verify_published(directory_fd, name, identity(temporary_value))
        os.fsync(directory_fd)
    finally:
        if temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
        os.close(directory_fd)

def replace_existing(destination, data):
    directory, name = split_path(destination)
    directory_fd = open_directory(directory)
    lock_directory(directory_fd)
    temporary_name = None
    swapped = False
    old_fd = os.open(name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC, dir_fd=directory_fd)
    try:
        lock_file(old_fd)
        old_value = os.fstat(old_fd)
        path_value = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if not private_regular(old_value) or identity(old_value) != identity(path_value):
            fail("replacement destination is not a stable private regular file")
        temporary_name, temporary_fd, temporary_value = make_temp(directory_fd, "replace")
        try:
            write_all(temporary_fd, data)
            os.fsync(temporary_fd)
            value = os.fstat(temporary_fd)
            if not private_regular(value) or identity(value) != identity(temporary_value):
                fail("replacement temporary identity changed")
        finally:
            os.close(temporary_fd)
        path_value = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if identity(path_value) != identity(old_value):
            fail("replacement destination changed before publication")
        rename_atomic(directory_fd, temporary_name, directory_fd, name, RENAME_SWAP)
        swapped = True
        old_path_value = os.stat(temporary_name, dir_fd=directory_fd, follow_symlinks=False)
        if not private_regular(old_path_value) or identity(old_path_value) != identity(old_value):
            fail("replacement destination was replaced during publication")
        os.unlink(temporary_name, dir_fd=directory_fd)
        temporary_name = None
        swapped = False
        verify_published(directory_fd, name, identity(temporary_value))
        os.fsync(directory_fd)
    finally:
        os.close(old_fd)
        if temporary_name is not None and not swapped:
            try:
                os.unlink(temporary_name, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
        os.close(directory_fd)

def copy_new(source, destination):
    source_directory, source_name = split_path(source)
    destination_directory, destination_name = split_path(destination)
    source_fd = open_directory(source_directory)
    destination_fd = open_directory(destination_directory)
    source_directory_value = os.fstat(source_fd)
    destination_directory_value = os.fstat(destination_fd)
    lock_directory(source_fd)
    if identity(source_directory_value) != identity(destination_directory_value):
        lock_directory(destination_fd)
    source_file = None
    temporary_name = None
    try:
        source_file = os.open(source_name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC, dir_fd=source_fd)
        source_value = os.fstat(source_file)
        source_path_value = os.stat(source_name, dir_fd=source_fd, follow_symlinks=False)
        if not private_regular(source_value) or identity(source_value) != identity(source_path_value):
            fail("copy source is not a stable private regular file")
        temporary_name, temporary_fd, temporary_value = make_temp(destination_fd, "copy")
        try:
            while True:
                chunk = os.read(source_file, 1024 * 1024)
                if not chunk:
                    break
                write_all(temporary_fd, chunk)
            os.fsync(temporary_fd)
            value = os.fstat(temporary_fd)
            if not private_regular(value) or identity(value) != identity(temporary_value):
                fail("copy temporary identity changed")
        finally:
            os.close(temporary_fd)
        source_path_value = os.stat(source_name, dir_fd=source_fd, follow_symlinks=False)
        if identity(source_path_value) != identity(source_value):
            fail("copy source changed during copy")
        maybe_test_interpose_source(source_fd, source_name)
        verify_source_binding(source_fd, source_name, source_file, identity(source_value))
        rename_atomic(destination_fd, temporary_name, destination_fd, destination_name, RENAME_EXCL)
        temporary_name = None
        verify_published(destination_fd, destination_name, identity(temporary_value))
        os.fsync(destination_fd)
    finally:
        if source_file is not None:
            os.close(source_file)
        if temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=destination_fd)
            except FileNotFoundError:
                pass
        os.close(source_fd)
        os.close(destination_fd)

def publish_existing(source, destination):
    source_directory, source_name = split_path(source)
    destination_directory, destination_name = split_path(destination)
    source_fd = open_directory(source_directory)
    destination_fd = open_directory(destination_directory)
    source_directory_value = os.fstat(source_fd)
    destination_directory_value = os.fstat(destination_fd)
    lock_directory(source_fd)
    if identity(source_directory_value) != identity(destination_directory_value):
        lock_directory(destination_fd)
    source_file = None
    try:
        source_file = os.open(source_name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC, dir_fd=source_fd)
        source_value = os.fstat(source_file)
        source_path_value = os.stat(source_name, dir_fd=source_fd, follow_symlinks=False)
        if not private_regular(source_value) or identity(source_value) != identity(source_path_value):
            fail("publication source is not a stable private regular file")
        maybe_test_interpose_source(source_fd, source_name)
        verify_source_binding(source_fd, source_name, source_file, identity(source_value))
        rename_atomic(source_fd, source_name, destination_fd, destination_name, RENAME_EXCL)
        verify_published(destination_fd, destination_name, identity(source_value))
        source_after = os.fstat(source_file)
        if not private_regular(source_after) or identity(source_after) != identity(source_value):
            fail("publication source identity changed after rename")
        os.fsync(destination_fd)
    finally:
        if source_file is not None:
            os.close(source_file)
        os.close(source_fd)
        os.close(destination_fd)

def replace_log(destination, data):
    directory, name = split_path(destination)
    directory_fd = open_directory(directory)
    lock_directory(directory_fd)
    old_fd = os.open(name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC, dir_fd=directory_fd)
    temporary_name = None
    swapped = False
    try:
        lock_file(old_fd)
        value = os.fstat(old_fd)
        path_value = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if not private_regular(value) or identity(value) != identity(path_value):
            fail("log destination is not a stable private regular file")
        old_data = read_all(old_fd)
        temporary_name, temporary_fd, temporary_value = make_temp(directory_fd, "log")
        try:
            write_all(temporary_fd, old_data + data)
            os.fsync(temporary_fd)
            final_value = os.fstat(temporary_fd)
            if not private_regular(final_value) or identity(final_value) != identity(temporary_value):
                fail("log temporary identity changed")
        finally:
            os.close(temporary_fd)
        path_value = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if identity(path_value) != identity(value):
            fail("log destination changed before publication")
        rename_atomic(directory_fd, temporary_name, directory_fd, name, RENAME_SWAP)
        swapped = True
        old_path_value = os.stat(temporary_name, dir_fd=directory_fd, follow_symlinks=False)
        if not private_regular(old_path_value) or identity(old_path_value) != identity(value):
            fail("log destination was replaced during publication")
        verify_published(directory_fd, name, identity(temporary_value))
        os.unlink(temporary_name, dir_fd=directory_fd)
        temporary_name = None
        swapped = False
        os.fsync(directory_fd)
    finally:
        os.close(old_fd)
        if temporary_name is not None and not swapped:
            try:
                os.unlink(temporary_name, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
        os.close(directory_fd)

def harden(path):
    directory, name = split_path(path)
    directory_fd = open_directory(directory)
    fd = os.open(name, os.O_RDWR | O_NOFOLLOW | O_CLOEXEC, dir_fd=directory_fd)
    try:
        value = os.fstat(fd)
        path_value = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or identity(value) != identity(path_value) or value.st_uid != os.getuid():
            fail("file to harden is not a stable regular file")
        expected = identity(value)
        os.fchmod(fd, 0o600)
        value = os.fstat(fd)
        path_value = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if not private_regular(value) or identity(value) != expected or identity(path_value) != expected:
            fail("hardened file identity or mode is invalid")
    finally:
        os.close(fd)
        os.close(directory_fd)

def create_temp(root, prefix):
    directory_fd = open_directory(root)
    try:
        name, fd, value = make_temp(directory_fd, prefix)
        os.close(fd)
        print(root.rstrip("/") + "/" + name)
    finally:
        os.close(directory_fd)

def create_directory(root, prefix):
    directory_fd = open_directory(root)
    try:
        name = make_private_directory(directory_fd, prefix)
        print(root.rstrip("/") + "/" + name)
    finally:
        os.close(directory_fd)

def run_with_outputs(stdout_path, stderr_path, command):
    stdout_directory, stdout_name = split_path(stdout_path)
    stderr_directory, stderr_name = split_path(stderr_path)
    stdout_fd = open_directory(stdout_directory)
    stderr_fd = open_directory(stderr_directory)
    stdout_name_temp = stderr_name_temp = None
    process = None
    try:
        stdout_name_temp, stdout_file, stdout_value = make_temp(stdout_fd, "stdout")
        stderr_name_temp, stderr_file, stderr_value = make_temp(stderr_fd, "stderr")
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stdout_file, stderr=stderr_file, close_fds=True, env=os.environ.copy())
        os.close(stdout_file); stdout_file = None
        os.close(stderr_file); stderr_file = None
        status = process.wait()
        stdout_check = os.open(stdout_name_temp, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC, dir_fd=stdout_fd)
        stderr_check = os.open(stderr_name_temp, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC, dir_fd=stderr_fd)
        try:
            if not private_regular(os.fstat(stdout_check)) or not private_regular(os.fstat(stderr_check)):
                fail("captured output identity or mode is invalid")
        finally:
            os.close(stdout_check); os.close(stderr_check)
        rename_atomic(stdout_fd, stdout_name_temp, stdout_fd, stdout_name, RENAME_EXCL)
        stdout_name_temp = None
        verify_published(stdout_fd, stdout_name, identity(stdout_value))
        rename_atomic(stderr_fd, stderr_name_temp, stderr_fd, stderr_name, RENAME_EXCL)
        stderr_name_temp = None
        verify_published(stderr_fd, stderr_name, identity(stderr_value))
        os.fsync(stdout_fd); os.fsync(stderr_fd)
        if status < 0:
            return 128 - status
        return status
    finally:
        if process is not None and process.poll() is None:
            process.kill(); process.wait()
        for directory_fd, name in ((stdout_fd, stdout_name_temp), (stderr_fd, stderr_name_temp)):
            if name is not None:
                try:
                    os.unlink(name, dir_fd=directory_fd)
                except FileNotFoundError:
                    pass
        os.close(stdout_fd); os.close(stderr_fd)

operation = sys.argv[1]
try:
    if operation == "create":
        create_temp(sys.argv[2], sys.argv[3])
    elif operation == "create-dir":
        create_directory(sys.argv[2], sys.argv[3])
    elif operation == "write-new":
        write_new(sys.argv[2], os.fdopen(3, "rb").read())
    elif operation == "write-replace":
        replace_existing(sys.argv[2], os.fdopen(3, "rb").read())
    elif operation == "copy-new":
        copy_new(sys.argv[2], sys.argv[3])
    elif operation == "publish-new":
        publish_existing(sys.argv[2], sys.argv[3])
    elif operation == "replace-log":
        replace_log(sys.argv[2], os.fdopen(3, "rb").read())
    elif operation == "harden":
        harden(sys.argv[2])
    elif operation == "run":
        sys.exit(run_with_outputs(sys.argv[2], sys.argv[3], sys.argv[4:]))
    else:
        fail("unknown secure filesystem operation")
except Exception as error:
    print("secure filesystem helper refused operation: %s" % error, file=sys.stderr)
    sys.exit(74)
PY
}

atomic_write_from_stdin() { secure_fs write-new "$1"; }
atomic_replace_from_stdin() { secure_fs write-replace "$1"; }
atomic_copy() { secure_fs copy-new "$1" "$2"; }
atomic_publish() { secure_fs publish-new "$1" "$2"; }
atomic_log_replace_from_stdin() { secure_fs replace-log "$1"; }
atomic_harden() { secure_fs harden "$1"; }
atomic_run_outputs() { secure_fs run "$1" "$2" "${@:3}"; }

test_parent_path() {
  local candidate="${HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT:-}"
  [[ -n "$candidate" && -d "$candidate" && ! -L "$candidate" ]] || die 'test wrapper parent is unavailable.' 69
  candidate="$(/bin/realpath "$candidate")"
  printf '%s\n' "$candidate"
}

test_wrapper_path() {
  local path="$1" label="$2" wrapper_parent
  wrapper_parent="$(test_parent_path)"
  [[ "$path" == /* && -x "$path" && ! -L "$path" && "$(/bin/realpath "$path")" == "$path" && "$(/bin/realpath "$(path_parent "$path")")" == "$wrapper_parent" ]] || die "test $label wrapper is not a private canonical executable." 69
  printf '%s\n' "$path"
}

swift_exec() {
  if testing; then
    local wrapper
    wrapper="$(test_wrapper_path "${HOSTWRIGHT_PHASE09_HARNESS_TEST_SWIFT:-}" swift)"
    "$wrapper" "$@"
  else
    "$swift_path" "$@"
  fi
}

swift_command_path() {
  if testing; then
    test_wrapper_path "${HOSTWRIGHT_PHASE09_HARNESS_TEST_SWIFT:-}" swift
  else
    printf '%s\n' "$swift_path"
  fi
}

security_exec() {
  if testing; then
    local wrapper
    wrapper="$(test_wrapper_path "${HOSTWRIGHT_PHASE09_HARNESS_TEST_SECURITY:-}" security)"
    "$wrapper" "$@"
  else
    "$security_path" "$@"
  fi
}

contract() {
  /bin/cat <<'EOF'
Phase 09 Gate 13 qualification harness contract v1
Gate 13 — 81.25% — ancestry, sync, and aggregate compatibility.
diagnose is non-qualifying and emits canonical JSON with claim:"none"; it never creates or reuses an evidence root.
Formal prepare/run require one exact maintainer-supplied Phase 08 completion commit, an immutable completion receipt,
and current CMS-verified passed evidence for Gates 8, 9, 10, 11, and 12. The only Phase 08 ancestry operation is
git merge-base --is-ancestor <exact-phase08-commit> HEAD. No Phase 08 checkout, mutable ref, process, runtime, or state is inspected.
The six U/I/L/M/S/R cells execute serially. Every cell is bound to the committed source, configuration, toolchain,
matrix, and prerequisite digests. A failed root and both locks are preserved; a partial root is never rerun or repaired.
Passed evidence is reused only after exact state, checksum-manifest, and CMS verification.
EOF
}

qualification_parent() {
  if testing; then
    : "${HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT:?test parent is required in harness test mode}"
    printf '%s\n' "$HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT"
  else
    local resolved_swift resolved_python
    printf '%s\n' "$live_parent"
  fi
}

dependency_parent() {
  if testing && [[ -n "${HOSTWRIGHT_PHASE09_EVIDENCE_PARENT:-}" ]]; then
    printf '%s\n' "$HOSTWRIGHT_PHASE09_EVIDENCE_PARENT"
  elif testing; then
    printf '%s\n' "$parent"
  else
    printf '%s\n' "$live_parent"
  fi
}

validate_worktree() {
  local top current_branch
  top="$(cd "$repository_root" && "$git_path" rev-parse --show-toplevel)"
  testing && return
  current_branch="$(cd "$repository_root" && "$git_path" branch --show-current)"
  [[ "$current_branch" == "$branch" ]] || die "Gate 13 requires branch $branch." 66
  [[ "$top" == '/Users/dev/Documents/hostwright-phase09' ]] || die 'Gate 13 requires the isolated Phase 09 worktree.' 66
}

validate_root() {
  : "${HOSTWRIGHT_PHASE09_GATE_ROOT:?HOSTWRIGHT_PHASE09_GATE_ROOT is required}"
  root="$HOSTWRIGHT_PHASE09_GATE_ROOT"
  parent="$(qualification_parent)"
  local canonical root_parent user_id
  [[ -d "$parent" && ! -L "$parent" ]] || die 'qualification parent must be an existing canonical directory.' 66
  canonical="$(/bin/realpath "$parent")"
  if testing; then
    [[ "$canonical" =~ ^/private/var/folders/.*/T/hostwright-phase09-gate13-harness-[a-f0-9-]+$ || "$canonical" =~ ^/var/folders/.*/T/hostwright-phase09-gate13-harness-[a-f0-9-]+$ ]] || die 'test parent must be an isolated Gate 13 harness directory.' 66
  else
    [[ "$canonical" == "$live_parent" ]] || die 'Gate 13 evidence must use the fixed qualification parent.' 66
  fi
  root_parent="$(/bin/realpath "$(path_parent "$root")")"
  [[ "$root" == /* && -d "$root" && ! -L "$root" && "$(/bin/realpath "$root")" == "$root" && "$root_parent" == "$canonical" ]] || die 'evidence root must be canonical and directly under its qualification parent.' 66
  [[ "${root##*/}" =~ ^phase09-gate13-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || die 'Gate 13 evidence root has an invalid lowercase UUID name.' 66
  user_id="$(/usr/bin/id -u)"
  [[ "$(/usr/bin/stat -f '%u' "$root")" == "$user_id" && "$(/usr/bin/stat -f '%Lp' "$root")" == 700 ]] || die 'Gate 13 evidence root must be current-user-owned mode 0700.' 66
}

empty_root() {
  [[ -z "$(/usr/bin/find "$root" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die 'Gate 13 evidence root must be empty.' 73
}

clean_source() {
  "$git_path" diff --quiet || die 'Gate 13 source must be clean and committed.' 73
  "$git_path" diff --cached --quiet || die 'Gate 13 source must be clean and committed.' 73
  local dirty
  dirty="$("$git_path" status --porcelain=v1 --untracked-files=all | "$awk_path" '$2 !~ /^tmp(\/|$)/ { print }')"
  [[ -z "$dirty" ]] || die 'Gate 13 source must be clean and committed.' 73
}

source_digest() {
  {
    "$git_path" rev-parse HEAD
    local path
    while IFS= read -r -d '' path; do
      case "$path" in
        tmp|tmp/*|.codex|.codex/*|.claude|.claude/*) continue ;;
      esac
      printf '%s\0' "$path"
      if [[ -f "$path" && ! -L "$path" ]]; then sha "$path"; else printf '%s\n' missing; fi
    done < <({
      "$git_path" ls-files --cached -z -- . ':(exclude)tmp' ':(exclude).codex' ':(exclude).claude'
      printf '%s\0' scripts/phase09-gate13-qualification.sh scripts/phase09-gate14-qualification.sh Tools/Phase09XCTestObserver.m Tests/HostwrightStateTests/Phase09Gate13QualificationHarnessTests.swift Tests/HostwrightStateTests/Phase09Gate14QualificationHarnessTests.swift
    } | LC_ALL=C /usr/bin/sort -z -u)
    "$git_path" submodule status --recursive 2>/dev/null || true
  } | stream_sha
}

config_digest() {
  local file
  {
    for file in "$matrix_path" "scripts/phase09-gate13-qualification.sh" "$xctest_observer_source" "Tests/HostwrightStateTests/Phase09Gate13QualificationHarnessTests.swift"; do
      [[ -f "$file" && ! -L "$file" ]] || die "Gate 13 configuration input is unavailable: $file" 69
      printf '%s  %s\n' "$(sha "$file")" "$file"
    done
    formal_toolchain_config
  } | stream_sha
}

formal_toolchain_config() {
  local path resolved_clang resolved_xctest
  for path in "$git_path" "$awk_path" "$python_path" "$security_path" "$openssl_path" "$shasum_path" "$jq_path" "$swift_path" "$xcodebuild_path" "$xcrun_path" "$bash_path" /bin/realpath; do
    validate_formal_tool "$path"
    printf 'formal-tool=%s\tsha256=%s\n' "$path" "$(sha "$path")"
  done
  if ! testing; then
    resolved_clang="$("$xcrun_path" --find clang)"
    resolved_xctest="$(/bin/realpath "$("$xcrun_path" --find xctest)")"
    validate_formal_tool "$resolved_clang"
    validate_formal_tool "$resolved_xctest"
    printf 'formal-tool=%s\tsha256=%s\n' "$resolved_clang" "$(sha "$resolved_clang")"
    printf 'formal-tool=%s\tsha256=%s\n' "$resolved_xctest" "$(sha "$resolved_xctest")"
  fi
}

validate_formal_tool() {
  local path="$1"
  [[ "$path" == /* && -x "$path" && ! -L "$path" && "$(/bin/realpath "$path")" == "$path" ]] || die "Gate 13 formal tool is not an exact canonical executable: $path" 69
}

toolchain_snapshot() {
  if testing; then
    printf '%s\n' 'qualification-toolchain=test-mode'
    printf 'test-swift=%s\ttest-swift-sha256=%s\n' "$(test_wrapper_path "${HOSTWRIGHT_PHASE09_HARNESS_TEST_SWIFT:-}" swift)" "$(sha "$(test_wrapper_path "${HOSTWRIGHT_PHASE09_HARNESS_TEST_SWIFT:-}" swift)")"
    printf 'test-security=%s\ttest-security-sha256=%s\n' "$(test_wrapper_path "${HOSTWRIGHT_PHASE09_HARNESS_TEST_SECURITY:-}" security)" "$(sha "$(test_wrapper_path "${HOSTWRIGHT_PHASE09_HARNESS_TEST_SECURITY:-}" security)")"
    "$bash_path" --version | /usr/bin/head -n 1
    swift_exec --version
    "$jq_path" --version
  else
    local resolved_swift resolved_python
    /usr/bin/sw_vers
    "$xcodebuild_path" -version
    swift_exec --version
    "$bash_path" --version | /usr/bin/head -n 1
    "$jq_path" --version
    resolved_swift="$("$xcrun_path" --find swift)"
    resolved_python="$("$xcrun_path" --find python3)"
    [[ -x "$resolved_swift" && -x "$resolved_python" && "$resolved_swift" != "$swift_path" && "$resolved_python" != "$python_path" ]] || return 0
    [[ "$("$swift_path" --version 2>&1)" == "$("$resolved_swift" --version 2>&1)" && "$("$python_path" --version 2>&1)" == "$("$resolved_python" --version 2>&1)" ]] || die 'Gate 13 xcrun-resolved formal tools do not match the pinned system toolchain identity.' 69
    printf 'xcrun-swift=%s\nxcrun-python3=%s\n' "$resolved_swift" "$resolved_python"
    "$security_path" cms -h 0 2>&1 | /usr/bin/head -n 1 || true
  fi
  formal_toolchain_config
}

toolchain_digest() { toolchain_snapshot | stream_sha; }

matrix_validate() {
  [[ -f "$matrix_path" && ! -L "$matrix_path" ]] || die 'Gate 13 compatibility matrix is unavailable or symlinked.' 69
  [[ "$(/usr/bin/jq -r '.schema' "$matrix_path")" == 'hostwright.phase09.gate13.compatibility-matrix.v1' ]] || die 'Gate 13 matrix schema mismatch.' 69
  [[ "$(/usr/bin/jq -r '.gate' "$matrix_path")" == '13' ]] || die 'Gate 13 matrix gate mismatch.' 69
  [[ "$(/usr/bin/jq -r '.version' "$matrix_path")" == 'v1' ]] || die 'Gate 13 matrix version mismatch.' 69
  [[ "$(sha "$matrix_path")" == "$frozen_matrix_digest" ]] || die 'Gate 13 compatibility matrix is not the frozen v1 contract.' 69
  [[ "$(/usr/bin/jq -r '.testCount' "$matrix_path")" == "$test_count" ]] || die 'Gate 13 compatibility test count drifted.' 69
  [[ "$(/usr/bin/jq -r '.tests | length' "$matrix_path")" == "$test_count" ]] || die 'Gate 13 compatibility matrix must contain exactly 20 tests.' 69
  /usr/bin/jq -e '.cellOrder == [1,2,3,4,5,6] and .structuredResult.format == "xunit-v1" and .structuredResult.exactSelectorBinding == true and .structuredResult.consoleTextIsNonEvidence == true and .compatibilitySurface.schemaMigrations == [17,18,19,20,21] and
    .compatibilitySurface.verifiedBackupAndRollbackRefusal == true and
    .compatibilitySurface.checksumAndFutureSchemaRejection == true and
    .compatibilitySurface.envelopeRevisions == ["2.0","2.1"] and
    .compatibilitySurface.replayAndIdempotencyConflicts == true and
    .compatibilitySurface.cliTransportParity == true and
    .compatibilitySurface.aggregateContractAndVersionDecode == true' "$matrix_path" >/dev/null || die 'Gate 13 compatibility surface drifted.' 69
  [[ "$(/usr/bin/jq -r '[.tests[].id] | unique | length' "$matrix_path")" == "$test_count" ]] || die 'Gate 13 matrix test identifiers must be unique.' 69
  [[ "$(/usr/bin/jq -r '[.tests[] | select(.cell >= 1 and .cell <= 6)] | length' "$matrix_path")" == "$test_count" ]] || die 'Gate 13 matrix cell assignment is invalid.' 69
  /usr/bin/jq -e 'all(.tests[]; (.id | test("^g13-[0-9]{2}$")) and (.selector | test("^[A-Za-z0-9_./]+$")) and (.category | test("^[a-z0-9-]+$")))' "$matrix_path" >/dev/null || die 'Gate 13 matrix contains an invalid selector or identifier.' 69
  local cell count
  for cell in 1 2 3 4 5 6; do
    count="$(/usr/bin/jq -r --argjson cell "$cell" '[.tests[] | select(.cell == $cell)] | length' "$matrix_path")"
    [[ "$count" =~ ^[1-9][0-9]*$ ]] || die "Gate 13 cell $cell has no frozen selectors." 69
  done
}

matrix_digest() { sha "$matrix_path"; }

load_signer_pins() {
  if testing; then
    signing_identity="${HOSTWRIGHT_PHASE09_HARNESS_TEST_CMS_SIGNING_IDENTITY:-$test_signing_identity}"
    signing_fingerprint="${HOSTWRIGHT_PHASE09_HARNESS_TEST_CMS_SIGNING_FINGERPRINT:-$test_signing_fingerprint}"
    signing_team_id="${HOSTWRIGHT_PHASE09_HARNESS_TEST_CMS_TEAM_ID:-$test_signing_team_id}"
    signing_certificate_sha256="${HOSTWRIGHT_PHASE09_HARNESS_TEST_CMS_CERTIFICATE_SHA256:-$test_signing_certificate_sha256}"
    [[ "$signing_identity" == "$test_signing_identity" && "$signing_fingerprint" == "$test_signing_fingerprint" && "$signing_team_id" == "$test_signing_team_id" && "$signing_certificate_sha256" == "$test_signing_certificate_sha256" ]] || die 'test CMS signer is not the isolated pinned fixture.' 69
    return 0
  fi
  signing_identity="${HOSTWRIGHT_PHASE09_CMS_SIGNING_IDENTITY:-}"
  signing_fingerprint="${HOSTWRIGHT_PHASE09_CMS_SIGNING_FINGERPRINT:-}"
  signing_team_id="${HOSTWRIGHT_PHASE09_CMS_SIGNING_TEAM_ID:-}"
  signing_certificate_sha256="${HOSTWRIGHT_PHASE09_CMS_CERTIFICATE_SHA256:-}"
  [[ "$signing_identity" == "$approved_signing_identity" ]] || die 'formal CMS identity is not the approved Gate 11/12 identity.' 69
  [[ "$signing_fingerprint" == "$approved_signing_fingerprint" ]] || die 'formal CMS fingerprint is not the approved Gate 11/12 fingerprint.' 69
  [[ "$signing_team_id" == "$approved_signing_team_id" ]] || die 'formal CMS Team ID is not the approved Gate 11/12 Team ID.' 69
  [[ "$signing_certificate_sha256" =~ ^[a-fA-F0-9]{64}$ ]] || die 'formal CMS certificate SHA-256 pin is required.' 69
  signing_certificate_sha256="$(lowercase "$signing_certificate_sha256")"
  signing_fingerprint="$(uppercase "$signing_fingerprint")"
  [[ "$signing_identity" == *"(${signing_team_id})" ]] || die 'formal CMS identity is not bound to the approved Team ID.' 69
  "$security_path" find-identity -v -p codesigning | /usr/bin/grep -F "$signing_fingerprint" | /usr/bin/grep -F "$signing_identity" >/dev/null || die 'the approved CMS signing identity is unavailable.' 69
}

collect() {
  local dependency_file
  matrix_validate
  testing || clean_source
  load_signer_pins
  source_commit="$("$git_path" rev-parse HEAD)"
  source_digest_value="$(source_digest)"
  config_digest_value="$(config_digest)"
  toolchain_digest_value="$(toolchain_digest)"
  dependency_file="${HOSTWRIGHT_PHASE09_GATE13_DEPENDENCY_EVIDENCE:-}"
  if [[ -n "$dependency_file" && -f "$dependency_file" && ! -L "$dependency_file" ]]; then
    dependency_digest_value="$(sha "$dependency_file")"
    dependency_canonical_digest_value="$(canonical_json_digest "$dependency_file")"
  fi
}

regular_canonical() {
  [[ -f "$1" && ! -L "$1" && "$(/bin/realpath "$1")" == "$1" ]]
}

private_file_0600() {
  regular_canonical "$1" && [[ "$(/usr/bin/stat -f '%u' "$1")" == "$(/usr/bin/id -u)" && "$(/usr/bin/stat -f '%Lp' "$1")" == 600 && "$(/usr/bin/stat -f '%l' "$1")" == 1 ]]
}

file_identity() {
  /usr/bin/stat -f '%d:%i:%u:%Lp' "$1"
}

assert_absent() { [[ ! -e "$1" && ! -L "$1" ]]; }

make_private_temp() {
  local path
  path="$(secure_fs create "$root" ".gate13-${1}")" || die 'Gate 13 could not create an exclusive root-local temporary.' 73
  private_file_0600 "$path" || die 'Gate 13 temporary failed private identity validation.' 73
  printf '%s\n' "$path"
}

make_private_directory() {
  local path
  path="$(secure_fs create-dir "$root" ".gate-external-$gate-$1")" || die 'Gate 13 could not create an unpredictable private external-output directory.' 73
  [[ -d "$path" && ! -L "$path" && "$(/bin/realpath "$path")" == "$path" && "$(/usr/bin/stat -f '%u' "$path")" == "$(/usr/bin/id -u)" && "$(/usr/bin/stat -f '%Lp' "$path")" == 700 ]] || die 'Gate 13 external-output directory failed private identity validation.' 73
  printf '%s\n' "$path"
}

dispose_private_artifact() {
  local artifact="$1" directory="$2"
  if [[ -e "$artifact" || -L "$artifact" ]]; then
    /bin/unlink "$artifact" || return 1
  fi
  /bin/rmdir "$directory"
}

validate_checksum_manifest() {
  local checksum="$1" directory="$2" expected name rest count=0 names='' expected_names expected_count
  private_file_0600 "$checksum" || return 1
  while IFS=$' \t' read -r expected name rest; do
    case "$name" in
      ..|*..*|/*|.*) return 1 ;;
    esac
    [[ "$expected" =~ ^[a-f0-9]{64}$ && -n "$name" && -z "${rest:-}" ]] || return 1
    private_file_0600 "$directory/$name" || return 1
    [[ "$(sha "$directory/$name")" == "$expected" ]] || return 1
    names="$names""$name"'\n'
    count=$((count + 1))
  done < "$checksum"
  if (( $# >= 3 )) && [[ "$3" == exact ]]; then
    expected_names="$(checksum_manifest_inventory)"
    expected_count="$(checksum_manifest_inventory | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    [[ "$count" == "$expected_count" && "$(printf '%b' "$names")" == "$expected_names" ]]
    return
  fi
  [[ "$count" -gt 0 && "$("$awk_path" '{print $2}' "$checksum" | /usr/bin/sort | /usr/bin/uniq -d | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 0 ]]
}

cms_signer_metadata() {
  local cms="$1" label="$2" metadata metadata_dir certificate certificate_dir subject actual_certificate_sha256 actual_fingerprint actual_team_id actual_common_name actual_identity
  if testing; then
    metadata_dir="$(make_private_directory "cms-metadata-$label")"
    metadata="$metadata_dir/output"
    if ! security_exec cms -M -i "$cms" -o "$metadata" >/dev/null 2>&1; then
      dispose_private_artifact "$metadata" "$metadata_dir" || true
      return 1
    fi
    atomic_harden "$metadata" >/dev/null 2>&1 || { dispose_private_artifact "$metadata" "$metadata_dir" || true; return 1; }
    actual_certificate_sha256="$("$awk_path" -F= '$1=="certificate-sha256"{print tolower($2); exit}' "$metadata")"
    actual_fingerprint="$("$awk_path" -F= '$1=="fingerprint"{print toupper($2); exit}' "$metadata")"
    actual_team_id="$("$awk_path" -F= '$1=="team-id"{print $2; exit}' "$metadata")"
    actual_identity="$("$awk_path" -F= '$1=="identity"{print substr($0, index($0, "=")+1); exit}' "$metadata")"
    dispose_private_artifact "$metadata" "$metadata_dir" || return 1
  else
    certificate_dir="$(make_private_directory "cms-certificate-$label")"
    certificate="$certificate_dir/output"
    if ! "$openssl_path" cms -verify -inform DER -binary -in "$cms" -noverify -signer "$certificate" -out /dev/null >/dev/null 2>&1; then
      dispose_private_artifact "$certificate" "$certificate_dir" || true
      return 1
    fi
    atomic_harden "$certificate" >/dev/null 2>&1 || { dispose_private_artifact "$certificate" "$certificate_dir" || true; return 1; }
    actual_certificate_sha256="$("$openssl_path" x509 -in "$certificate" -outform DER | "$shasum_path" -a 256 | "$awk_path" '{print tolower($1)}')"
    actual_fingerprint="$("$openssl_path" x509 -in "$certificate" -fingerprint -sha1 -noout | "$awk_path" -F= '{print toupper($2)}' | /usr/bin/tr -d ':')"
    subject="$("$openssl_path" x509 -in "$certificate" -subject -nameopt RFC2253 -noout)"
    actual_team_id="$(printf '%s\n' "$subject" | "$awk_path" -F, '{for (i=1; i<=NF; i++) if ($i ~ /^OU=[A-Z0-9]+$/) {v=$i; sub(/^OU=/,"",v); if (length(v)==10) {print v; exit}}}')"
    actual_common_name="$(printf '%s\n' "$subject" | "$awk_path" -F, '{for (i=1; i<=NF; i++) if ($i ~ /^CN=/) {v=$i; sub(/^CN=/,"",v); print v; exit}}')"
    if [[ "$actual_common_name" == *"($actual_team_id)" ]]; then
      actual_identity="$actual_common_name"
    else
      actual_identity="${actual_common_name} (${actual_team_id})"
    fi
    dispose_private_artifact "$certificate" "$certificate_dir" || return 1
  fi
  [[ "$actual_certificate_sha256" =~ ^[a-f0-9]{64}$ && "$actual_fingerprint" =~ ^[A-F0-9]{40}$ && "$actual_team_id" =~ ^[A-Z0-9]{10}$ && -n "$actual_identity" ]] || return 1
  [[ "$actual_certificate_sha256" == "$(lowercase "$signing_certificate_sha256")" && "$actual_fingerprint" == "$signing_fingerprint" && "$actual_team_id" == "$signing_team_id" && "$actual_identity" == "$signing_identity" ]]
}

verify_cms_payload() {
  local cms="$1" checksum="$2" label="$3" decoded decoded_dir
  private_file_0600 "$cms" && private_file_0600 "$checksum" || return 1
  decoded_dir="$(make_private_directory "cms-decoded-$label")"
  decoded="$decoded_dir/output"
  cms_signer_metadata "$cms" "$label" || { dispose_private_artifact "$decoded" "$decoded_dir" || true; return 1; }
  security_exec cms -D -u 9 -i "$cms" -o "$decoded" >/dev/null 2>&1 || { dispose_private_artifact "$decoded" "$decoded_dir" || true; return 1; }
  atomic_harden "$decoded" >/dev/null 2>&1 || { dispose_private_artifact "$decoded" "$decoded_dir" || true; return 1; }
  /usr/bin/cmp -s "$checksum" "$decoded" || { dispose_private_artifact "$decoded" "$decoded_dir" || true; return 1; }
  dispose_private_artifact "$decoded" "$decoded_dir"
}

validate_receipt_file() {
  local receipt="$1" checksum="$2" cms="$3" copied="${4:-false}" receipt_identity checksum_identity cms_identity
  if [[ "$copied" != true ]]; then
    case "$receipt" in */hostwright/*|/Volumes/T9/*) die 'Gate 13 refuses a mutable or live-runtime completion receipt.' 69 ;; esac
  fi
  [[ "${receipt##*/}" == phase08-completion-receipt-v1.json ]] || die 'Gate 13 completion receipt has the wrong canonical filename.' 69
  private_file_0600 "$receipt" && private_file_0600 "$checksum" && private_file_0600 "$cms" || die 'Gate 13 completion receipt artifacts must be private canonical files.' 69
  receipt_identity="$(file_identity "$receipt")"; checksum_identity="$(file_identity "$checksum")"; cms_identity="$(file_identity "$cms")"
  /usr/bin/jq -e --arg commit "${HOSTWRIGHT_PHASE09_PHASE08_COMPLETION_COMMIT:-}" --arg cert "$signing_certificate_sha256" --arg fingerprint "$signing_fingerprint" --arg team "$signing_team_id" --arg identity "$signing_identity" \
    'type=="object" and (keys|sort)==["cmsVerified","finalEvidenceCMSCertificateSHA256","finalEvidenceCMSDigest","finalEvidenceCMSFingerprint","finalEvidenceCMSIdentity","finalEvidenceCMSTeamID","finalEvidenceDigest","schema","sourceCommit","status"] and
     .schema=="hostwright.phase09.phase08-completion-receipt.v1" and .status=="passed" and .sourceCommit==$commit and
     (.sourceCommit|test("^[0-9a-f]{40}$")) and (.finalEvidenceDigest|test("^[a-f0-9]{64}$")) and (.finalEvidenceCMSDigest|test("^[a-f0-9]{64}$")) and
     .finalEvidenceCMSCertificateSHA256==($cert|ascii_downcase) and .finalEvidenceCMSFingerprint==$fingerprint and .finalEvidenceCMSTeamID==$team and .finalEvidenceCMSIdentity==$identity and .cmsVerified==true and
     (.finalEvidenceCMSCertificateSHA256|test("^[a-f0-9]{64}$"))' "$receipt" >/dev/null || die 'Gate 13 completion receipt schema, signer, or commit binding is invalid.' 69
  [[ "$(/usr/bin/wc -l < "$checksum" | /usr/bin/tr -d ' ')" == 1 && "$(/usr/bin/sed -n '1p' "$checksum")" == "$(sha "$receipt")  ${receipt##*/}" ]] || die 'Gate 13 completion receipt checksum manifest is invalid.' 69
  verify_cms_payload "$cms" "$checksum" receipt || die 'Gate 13 completion receipt CMS is not verified by the pinned signer.' 69
  private_file_0600 "$receipt" && private_file_0600 "$checksum" && private_file_0600 "$cms" || die 'Gate 13 completion receipt artifacts changed identity or mode.' 73
  [[ "$(file_identity "$receipt")" == "$receipt_identity" && "$(file_identity "$checksum")" == "$checksum_identity" && "$(file_identity "$cms")" == "$cms_identity" ]] || die 'Gate 13 completion receipt artifact identity changed.' 73
}

validate_receipt() {
  local receipt="${HOSTWRIGHT_PHASE09_PHASE08_COMPLETION_RECEIPT:-}" directory
  [[ -n "$receipt" ]] || die 'Gate 13 requires HOSTWRIGHT_PHASE09_PHASE08_COMPLETION_RECEIPT.' 69
  private_file_0600 "$receipt" || die 'Gate 13 completion receipt must be current-user-owned mode 0600.' 69
  directory="$(/bin/realpath "$(path_parent "$receipt")")"
  validate_receipt_file "$receipt" "$directory/phase08-completion-receipt-v1.sha256" "$directory/phase08-completion-receipt-v1.cms"
}

validate_dependency_record() {
  local record="$1" expected_gate="$2" root_basename record_source record_source_digest record_config_digest record_toolchain_digest manifest_digest checksum_digest cms_digest dep_root manifest_source_digest manifest_config_digest manifest_toolchain_digest
  "$jq_path" -e --argjson gate "$expected_gate" --arg source "$source_commit" --arg cert "$signing_certificate_sha256" --arg fingerprint "$signing_fingerprint" --arg team "$signing_team_id" --arg identity "$signing_identity" \
    'type=="object" and (keys|sort)==["checksumManifestDigest","cmsCertificateSHA256","cmsDigest","cmsFingerprint","cmsIdentity","cmsTeamID","configDigest","gate","manifestDigest","rootBasename","sourceCommit","sourceDigest","status","toolchainDigest"] and .gate==$gate and .status=="passed" and .sourceCommit==$source and (.rootBasename|test("^phase09-gate(08|09|10|11|12)-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$")) and (.sourceDigest|test("^[a-f0-9]{64}$")) and (.configDigest|test("^[a-f0-9]{64}$")) and (.toolchainDigest|test("^[a-f0-9]{64}$")) and (.manifestDigest|test("^[a-f0-9]{64}$")) and (.checksumManifestDigest|test("^[a-f0-9]{64}$")) and (.cmsDigest|test("^[a-f0-9]{64}$")) and .cmsCertificateSHA256==($cert|ascii_downcase) and .cmsFingerprint==$fingerprint and .cmsTeamID==$team and .cmsIdentity==$identity' <<<"$record" >/dev/null || die "Gate 13 dependency gate $expected_gate record or signer binding is invalid." 69
  root_basename="$(/usr/bin/jq -r '.rootBasename' <<<"$record")"
  [[ "$root_basename" =~ ^phase09-gate(08|09|10|11|12)-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || die 'Gate 13 dependency root basename is invalid.' 69
  [[ "$root_basename" == "$(printf 'phase09-gate%02d-' "$expected_gate")"* ]] || die "Gate 13 dependency gate $expected_gate root basename does not match its gate." 69
  [[ -z "$(/usr/bin/jq -r '(.path // .rootPath // empty)' <<<"$record")" ]] || die 'Gate 13 dependency records may not substitute a path for a bound root basename.' 69
  record_source="$(/usr/bin/jq -r '.sourceCommit' <<<"$record")"
  [[ "$record_source" == "$source_commit" && "$record_source" =~ ^[0-9a-f]{40}$ ]] || die "Gate 13 dependency gate $expected_gate is not bound to the current source commit." 69
  record_source_digest="$(/usr/bin/jq -r '.sourceDigest' <<<"$record")"
  record_config_digest="$(/usr/bin/jq -r '.configDigest' <<<"$record")"
  record_toolchain_digest="$(/usr/bin/jq -r '.toolchainDigest' <<<"$record")"
  [[ "$record_source_digest" =~ ^[a-f0-9]{64}$ && "$record_config_digest" =~ ^[a-f0-9]{64}$ && "$record_toolchain_digest" =~ ^[a-f0-9]{64}$ ]] || die "Gate 13 dependency gate $expected_gate has invalid source, config, or toolchain bindings." 69
  # Each producer gate records its own algorithm's source digest inside its
  # CMS-sealed manifest; cross-gate identity is the exact source commit
  # (validated above) plus internal manifest/record consistency (below),
  # because digest flavors differ between producer and aggregate harnesses.
  manifest_digest="$(/usr/bin/jq -r '.manifestDigest' <<<"$record")"
  checksum_digest="$(/usr/bin/jq -r '.checksumManifestDigest' <<<"$record")"
  cms_digest="$(/usr/bin/jq -r '.cmsDigest' <<<"$record")"
  [[ "$manifest_digest" =~ ^[a-f0-9]{64}$ && "$checksum_digest" =~ ^[a-f0-9]{64}$ && "$cms_digest" =~ ^[a-f0-9]{64}$ ]] || die "Gate 13 dependency gate $expected_gate has invalid evidence digests." 69
  dep_root="${evidence_parent}/${root_basename}"
  [[ -d "$dep_root" && ! -L "$dep_root" && "$(/bin/realpath "$dep_root")" == "$dep_root" && "$(/bin/realpath "$(path_parent "$dep_root")")" == "$evidence_parent" ]] || die "Gate 13 dependency gate $expected_gate root is not a direct canonical child of the evidence parent." 69
  [[ "$(/usr/bin/stat -f '%u' "$dep_root")" == "$(/usr/bin/id -u)" && "$(/usr/bin/stat -f '%Lp' "$dep_root")" == 700 ]] || die "Gate 13 dependency gate $expected_gate root ownership is invalid." 69
  private_file_0600 "$dep_root/manifest-v1.json" || die "Gate 13 dependency gate $expected_gate manifest is unsafe or not private." 69
  private_file_0600 "$dep_root/evidence-v1.sha256" || die "Gate 13 dependency gate $expected_gate checksum manifest is unsafe or not private." 69
  private_file_0600 "$dep_root/evidence-v1.cms" || die "Gate 13 dependency gate $expected_gate CMS is unsafe or not private." 69
  [[ "$(sha "$dep_root/manifest-v1.json")" == "$manifest_digest" && "$(sha "$dep_root/evidence-v1.sha256")" == "$checksum_digest" && "$(sha "$dep_root/evidence-v1.cms")" == "$cms_digest" ]] || die "Gate 13 dependency gate $expected_gate evidence digest changed." 69
  manifest_source_digest="$(/usr/bin/jq -r '.sourceDigest' "$dep_root/manifest-v1.json")"
  manifest_config_digest="$(/usr/bin/jq -r '.configDigest' "$dep_root/manifest-v1.json")"
  manifest_toolchain_digest="$(/usr/bin/jq -r '.toolchainDigest' "$dep_root/manifest-v1.json")"
  [[ "$(/usr/bin/jq -r '.gate' "$dep_root/manifest-v1.json")" == "$expected_gate" && "$(/usr/bin/jq -r '.status' "$dep_root/manifest-v1.json")" == 'passed' && "$(/usr/bin/jq -r '.sourceCommit' "$dep_root/manifest-v1.json")" == "$source_commit" && "$manifest_source_digest" == "$record_source_digest" && "$manifest_config_digest" == "$record_config_digest" && "$manifest_toolchain_digest" == "$record_toolchain_digest" ]] || die "Gate 13 dependency gate $expected_gate manifest binding is invalid." 69
  validate_checksum_manifest "$dep_root/evidence-v1.sha256" "$dep_root" || die "Gate 13 dependency gate $expected_gate checksum manifest failed verification." 69
  verify_cms_payload "$dep_root/evidence-v1.cms" "$dep_root/evidence-v1.sha256" "dependency-${expected_gate}" || die "Gate 13 dependency gate $expected_gate CMS verification failed." 69
}

validate_dependency_file() {
  local file="$1" expected_gates="$2" dep_gate record seen=''
  private_file_0600 "$file" || die 'Gate 13 dependency evidence must be a canonical private regular file.' 69
  "$jq_path" -e 'type=="object" and (keys|sort)==["records","schema"] and .schema=="hostwright.phase09.dependency-evidence.v1" and (.records|type)=="array"' "$file" >/dev/null || die 'Gate 13 dependency evidence schema mismatch.' 69
  for dep_gate in $expected_gates; do
    record="$(/usr/bin/jq -c --argjson gate "$dep_gate" '.records[] | select(.gate == $gate)' "$file")"
    [[ -n "$record" ]] || die "Gate 13 dependency evidence lacks gate $dep_gate." 69
    [[ "$seen" != *"|$dep_gate|"* ]] || die "Gate 13 dependency evidence duplicates gate $dep_gate." 69
    seen="${seen}|${dep_gate}|"
    validate_dependency_record "$record" "$dep_gate"
  done
  [[ "$(/usr/bin/jq -r '.records | length' "$file")" == "$(printf '%s\n' $expected_gates | /usr/bin/wc -l | /usr/bin/tr -d ' ')" ]] || die 'Gate 13 dependency evidence contains extra or missing records.' 69
}

validate_formal_prerequisites() {
  evidence_parent="$(/bin/realpath "$(dependency_parent)")"
  [[ -d "$evidence_parent" && ! -L "$evidence_parent" ]] || die 'Gate 13 evidence dependency parent is unavailable.' 69
  local completion_commit="${HOSTWRIGHT_PHASE09_PHASE08_COMPLETION_COMMIT:-}" dependency_file receipt="${HOSTWRIGHT_PHASE09_PHASE08_COMPLETION_RECEIPT:-}" receipt_directory
  [[ "$completion_commit" =~ ^[0-9a-f]{40}$ ]] || die 'Gate 13 requires an exact lowercase 40-hex Phase 08 completion commit.' 69
  if ! "$git_path" merge-base --is-ancestor "$completion_commit" HEAD; then
    die 'The supplied Phase 08 completion commit is not an ancestor of current Phase 09 HEAD.' 69
  fi
  validate_receipt
  dependency_file="${HOSTWRIGHT_PHASE09_GATE13_DEPENDENCY_EVIDENCE:-}"
  [[ -n "$dependency_file" ]] || die 'Gate 13 requires HOSTWRIGHT_PHASE09_GATE13_DEPENDENCY_EVIDENCE.' 69
  validate_dependency_file "$dependency_file" '8 9 10 11 12'
  if [[ -f "$root/dependency-evidence-v1.json" ]]; then
    [[ "$(sha "$dependency_file")" == "$(sha "$root/dependency-evidence-v1.json")" ]] || die 'Gate 13 dependency evidence changed after preparation.' 73
    [[ "$(sha "$receipt")" == "$(sha "$root/phase08-completion-receipt-v1.json")" ]] || die 'Gate 13 completion receipt changed after preparation.' 73
    receipt_directory="$(/bin/realpath "$(path_parent "$receipt")")"
    [[ "$(sha "$receipt_directory/phase08-completion-receipt-v1.sha256")" == "$(sha "$root/phase08-completion-receipt-v1.sha256")" && "$(sha "$receipt_directory/phase08-completion-receipt-v1.cms")" == "$(sha "$root/phase08-completion-receipt-v1.cms")" ]] || die 'Gate 13 completion receipt sidecar changed after preparation.' 73
    if [[ -e "$root/manifest-v1.json" || -L "$root/manifest-v1.json" ]]; then
      private_file_0600 "$root/manifest-v1.json" || die 'Gate 13 prepared manifest is unsafe; preserve this root.' 73
      [[ "$(sha "$root/dependency-evidence-v1.json")" == "$(/usr/bin/jq -r '.dependencyEvidenceDigest' "$root/manifest-v1.json")" && "$(canonical_json_digest "$root/dependency-evidence-v1.json")" == "$(/usr/bin/jq -r '.dependencyEvidenceCanonicalDigest' "$root/manifest-v1.json")" && "$(sha "$root/phase08-completion-receipt-v1.json")" == "$(/usr/bin/jq -r '.phase08CompletionReceiptDigest' "$root/manifest-v1.json")" && "$(sha "$root/phase08-completion-receipt-v1.sha256")" == "$(/usr/bin/jq -r '.phase08CompletionReceiptChecksumDigest' "$root/manifest-v1.json")" && "$(sha "$root/phase08-completion-receipt-v1.cms")" == "$(/usr/bin/jq -r '.phase08CompletionReceiptCMSDigest' "$root/manifest-v1.json")" ]] || die 'Gate 13 manifest prerequisite bindings changed after preparation.' 73
    fi
  fi
}

write_prepared_evidence() {
  local dependency_file receipt receipt_directory
  dependency_file="$HOSTWRIGHT_PHASE09_GATE13_DEPENDENCY_EVIDENCE"
  receipt="$HOSTWRIGHT_PHASE09_PHASE08_COMPLETION_RECEIPT"
  receipt_directory="$(/bin/realpath "$(path_parent "$receipt")")"
  atomic_copy "$dependency_file" "$root/dependency-evidence-v1.json" || die 'Gate 13 dependency evidence copy failed closed.' 73
  atomic_copy "$receipt" "$root/phase08-completion-receipt-v1.json" || die 'Gate 13 completion receipt copy failed closed.' 73
  atomic_copy "$receipt_directory/phase08-completion-receipt-v1.sha256" "$root/phase08-completion-receipt-v1.sha256" || die 'Gate 13 completion receipt checksum copy failed closed.' 73
  atomic_copy "$receipt_directory/phase08-completion-receipt-v1.cms" "$root/phase08-completion-receipt-v1.cms" || die 'Gate 13 completion receipt CMS copy failed closed.' 73
  validate_receipt_file "$root/phase08-completion-receipt-v1.json" "$root/phase08-completion-receipt-v1.sha256" "$root/phase08-completion-receipt-v1.cms" true
  printf '%s\n' "$state_header" | atomic_write_from_stdin "$root/state-v1.tsv" || die 'Gate 13 state preparation write failed closed.' 73
  printf '%s\n' "$ownership_header" | atomic_write_from_stdin "$root/ownership-v1.tsv" || die 'Gate 13 ownership preparation write failed closed.' 73
  toolchain_snapshot | atomic_write_from_stdin "$root/toolchain-v1.txt" || die 'Gate 13 toolchain preparation write failed closed.' 73
  /usr/bin/jq -n \
    --arg schema "$schema" --argjson gate "$gate" --arg commit "$source_commit" \
    --arg source "$source_digest_value" --arg config "$config_digest_value" \
    --arg toolchain "$toolchain_digest_value" --arg matrix "$(matrix_digest)" \
    --arg deps "$(sha "$root/dependency-evidence-v1.json")" \
    --arg depsCanonical "$(canonical_json_digest "$root/dependency-evidence-v1.json")" \
    --arg receipt "$(sha "$root/phase08-completion-receipt-v1.json")" \
    --arg receiptChecksum "$(sha "$root/phase08-completion-receipt-v1.sha256")" \
    --arg receiptCMS "$(sha "$root/phase08-completion-receipt-v1.cms")" \
    --arg prepared "$(now)" --arg testMode "$(testing && printf true || printf false)" --arg cert "$signing_certificate_sha256" --arg fingerprint "$signing_fingerprint" --arg team "$signing_team_id" --arg identity "$signing_identity" \
    '{schema:$schema,gate:$gate,status:"prepared",testMode:($testMode=="true"),preparedAt:$prepared,completedAt:null,
      sourceCommit:$commit,sourceDigest:$source,configDigest:$config,toolchainDigest:$toolchain,matrixDigest:$matrix,
      dependencyEvidenceDigest:$deps,dependencyEvidenceCanonicalDigest:$depsCanonical,phase08CompletionReceiptDigest:$receipt,phase08CompletionReceiptChecksumDigest:$receiptChecksum,phase08CompletionReceiptCMSDigest:$receiptCMS,cellOrder:[1,2,3,4,5,6],
      evidenceClasses:["U","I","L","M","S","R"],formalClaim:false,cmsSigner:{certificateSHA256:$cert,fingerprint:$fingerprint,teamID:$team,identity:$identity}}' \
    | atomic_write_from_stdin "$root/manifest-v1.json" || die 'Gate 13 manifest preparation write failed closed.' 73
}

validate_prepared() {
  local status receipt_digest receipt_checksum_digest receipt_cms_digest
  private_file_0600 "$root/manifest-v1.json" || die 'Gate 13 evidence root is not prepared or manifest is not private.' 73
  status="$(/usr/bin/jq -r '.status' "$root/manifest-v1.json")"
  case "$status" in
    prepared)
      [[ ! -e "$root/evidence-v1.sha256" && ! -L "$root/evidence-v1.sha256" && ! -e "$root/evidence-v1.cms" && ! -L "$root/evidence-v1.cms" ]] || die 'Gate 13 prepared evidence has an incomplete final seal; preserve this root.' 73
      ;;
    passed)
      private_file_0600 "$root/evidence-v1.sha256" && private_file_0600 "$root/evidence-v1.cms" || die 'Gate 13 passed evidence is missing one or both final seal files; preserve this root.' 73
      ;;
    failed)
      die 'Gate 13 evidence is frozen after failure; preserve this root.' 73
      ;;
    *)
      die 'Gate 13 manifest status is not runnable; preserve this root.' 73
      ;;
  esac
  validate_manifest_shape || die 'Gate 13 manifest schema, mode, or signer shape is invalid.' 73
  [[ "$(/usr/bin/jq -r '.cmsSigner.certificateSHA256' "$root/manifest-v1.json")" == "$(lowercase "$signing_certificate_sha256")" && "$(/usr/bin/jq -r '.cmsSigner.fingerprint' "$root/manifest-v1.json")" == "$signing_fingerprint" && "$(/usr/bin/jq -r '.cmsSigner.teamID' "$root/manifest-v1.json")" == "$signing_team_id" && "$(/usr/bin/jq -r '.cmsSigner.identity' "$root/manifest-v1.json")" == "$signing_identity" ]] || die 'Gate 13 manifest signer pin changed; preserve this root.' 73
  [[ "$(/usr/bin/jq -r '.sourceDigest' "$root/manifest-v1.json")" == "$source_digest_value" && "$(/usr/bin/jq -r '.configDigest' "$root/manifest-v1.json")" == "$config_digest_value" && "$(/usr/bin/jq -r '.toolchainDigest' "$root/manifest-v1.json")" == "$toolchain_digest_value" && "$(/usr/bin/jq -r '.matrixDigest' "$root/manifest-v1.json")" == "$(matrix_digest)" ]] || die 'Gate 13 prepared evidence dependencies changed; preserve this root.' 73
  [[ -f "$root/dependency-evidence-v1.json" && -f "$root/phase08-completion-receipt-v1.json" && -f "$root/phase08-completion-receipt-v1.sha256" && -f "$root/phase08-completion-receipt-v1.cms" ]] || die 'Gate 13 prerequisite evidence changed; preserve this root.' 73
  private_file_0600 "$root/dependency-evidence-v1.json" && private_file_0600 "$root/phase08-completion-receipt-v1.json" && private_file_0600 "$root/phase08-completion-receipt-v1.sha256" && private_file_0600 "$root/phase08-completion-receipt-v1.cms" || die 'Gate 13 prerequisite evidence is not private; preserve this root.' 73
  receipt_digest="$(sha "$root/phase08-completion-receipt-v1.json")"
  receipt_checksum_digest="$(sha "$root/phase08-completion-receipt-v1.sha256")"
  receipt_cms_digest="$(sha "$root/phase08-completion-receipt-v1.cms")"
  [[ "$(sha "$root/dependency-evidence-v1.json")" == "$(/usr/bin/jq -r '.dependencyEvidenceDigest' "$root/manifest-v1.json")" && "$(canonical_json_digest "$root/dependency-evidence-v1.json")" == "$(/usr/bin/jq -r '.dependencyEvidenceCanonicalDigest' "$root/manifest-v1.json")" && "$receipt_digest" == "$(/usr/bin/jq -r '.phase08CompletionReceiptDigest' "$root/manifest-v1.json")" && "$receipt_checksum_digest" == "$(/usr/bin/jq -r '.phase08CompletionReceiptChecksumDigest' "$root/manifest-v1.json")" && "$receipt_cms_digest" == "$(/usr/bin/jq -r '.phase08CompletionReceiptCMSDigest' "$root/manifest-v1.json")" ]] || die 'Gate 13 prerequisite evidence changed; preserve this root.' 73
  validate_receipt_file "$root/phase08-completion-receipt-v1.json" "$root/phase08-completion-receipt-v1.sha256" "$root/phase08-completion-receipt-v1.cms" true
  validate_formal_prerequisites
}

revalidate_dependencies() {
  local dependency_file="${HOSTWRIGHT_PHASE09_GATE13_DEPENDENCY_EVIDENCE:-}" current_dependency_digest current_dependency_canonical_digest
  [[ "$(source_digest)" == "$source_digest_value" ]] || die 'Gate 13 source digest changed during qualification; preserve this root.' 73
  [[ "$(config_digest)" == "$config_digest_value" ]] || die 'Gate 13 configuration digest changed during qualification; preserve this root.' 73
  [[ "$(toolchain_digest)" == "$toolchain_digest_value" ]] || die 'Gate 13 toolchain digest changed during qualification; preserve this root.' 73
  validate_formal_prerequisites
  current_dependency_digest="$(sha "$dependency_file")"
  current_dependency_canonical_digest="$(canonical_json_digest "$dependency_file")"
  [[ -n "$dependency_digest_value" && "$current_dependency_digest" == "$dependency_digest_value" && "$current_dependency_canonical_digest" == "$dependency_canonical_digest_value" ]] || die 'Gate 13 dependency digest changed during qualification; preserve this root.' 73
  [[ -f "$root/dependency-evidence-v1.json" && "$current_dependency_digest" == "$(sha "$root/dependency-evidence-v1.json")" && "$current_dependency_canonical_digest" == "$(canonical_json_digest "$root/dependency-evidence-v1.json")" ]] || die 'Gate 13 prepared dependency copy changed during qualification; preserve this root.' 73
}

matrix_filter() {
  /usr/bin/jq -r --argjson cell "$1" '[.tests[] | select(.cell == $cell) | .selector] | join("|")' "$matrix_path"
}

matrix_expected() {
  /usr/bin/jq -r --argjson cell "$1" '[.tests[] | select(.cell == $cell)] | length' "$matrix_path"
}

cell_command() {
  case "$1" in
    1) printf '%s\n' 'swift test --jobs 1 --filter Gate13 schema 17→18→19→20→21 migration compatibility selectors' ;;
    2) printf '%s\n' 'swift test --jobs 1 --filter verified backup and rollback refusal selectors' ;;
    3) printf '%s\n' 'swift test --jobs 1 --filter checksum and future-schema rejection selectors' ;;
    4) printf '%s\n' 'swift test --jobs 1 --filter legacy/current envelope replay and idempotency conflict selectors' ;;
    5) printf '%s\n' 'swift test --jobs 1 --filter frozen CLI transport parity selectors' ;;
    6) printf '%s\n' 'swift test --jobs 1 --filter aggregate contract and version decode selectors' ;;
    *) die 'unknown Gate 13 cell.' 70 ;;
  esac
}

run_xctest_cell() {
  local filter="$1" xunit_dir="$2" xunit_base="$3" expected="$4" test_bundle observer runner compiler platform sdk selectors
  if testing; then
    HOSTWRIGHT_PHASE09_EXPECTED_TESTS="$expected" HOSTWRIGHT_PHASE09_EXPECTED_SELECTORS_JSON="$(/usr/bin/jq -c --argjson cell "${HOSTWRIGHT_PHASE09_INTERNAL_CELL_ID:?}" '[.tests[]|select(.cell==$cell)|.selector]' "$matrix_path")" \
      swift_exec test --jobs 1 --filter "$filter" --xunit-output "$xunit_base"
    return
  fi
  swift_exec test list --jobs 1 >/dev/null
  test_bundle="$(swift_exec build --show-bin-path)/hostwrightPackageTests.xctest"
  [[ -d "$test_bundle" && ! -L "$test_bundle" && "$(/bin/realpath "$test_bundle")" == "$test_bundle" ]] || die 'Gate 13 XCTest bundle is unavailable or unsafe.' 74
  compiler="$("$xcrun_path" --find clang)"; runner="$(/bin/realpath "$("$xcrun_path" --find xctest)")"; platform="$("$xcrun_path" --sdk macosx --show-sdk-platform-path)"; sdk="$(/bin/realpath "$("$xcrun_path" --sdk macosx --show-sdk-path)")"
  validate_formal_tool "$compiler"; validate_formal_tool "$runner"
  [[ -d "$platform" && ! -L "$platform" && "$(/bin/realpath "$platform")" == "$platform" && -d "$sdk" && ! -L "$sdk" && "$(/bin/realpath "$sdk")" == "$sdk" ]] || die 'Gate 13 XCTest platform is unavailable or unsafe.' 74
  observer="$xunit_dir/phase09-xctest-observer.dylib"
  "$compiler" -isysroot "$sdk" -fobjc-arc -dynamiclib -F "$platform/Developer/Library/Frameworks" -framework Foundation -framework XCTest "$xctest_observer_source" -o "$observer"
  [[ -f "$observer" && ! -L "$observer" ]] || die 'Gate 13 XCTest observer compilation produced no regular file.' 74
  selectors="${filter//|/,}"
  HOSTWRIGHT_PHASE09_XCTEST_XUNIT_OUTPUT="$xunit_base" DYLD_INSERT_LIBRARIES="$observer" \
    "$runner" -XCTest "$selectors" "$test_bundle"
}

run_cell() {
  local cell="$1" filter expected xunit_dir xunit_base candidate final_result runner_status
  if testing && [[ "${HOSTWRIGHT_PHASE09_HARNESS_TEST_FORCE_FAILURE_CELL:-}" == "$cell" ]]; then
    return 47
  fi
  filter="$(matrix_filter "$cell")"
  expected="$(matrix_expected "$cell")"
  [[ -n "$filter" && "$expected" =~ ^[1-9][0-9]*$ ]] || die 'Gate 13 cannot execute an empty compatibility selector.' 69
  xunit_dir="$(make_private_directory "xunit-$cell")"
  xunit_base="$xunit_dir/result"
  set +e
  HOSTWRIGHT_PHASE09_INTERNAL_CELL_ID="$cell" run_xctest_cell "$filter" "$xunit_dir" "$xunit_base" "$expected"
  runner_status=$?
  set -e
  candidate=''
  for candidate_name in "$xunit_base-swift-testing.xml" "$xunit_base-swift-testing" "$xunit_base" "$xunit_base.xml"; do
    if [[ -e "$candidate_name" || -L "$candidate_name" ]]; then candidate="$candidate_name"; break; fi
  done
  [[ -n "$candidate" ]] || candidate="$xunit_base"
  if [[ "$runner_status" != 0 ]]; then
    dispose_private_artifact "$candidate" "$xunit_dir" || true
    die 'Gate 13 structured result generation failed closed.' 74
  fi
  if ! atomic_harden "$candidate"; then
    dispose_private_artifact "$candidate" "$xunit_dir" || true
    die 'Gate 13 structured result hardening failed closed.' 74
  fi
  if ! private_file_0600 "$candidate"; then
    dispose_private_artifact "$candidate" "$xunit_dir" || true
    die 'Gate 13 test runner did not produce a private structured xUnit result.' 74
  fi
  if ! validate_structured_results "$candidate" "$cell" >/dev/null; then
    dispose_private_artifact "$candidate" "$xunit_dir" || true
    die "Gate 13 cell $cell structured selector evidence is invalid." 74
  fi
  final_result="$root/cell-$(printf '%02d' "$cell").xunit.xml"
  if ! atomic_copy "$candidate" "$final_result"; then
    dispose_private_artifact "$candidate" "$xunit_dir" || true
    die 'Gate 13 structured result publication failed closed.' 73
  fi
  dispose_private_artifact "$candidate" "$xunit_dir" || die 'Gate 13 xUnit temporary directory could not be disposed.' 73
}

validate_structured_results() {
  local result="$1" cell="$2" selectors expected
  selectors="$(/usr/bin/jq -c --argjson cell "$cell" '[.tests[]|select(.cell==$cell)|.selector]' "$matrix_path")"; expected="$(matrix_expected "$cell")"
  private_file_0600 "$result" || return 1
  "$python_path" - "$result" "$selectors" "$expected" <<'PY'
import json, sys, xml.etree.ElementTree as ET
from collections import Counter
path, selectors, expected = sys.argv[1:]
raw = open(path, 'rb').read()
if b'<!DOCTYPE' in raw or b'<!ENTITY' in raw: raise SystemExit(1)
root = ET.fromstring(raw); wanted = Counter(json.loads(selectors)); cases = list(root.iter('testcase')); seen = Counter()
for case in cases:
    if list(case): raise SystemExit(1)
    cls = case.attrib.get('classname', '').rsplit('.', 1)[-1]; name = case.attrib.get('name', '')
    ident = f'{cls}/{name}'
    if not cls or not name or ident not in wanted: raise SystemExit(1)
    seen[ident] += 1
    if seen[ident] > wanted[ident]: raise SystemExit(1)
if len(cases) != int(expected) or seen != wanted: raise SystemExit(1)
for suite in root.iter('testsuite'):
    if 'tests' in suite.attrib and int(suite.attrib['tests']) != len(cases): raise SystemExit(1)
    if any(int(suite.attrib.get(k, '0')) != 0 for k in ('failures','errors','skipped')): raise SystemExit(1)
print(len(cases))
PY
}

run_diagnostic_cell() {
  local cell="$1" filter expected output diagnostic_dir xunit_base candidate
  filter="$(matrix_filter "$cell")"
  expected="$(matrix_expected "$cell")"
  diagnostic_dir="$(/usr/bin/mktemp -d -t hostwright-phase09-gate13-diagnose)"
  diagnostic_dir="$(/bin/realpath "$diagnostic_dir")"
  /bin/chmod 700 "$diagnostic_dir"
  xunit_base="$diagnostic_dir/result"
  set +e
  output="$(HOSTWRIGHT_PHASE09_INTERNAL_CELL_ID="$cell" run_xctest_cell "$filter" "$diagnostic_dir" "$xunit_base" "$expected" 2>&1)"
  diagnostic_status=$?
  set -e
  candidate="$xunit_base-swift-testing.xml"; [[ -e "$candidate" || -L "$candidate" ]] || candidate="$xunit_base"
  diagnostic_observed='null'
  [[ -f "$candidate" && ! -L "$candidate" ]] && atomic_harden "$candidate" 2>/dev/null || true
  [[ "$diagnostic_status" == 0 && -f "$candidate" && ! -L "$candidate" ]] && diagnostic_observed="$(validate_structured_results "$candidate" "$cell" 2>/dev/null || true)"
  /bin/unlink "$candidate" 2>/dev/null || true; /bin/rmdir "$diagnostic_dir" 2>/dev/null || true
}

diagnose() {
  matrix_validate
  local cells='' cell expected observed status total=0 exact=true observed_json
  for cell in 1 2 3 4 5 6; do
    run_diagnostic_cell "$cell"
    expected="$(matrix_expected "$cell")"; observed="${diagnostic_observed:-null}"; status="$diagnostic_status"
    [[ "$diagnostic_status" == 0 && "$diagnostic_observed" == "$expected" ]] || exact=false
    [[ "$diagnostic_observed" =~ ^[0-9]+$ ]] && total=$((total + diagnostic_observed))
    observed_json='null'
    [[ "$diagnostic_observed" =~ ^[0-9]+$ ]] && observed_json="$diagnostic_observed"
    [[ -z "$cells" ]] || cells="${cells},"
    cells="${cells}{\"cell\":${cell},\"expectedTests\":${expected},\"observedTests\":${observed_json},\"status\":${status}}"
  done
  /usr/bin/jq -n --arg schema "$schema" --argjson gate "$gate" --arg claim none --arg status diagnostic \
    --arg sourceCommit "$("$git_path" rev-parse HEAD)" --arg matrixDigest "$(matrix_digest)" \
    --argjson cells "[${cells}]" --argjson expected "$test_count" --argjson observed "$total" --arg exact "$exact" \
    '{schema:$schema,gate:$gate,claim:$claim,status:$status,qualifying:false,sourceCommit:$sourceCommit,matrixDigest:$matrixDigest,
      expectedTests:$expected,observedTests:$observed,exactCount:($exact=="true"),cells:$cells,prerequisites:"not evaluated by diagnose"}'
}

append_state() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$gate" "$1" "$2" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" "$3" "$4" "$5" "$6" "$7" | atomic_log_replace_from_stdin "$root/state-v1.tsv" || die 'Gate 13 state log replacement failed closed.' 74
}

append_failure() {
  if [[ ! -e "$root/failure-v1.tsv" && ! -L "$root/failure-v1.tsv" ]]; then
    printf '%s\n' $'recorded_at\tgate\tcell\texit_status\tcommand\tsource_digest\tconfig_digest\ttoolchain_digest\tstdout_sha256\tstderr_sha256\tstructured_result_sha256' | atomic_write_from_stdin "$root/failure-v1.tsv" || die 'Gate 13 failure ledger creation failed closed.' 74
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$gate" "$1" "$2" "$3" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" "$4" "$5" "$6" | atomic_log_replace_from_stdin "$root/failure-v1.tsv" || die 'Gate 13 failure ledger log replacement failed closed.' 74
}

mark_failed() {
  [[ -f "$root/manifest-v1.json" && ! -L "$root/manifest-v1.json" ]] || return 0
  [[ "$(/usr/bin/jq -r '.status' "$root/manifest-v1.json" 2>/dev/null || true)" != failed ]] || return 0
  /usr/bin/jq --arg failedAt "$(now)" '.status="failed"|.failedAt=$failedAt|.formalClaim=false' "$root/manifest-v1.json" | atomic_replace_from_stdin "$root/manifest-v1.json" || return 74
}

verify_cms_binding() {
  validate_checksum_manifest "$1/evidence-v1.sha256" "$1" && verify_cms_payload "$1/evidence-v1.cms" "$1/evidence-v1.sha256" dependency
}

expected_inventory() {
  local mode="${1:-passed}" cell
  printf '%s\n' manifest-v1.json dependency-evidence-v1.json phase08-completion-receipt-v1.json phase08-completion-receipt-v1.sha256 phase08-completion-receipt-v1.cms state-v1.tsv ownership-v1.tsv toolchain-v1.txt
  [[ "$mode" == passed ]] || return 0
  printf '%s\n' gate-active-run-v1-info.tsv
  for cell in 1 2 3 4 5 6; do printf 'cell-%02d.stdout.log\ncell-%02d.stderr.log\ncell-%02d.xunit.xml\n' "$cell" "$cell" "$cell"; done
  printf '%s\n' evidence-v1.sha256 evidence-v1.cms
}

checksum_manifest_inventory() {
  staged_digest_inventory
}

staged_digest_inventory() {
  local staged_manifest="${1:-$root/manifest-v1.json}" file actual
  {
    while IFS= read -r file; do
      if [[ "$file" == manifest-v1.json ]]; then actual="$staged_manifest"; else actual="$root/$file"; fi
      printf '%s  %s\n' "$(sha "$actual")" "$file"
    done < <({
      expected_inventory prepared
      printf '%s\n' gate-active-run-v1-info.tsv
      for cell in 1 2 3 4 5 6; do printf 'cell-%02d.stdout.log\ncell-%02d.stderr.log\ncell-%02d.xunit.xml\n' "$cell" "$cell" "$cell"; done
    })
  } | LC_ALL=C /usr/bin/sort | "$awk_path" '{print $2}'
}

validate_reuse_ledger() {
  local expected_cell=1 gate_value cell status source config toolchain started finished stdout_sha stderr_sha xunit_sha extra
  private_file_0600 "$root/state-v1.tsv" || return 1
  [[ "$(/usr/bin/head -n 1 "$root/state-v1.tsv")" == "$state_header" ]] || return 1
  [[ "$(/usr/bin/wc -l < "$root/state-v1.tsv" | /usr/bin/tr -d ' ')" == 7 ]] || return 1
  while IFS=$'\t' read -r gate_value cell status source config toolchain started finished stdout_sha stderr_sha xunit_sha extra; do
    [[ -z "${extra:-}" && "$gate_value" == "$gate" && "$cell" == "$expected_cell" && "$status" == pass && "$source" == "$source_digest_value" && "$config" == "$config_digest_value" && "$toolchain" == "$toolchain_digest_value" ]] || return 1
    [[ "$started" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ && "$finished" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ && "$stdout_sha" =~ ^[a-f0-9]{64}$ && "$stderr_sha" =~ ^[a-f0-9]{64}$ && "$xunit_sha" =~ ^[a-f0-9]{64}$ ]] || return 1
    expected_cell=$((expected_cell + 1))
  done < <(/usr/bin/tail -n +2 "$root/state-v1.tsv")
  [[ "$expected_cell" == 7 ]]
}

validate_staged_digest() {
  local digest="$1" staged_manifest="$2" expected name rest actual count=0 names=''
  private_file_0600 "$digest" && private_file_0600 "$staged_manifest" || return 1
  while IFS=$' \t' read -r expected name rest; do
    case "$name" in
      ..|*..*|/*|.*) return 1 ;;
    esac
    [[ "$expected" =~ ^[a-f0-9]{64}$ && -n "$name" && -z "${rest:-}" ]] || return 1
    case "$name" in
      manifest-v1.json) actual="$staged_manifest" ;;
      *) actual="$root/$name" ;;
    esac
    private_file_0600 "$actual" || return 1
    [[ "$(sha "$actual")" == "$expected" ]] || return 1
    names="${names}${name}\n"; count=$((count + 1))
  done < "$digest"
  [[ "$count" == 27 ]] || return 1
  [[ "$(printf '%b' "$names")" == "$(staged_digest_inventory "$staged_manifest")" ]] || return 1
  [[ "$(printf '%b' "$names" | /usr/bin/uniq -d | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 0 ]]
}

validate_manifest_shape() {
  local test_mode
  test_mode="$(testing && printf true || printf false)"
  /usr/bin/jq -e --arg schema "$schema" --argjson gate "$gate" --arg source "$source_commit" --argjson testMode "$test_mode" --arg cert "$(lowercase "$signing_certificate_sha256")" --arg fingerprint "$signing_fingerprint" --arg team "$signing_team_id" --arg identity "$signing_identity" \
    'type=="object" and (keys|sort)==["cellOrder","cmsSigner","completedAt","configDigest","dependencyEvidenceCanonicalDigest","dependencyEvidenceDigest","evidenceClasses","formalClaim","gate","matrixDigest","phase08CompletionReceiptCMSDigest","phase08CompletionReceiptChecksumDigest","phase08CompletionReceiptDigest","preparedAt","schema","sourceCommit","sourceDigest","status","testMode","toolchainDigest"] and .schema==$schema and .gate==$gate and (.status=="prepared" or .status=="passed") and .sourceCommit==$source and (.sourceCommit|test("^[0-9a-f]{40}$")) and .testMode==$testMode and ((.status=="prepared" and .formalClaim==false) or (.status=="passed" and .formalClaim==(.testMode|not))) and .cmsSigner=={certificateSHA256:$cert,fingerprint:$fingerprint,teamID:$team,identity:$identity}' "$root/manifest-v1.json" >/dev/null
}

compare_inventory() {
  local mode="$1" expected actual
  expected="$(expected_inventory "$mode" | LC_ALL=C /usr/bin/sort)"
  actual="$(/usr/bin/find "$root" -mindepth 1 -maxdepth 1 -exec /usr/bin/basename {} \; | LC_ALL=C /usr/bin/sort)"
  [[ "$expected" == "$actual" ]]
}

verify_reusable() {
  local cell stdout_log stderr_log xunit_log expected_out expected_err expected_xunit
  [[ "$(/usr/bin/jq -r '.status' "$root/manifest-v1.json")" == 'passed' ]] || return 1
  compare_inventory passed || return 1
  validate_reuse_ledger || return 1
  for cell in 1 2 3 4 5 6; do
    stdout_log="$root/cell-$(printf '%02d' "$cell").stdout.log"; stderr_log="$root/cell-$(printf '%02d' "$cell").stderr.log"; xunit_log="$root/cell-$(printf '%02d' "$cell").xunit.xml"
    [[ -f "$stdout_log" && -f "$stderr_log" && -f "$xunit_log" && ! -L "$stdout_log" && ! -L "$stderr_log" && ! -L "$xunit_log" ]] || return 1
    validate_structured_results "$xunit_log" "$cell" >/dev/null || return 1
    /usr/bin/awk -F $'\t' -v gate="$gate" -v cell="$cell" -v source="$source_digest_value" -v config="$config_digest_value" -v toolchain="$toolchain_digest_value" '$1==gate&&$2==cell&&$3=="pass"&&$4==source&&$5==config&&$6==toolchain{found=1}END{exit(found?0:1)}' "$root/state-v1.tsv" || return 1
    expected_out="$(/usr/bin/awk -F $'\t' -v cell="$cell" '$2==cell&&$3=="pass"{x=$9}END{print x}' "$root/state-v1.tsv")"
    expected_err="$(/usr/bin/awk -F $'\t' -v cell="$cell" '$2==cell&&$3=="pass"{x=$10}END{print x}' "$root/state-v1.tsv")"
    expected_xunit="$(/usr/bin/awk -F $'\t' -v cell="$cell" '$2==cell&&$3=="pass"{x=$11}END{print x}' "$root/state-v1.tsv")"
    [[ "$(sha "$stdout_log")" == "$expected_out" && "$(sha "$stderr_log")" == "$expected_err" && "$(sha "$xunit_log")" == "$expected_xunit" ]] || return 1
  done
  private_file_0600 "$root/evidence-v1.sha256" && private_file_0600 "$root/evidence-v1.cms" || return 1
  validate_checksum_manifest "$root/evidence-v1.sha256" "$root" exact && verify_cms_payload "$root/evidence-v1.cms" "$root/evidence-v1.sha256" reusable
}

write_evidence() {
  local completed="$1" digest cms cms_dir manifest_tmp file
  revalidate_dependencies
  for file in "$root/.evidence-v1.sha256.tmp" "$root/.evidence-v1.cms.tmp" "$root/.evidence-v1.decoded.tmp" "$root/.manifest-v1.passed.tmp"; do assert_absent "$file" || die 'Gate 13 fixed sealing temporary already exists or is symlinked; preserve this root.' 73; done
  validate_formal_prerequisites
  validate_receipt_file "$root/phase08-completion-receipt-v1.json" "$root/phase08-completion-receipt-v1.sha256" "$root/phase08-completion-receipt-v1.cms" true
  atomic_publish "$parent/.phase09-gate13-active-v1/info-v1.tsv" "$root/gate-active-run-v1-info.tsv" || die 'Gate 13 active-run inventory publication failed closed.' 73
  manifest_tmp="$(make_private_temp manifest-passed)"; digest="$(make_private_temp evidence-digest)"; cms_dir="$(make_private_directory cms-sign)"; cms="$cms_dir/output.cms"
  /usr/bin/jq --arg completed "$completed" '.status="passed"|.completedAt=$completed|.formalClaim=(.testMode|not)' "$root/manifest-v1.json" | atomic_replace_from_stdin "$manifest_tmp"
  { printf '%s  manifest-v1.json\n' "$(sha "$manifest_tmp")"; for file in dependency-evidence-v1.json phase08-completion-receipt-v1.json phase08-completion-receipt-v1.sha256 phase08-completion-receipt-v1.cms state-v1.tsv ownership-v1.tsv toolchain-v1.txt gate-active-run-v1-info.tsv cell-01.stdout.log cell-01.stderr.log cell-01.xunit.xml cell-02.stdout.log cell-02.stderr.log cell-02.xunit.xml cell-03.stdout.log cell-03.stderr.log cell-03.xunit.xml cell-04.stdout.log cell-04.stderr.log cell-04.xunit.xml cell-05.stdout.log cell-05.stderr.log cell-05.xunit.xml cell-06.stdout.log cell-06.stderr.log cell-06.xunit.xml; do private_file_0600 "$root/$file" || die "Gate 13 cannot seal missing or unsafe $file." 74; printf '%s  %s\n' "$(sha "$root/$file")" "$file"; done; } | LC_ALL=C /usr/bin/sort | atomic_replace_from_stdin "$digest"
  validate_staged_digest "$digest" "$manifest_tmp" || die 'Gate 13 staged checksum inventory is incomplete, duplicated, or changed.' 74
  if ! security_exec cms -S -N "$signing_identity" -H SHA256 -u 9 -i "$digest" -o "$cms"; then
    dispose_private_artifact "$cms" "$cms_dir" || true
    die 'Gate 13 CMS evidence signing failed.' 74
  fi
  if ! atomic_harden "$cms"; then
    dispose_private_artifact "$cms" "$cms_dir" || true
    die 'Gate 13 CMS output hardening failed closed.' 74
  fi
  if ! private_file_0600 "$cms"; then
    dispose_private_artifact "$cms" "$cms_dir" || true
    die 'Gate 13 CMS output identity or mode changed.' 74
  fi
  if ! verify_cms_payload "$cms" "$digest" final; then
    dispose_private_artifact "$cms" "$cms_dir" || true
    die 'Gate 13 staged CMS evidence did not round-trip with the pinned signer.' 74
  fi
  assert_absent "$root/evidence-v1.sha256" && assert_absent "$root/evidence-v1.cms" || die 'Gate 13 final evidence destination already exists or is symlinked.' 73
  private_file_0600 "$root/manifest-v1.json" || die 'Gate 13 prepared manifest is unsafe at finalization.' 73
  validate_receipt_file "$root/phase08-completion-receipt-v1.json" "$root/phase08-completion-receipt-v1.sha256" "$root/phase08-completion-receipt-v1.cms" true
  if ! atomic_copy "$digest" "$root/evidence-v1.sha256"; then
    dispose_private_artifact "$cms" "$cms_dir" || true
    die 'Gate 13 final checksum publication failed closed.' 73
  fi
  if ! atomic_copy "$cms" "$root/evidence-v1.cms"; then
    dispose_private_artifact "$cms" "$cms_dir" || true
    die 'Gate 13 final CMS publication failed closed.' 73
  fi
  if ! /bin/cat "$manifest_tmp" | atomic_replace_from_stdin "$root/manifest-v1.json"; then
    dispose_private_artifact "$cms" "$cms_dir" || true
    die 'Gate 13 final manifest publication failed closed.' 73
  fi
  /bin/unlink "$manifest_tmp"
  /bin/unlink "$digest"
  dispose_private_artifact "$cms" "$cms_dir" || die 'Gate 13 CMS external artifact could not be disposed.' 73
  validate_checksum_manifest "$root/evidence-v1.sha256" "$root" exact || die 'Gate 13 final checksum inventory failed verification.' 74
  verify_cms_payload "$root/evidence-v1.cms" "$root/evidence-v1.sha256" final || die 'Gate 13 final CMS verification failed.' 74
  revalidate_dependencies
  validate_prepared || die 'Gate 13 final receipt, manifest, or prerequisite binding failed revalidation.' 74
  /bin/rmdir "$root/active-run-v1" || die 'Gate 13 active root lock was not empty at finalization.' 74
  if ! compare_inventory passed; then /bin/mkdir "$root/active-run-v1"; /bin/chmod 700 "$root/active-run-v1"; die 'Gate 13 final evidence inventory is incomplete or changed.' 74; fi
}

release_locks() {
  if [[ "$gate_lock_created" == 1 ]]; then
    /bin/rmdir "$parent/.phase09-gate13-active-v1"
    root_lock_created=0; gate_lock_created=0
  fi
}

on_exit() {
  local status=$?
  trap - EXIT
  if [[ "$status" != 0 && "$run_active" == 1 ]]; then
    set +e; mark_failed; set -e
  fi
  if [[ "$status" == 0 && "$run_succeeded" == 1 ]]; then
    release_locks || status=$?
  fi
  exit "$status"
}

run() {
  validate_prepared
  if [[ "$(/usr/bin/jq -r '.status' "$root/manifest-v1.json")" == 'passed' ]]; then
    revalidate_dependencies
    verify_reusable || die 'Gate 13 completed evidence is incomplete or changed; preserve this root and do not rerun.' 73
    printf '%s\n' 'Gate 13 evidence is valid and reused; no cells were rerun.'
    return 0
  fi
  local lock="$parent/.phase09-gate13-active-v1" cell command stdout_log stderr_log xunit_log started finished status stdout_sha stderr_sha xunit_sha
  [[ ! -e "$lock" && ! -L "$lock" && ! -e "$root/active-run-v1" && ! -L "$root/active-run-v1" ]] || die 'An active Gate 13 qualification already exists; do not duplicate it.' 75
  for cell in 1 2 3 4 5 6; do
    stdout_log="$root/cell-$(printf '%02d' "$cell").stdout.log"; stderr_log="$root/cell-$(printf '%02d' "$cell").stderr.log"; xunit_log="$root/cell-$(printf '%02d' "$cell").xunit.xml"
    [[ ! -e "$stdout_log" && ! -L "$stdout_log" && ! -e "$stderr_log" && ! -L "$stderr_log" && ! -e "$xunit_log" && ! -L "$xunit_log" ]] || die 'Cell outputs already exist; preserve this root and do not rerun.' 73
  done
  /bin/mkdir "$lock"; /bin/chmod 700 "$lock"
  printf '%s\n' $'root\tpid\tstarted_at\tsource_digest\tconfig_digest\ttoolchain_digest' | atomic_write_from_stdin "$lock/info-v1.tsv" || die 'Gate 13 lock inventory creation failed closed.' 74
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$root" "$$" "$(now)" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" | atomic_log_replace_from_stdin "$lock/info-v1.tsv" || die 'Gate 13 lock inventory log replacement failed closed.' 74
  gate_lock_created=1
  /bin/mkdir "$root/active-run-v1"; /bin/chmod 700 "$root/active-run-v1"; root_lock_created=1
  run_active=1
  trap on_exit EXIT
  for cell in 1 2 3 4 5 6; do
    revalidate_dependencies
    command="$(cell_command "$cell")"
    stdout_log="$root/cell-$(printf '%02d' "$cell").stdout.log"; stderr_log="$root/cell-$(printf '%02d' "$cell").stderr.log"; xunit_log="$root/cell-$(printf '%02d' "$cell").xunit.xml"
    started="$(now)"
    set +e
    HOSTWRIGHT_PHASE09_INTERNAL_CELL_RUN=1 atomic_run_outputs "$stdout_log" "$stderr_log" "$bash_path" "$harness_path" cell "$cell"
    status=$?
    set -e
    if [[ "$status" == 0 ]] && ! validate_structured_results "$xunit_log" "$cell" >/dev/null; then status=74; fi
    if [[ "$status" == 0 ]] && ! revalidate_dependencies; then status=73; fi
    finished="$(now)"; stdout_sha=''; stderr_sha=''; xunit_sha=''
    if private_file_0600 "$stdout_log"; then stdout_sha="$(sha "$stdout_log")"; elif [[ "$status" == 0 ]]; then status=74; fi
    if private_file_0600 "$stderr_log"; then stderr_sha="$(sha "$stderr_log")"; elif [[ "$status" == 0 ]]; then status=74; fi
    if private_file_0600 "$xunit_log"; then xunit_sha="$(sha "$xunit_log")"; elif [[ "$status" == 0 ]]; then status=74; fi
    if [[ "$status" != 0 ]]; then
      append_state "$cell" failed "$started" "$finished" "$stdout_sha" "$stderr_sha" "$xunit_sha"
      append_failure "$cell" "$status" "$command" "$stdout_sha" "$stderr_sha" "$xunit_sha"
      mark_failed
      die "Gate 13 cell $cell failed; progress is frozen and both locks are preserved." "$status"
    fi
    append_state "$cell" pass "$started" "$finished" "$stdout_sha" "$stderr_sha" "$xunit_sha"
  done
  write_evidence "$(now)"
  run_succeeded=1
  printf '%s\n' 'Gate 13 qualification passed.'
}

prepare() {
  validate_root
  empty_root
  collect
  evidence_parent="$(/bin/realpath "$(dependency_parent)")"
  validate_formal_prerequisites
  write_prepared_evidence
  compare_inventory prepared || die 'Gate 13 prepared evidence inventory is incomplete or changed.' 74
  printf '%s\n' 'Gate 13 evidence root prepared.'
}

main() {
  [[ "$#" -ge 1 ]] || die 'usage: phase09-gate13-qualification.sh <contract|diagnose|prepare|run> [args].' 64
  case "$1" in
    contract) [[ "$#" == 1 ]] || die 'contract accepts no arguments.' 64; contract ;;
    diagnose) [[ "$#" == 1 ]] || die 'diagnose accepts no arguments.' 64; validate_worktree; cd "$repository_root"; diagnose ;;
    prepare) [[ "$#" == 2 && "$2" == 13 ]] || die 'usage: prepare 13.' 64; validate_worktree; cd "$repository_root"; validate_root; prepare ;;
    run) [[ "$#" == 2 && "$2" == 13 ]] || die 'usage: run 13.' 64; validate_worktree; cd "$repository_root"; validate_root; collect; run ;;
    cell) [[ "${HOSTWRIGHT_PHASE09_INTERNAL_CELL_RUN:-}" == 1 && "$#" == 2 && "$2" =~ ^[1-6]$ ]] || die 'unknown Gate 13 cell.' 64; validate_worktree; cd "$repository_root"; validate_root; collect; run_cell "$2" ;;
    *) die 'unknown Gate 13 qualification command.' 64 ;;
  esac
}

main "$@"
