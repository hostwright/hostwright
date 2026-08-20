#!/usr/bin/env bash
set -euo pipefail

readonly gate=15
readonly branch='feat/v0.0.2-phase-09'
readonly repository_path='/Users/dev/Documents/hostwright-phase09'
readonly protected_repository_path='/Users/dev/Documents/hostwright'
readonly live_parent='/Volumes/T9/hostwright/qualification'
readonly canonical_dependency_validator_path='/Users/dev/Documents/hostwright-phase09/scripts/phase09-gate15-qualification.sh'
readonly canonical_boundary_validator_path='/Users/dev/Documents/hostwright-phase09/scripts/phase09-gate15-live.sh'
readonly canonical_tool_path='/Users/dev/Documents/hostwright-phase09/.build/release/HostwrightPhase09QualificationTool'
readonly formal_path='/usr/bin:/bin:/usr/sbin:/sbin'
readonly root_pattern='^phase09-gate15-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
readonly manifest_schema='hostwright.phase09.gate15.qualification.manifest.v1'
readonly dependency_schema='hostwright.phase09.gate15.dependencies.v1'
readonly run_started_schema='hostwright.phase09.gate15.run-started.v1'
readonly ownership_header=$'recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity'
readonly state_header=$'gate\tcell\tresult\tsource_digest\tconfig_digest\ttoolchain_digest\tstarted_at\tended_at\tstdout_sha256\tstderr_sha256'
readonly lock_info_header=$'root\tpid\trunner_start_identity\tstarted_at\tsource_commit\tsource_digest\tconfig_digest\ttoolchain_digest\tdependency_digest\tpinset_digest\tmanifest_digest'
readonly expected_signing_identity='Developer ID Application: Dev Trivedi (993YC3JY4Q)'
readonly expected_signing_fingerprint='A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB'
readonly expected_certificate_fingerprint='A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB'
readonly expected_signing_team='993YC3JY4Q'
readonly test_signing_identity='testing-cms-signer'
readonly test_signing_fingerprint='testing-cms-fingerprint'
readonly test_certificate_fingerprint='testing-cms-certificate'
readonly test_signing_team='testing'
readonly duration_seconds=259200
readonly interval_seconds=300
readonly required_intervals=864
readonly sample_count=865
readonly user_id="$(/usr/bin/id -u)"

export PATH="$formal_path"

root=''
parent=''
source_commit=''
source_digest_value=''
config_digest_value=''
toolchain_digest_value=''
dependency_digest_value=''
pinset_digest_value=''
pinset_path_value=''
pinset_device_value=''
pinset_inode_value=''
dependency_validator_digest_value=''
dependency_validator_device_value=''
dependency_validator_inode_value=''
boundary_validator_digest_value=''
boundary_validator_device_value=''
boundary_validator_inode_value=''
signing_identity=''
signing_fingerprint=''
signing_certificate_fingerprint=''
signing_team_id=''
tool_path_value=''
tool_device_value=''
tool_inode_value=''
tool_mode_value=''
tool_digest_value=''
tool_build_identity_value=''
observation_provider_path_value=''
observation_provider_device_value=''
observation_provider_inode_value=''
observation_provider_digest_value=''
trusted_observation_provider_path_value=''
trusted_observation_provider_device_value=''
trusted_observation_provider_inode_value=''
trusted_observation_provider_digest_value=''
sleep_wake_provider_path_value=''
sleep_wake_provider_device_value=''
sleep_wake_provider_inode_value=''
sleep_wake_provider_digest_value=''
run_succeeded=0
root_lock_created=0
gate_lock_created=0
run_started_created=0
trap_armed=0
final_state_exposed=0
pass_publication_started=0
locks_released=0
sealed_manifest_tmp=''
sealed_digest_tmp=''
sealed_cms_tmp=''
qualification_child_pid=0
capture_status=0
capture_out_tmp=''
capture_err_tmp=''
script_invocation="${BASH_SOURCE[0]}"
script_absolute=''
repo_root=''

die() {
  printf '%s\n' "$1" >&2
  exit "${2:-70}"
}

testing() { [[ "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" == 1 ]]; }

now() { /bin/date -u '+%Y-%m-%dT%H:%M:%S.%3NZ'; }

sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
sha_executable() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

stream_sha() { /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'; }

tool_build_identity() {
  printf 'path=%s\nmode=%s\ndevice=%s\ninode=%s\ndigest=%s\nsourceCommit=%s\nsourceDigest=%s\nconfigDigest=%s\ntoolchainDigest=%s\n' \
    "$tool_path_value" "$tool_mode_value" "$tool_device_value" "$tool_inode_value" "$tool_digest_value" \
    "$source_commit" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" | stream_sha
}

formal_command_snapshot() {
  printf 'PATH=%s\n' "$formal_path"
  local command
  for command in \
    /bin/bash /bin/cat /bin/chmod /bin/date /bin/kill /bin/mkdir /bin/realpath /bin/rmdir /bin/sleep /bin/unlink \
    /usr/bin/awk /usr/bin/basename /usr/bin/cmp /usr/bin/codesign /usr/bin/dirname /usr/bin/find /usr/bin/git \
    /usr/bin/head /usr/bin/id /usr/bin/jq /usr/bin/openssl /usr/bin/perl /usr/bin/python3 /usr/bin/readlink \
    /usr/bin/security /usr/bin/sed /usr/bin/shasum /usr/bin/sort /usr/bin/stat /usr/bin/swift /usr/bin/sw_vers \
    /usr/bin/tail /usr/bin/tr /usr/bin/wc /usr/bin/xcodebuild /usr/bin/xcrun /usr/bin/uniq /usr/sbin/sysctl \
    /usr/local/bin/container; do
    [[ -x "$command" ]] || die "Gate 15 formal command is unavailable: $command" 69
    printf 'COMMAND=%s\tSHA256=%s\n' "$command" "$(sha "$command")"
  done
}

arm_traps() {
  trap on_exit EXIT
  trap 'on_signal INT 130' INT
  trap 'on_signal TERM 143' TERM
  trap 'on_signal HUP 129' HUP
  trap_armed=1
}

disarm_traps() {
  trap - INT TERM HUP EXIT
  trap_armed=0
}

terminate_and_wait_qualification_child() {
  local pid="$qualification_child_pid"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
  local attempt=0
  while [[ "$attempt" -lt 120 ]]; do
    /bin/kill -0 "$pid" >/dev/null 2>&1 || break
    /bin/sleep .05
    attempt=$((attempt + 1))
  done
  /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  qualification_child_pid=0
}

assert_absent() { [[ ! -e "$1" && ! -L "$1" ]]; }

private_file() {
  local path="$1"
  [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\t'* && -f "$path" && ! -L "$path" && "$(/bin/realpath "$path")" == "$path" \
    && "$(/usr/bin/stat -f '%u' "$path")" == "$user_id" && "$(/usr/bin/stat -f '%Lp' "$path")" == 600 \
    && "$(/usr/bin/stat -f '%l' "$path")" == 1 ]]
}

private_directory() {
  local path="$1"
  [[ "$path" == /* && -d "$path" && ! -L "$path" && "$(/bin/realpath "$path")" == "$path" \
    && "$(/usr/bin/stat -f '%u' "$path")" == "$user_id" && "$(/usr/bin/stat -f '%Lp' "$path")" == 700 ]]
}

make_private_temp() {
  local prefix="$1" path
  path="$(/usr/bin/python3 -c '
import os, secrets, sys
root, prefix = sys.argv[1:]
for _ in range(64):
    path = os.path.join(root, ".gate15-" + prefix + "." + secrets.token_hex(12))
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        continue
    os.close(descriptor)
    print(path)
    raise SystemExit(0)
raise SystemExit(73)
' "$root" "$prefix")" || die 'Gate 15 could not create an exclusive root-local temporary.' 73
  private_file "$path" || die 'Gate 15 temporary failed private identity validation.' 73
  printf '%s\n' "$path"
}

write_private_temp_from_stdin() {
  local prefix="$1"
  local directory="${2:-$root}"
  private_directory "$directory" || die 'Gate 15 publication destination directory is not private and canonical.' 124
  /usr/bin/python3 -c '
import os, secrets, sys
root, prefix = sys.argv[1:]
for _ in range(64):
    path = os.path.join(root, ".gate15-" + prefix + "." + secrets.token_hex(12))
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        continue
    try:
        while True:
            chunk = sys.stdin.buffer.read(65536)
            if not chunk:
                break
            view = memoryview(chunk)
            while view:
                written = os.write(descriptor, view)
                view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    print(path)
    raise SystemExit(0)
raise SystemExit(73)
' "$directory" "$prefix"
}

make_private_temp_directory() {
  local prefix="$1"
  local path
  path="$(/usr/bin/python3 -c '
import os, secrets, sys
root, prefix = sys.argv[1:]
for _ in range(64):
    path = os.path.join(root, ".gate15-dir-" + prefix + "." + secrets.token_hex(12))
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        continue
    print(path)
    raise SystemExit(0)
raise SystemExit(73)
' "$root" "$prefix")" || die 'Gate 15 private temporary directory could not be created.' 73
  private_directory "$path" || die 'Gate 15 private temporary directory failed identity validation.' 73
  printf '%s\n' "$path"
}

write_private() {
  local destination="$1" label="$2" prefix="$3" temporary destination_directory
  destination_directory="$(/usr/bin/dirname "$destination")"
  temporary="$(write_private_temp_from_stdin "$prefix" "$destination_directory")" || die "$label could not be written by the exclusive private writer." 124
  private_file "$temporary" || die "$label temporary failed private identity validation." 73
  publish_temp_absent "$temporary" "$destination" "$label"
}

atomic_rename_exclusive() {
  local temporary="$1" destination="$2"
  /usr/bin/python3 - "$temporary" "$destination" <<'PY'
import ctypes
import os
import sys

source, destination = sys.argv[1:]
libc = ctypes.CDLL(None, use_errno=True)
renameatx_np = getattr(libc, "renameatx_np", None)
if renameatx_np is None:
    raise SystemExit(1)
renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameatx_np.restype = ctypes.c_int
if renameatx_np(-2, source.encode(), -2, destination.encode(), 0x00000004) != 0:
    raise SystemExit(ctypes.get_errno() or 1)
PY
}

atomic_rename_replace() {
  local temporary="$1" destination="$2"
  /usr/bin/python3 - "$temporary" "$destination" <<'PY'
import os
import sys

source, destination = sys.argv[1:]
os.rename(source, destination)
PY
}

publish_temp_absent() {
  local temporary="$1" destination="$2" label="$3" temporary_device temporary_inode temporary_nlink destination_directory
  private_file "$temporary" || die "$label temporary failed private identity validation." 124
  destination_directory="$(/usr/bin/dirname "$destination")"
  [[ "$(/usr/bin/dirname "$temporary")" == "$destination_directory" ]] || die "$label temporary is not inside the destination directory." 124
  private_directory "$destination_directory" || die "$label destination directory failed private identity validation." 124
  temporary_device="$(/usr/bin/stat -f '%d' "$temporary")"
  temporary_inode="$(/usr/bin/stat -f '%i' "$temporary")"
  temporary_nlink="$(/usr/bin/stat -f '%l' "$temporary")"
  [[ "$temporary_nlink" == 1 ]] || die "$label temporary has more than one hard link." 124
  assert_absent "$destination" || die "$label already exists or is a symlink." 124
  atomic_rename_exclusive "$temporary" "$destination" || die "$label could not be published with an exclusive same-directory atomic rename." 124
  private_file "$destination" || die "$label failed private publication validation." 124
  [[ "$(/usr/bin/stat -f '%d' "$destination")" == "$temporary_device" \
    && "$(/usr/bin/stat -f '%i' "$destination")" == "$temporary_inode" \
    && "$(/usr/bin/stat -f '%l' "$destination")" == 1 ]] || die "$label changed device, inode, or nlink during publication." 124
}

replace_private() {
  local destination="$1" label="$2" prefix="$3" temporary destination_directory temporary_device temporary_inode
  destination_directory="$(/usr/bin/dirname "$destination")"
  temporary="$(write_private_temp_from_stdin "$prefix" "$destination_directory")" || die "$label could not be written by the exclusive private writer." 124
  private_file "$temporary" || die "$label temporary failed private identity validation." 73
  temporary_device="$(/usr/bin/stat -f '%d' "$temporary")"
  temporary_inode="$(/usr/bin/stat -f '%i' "$temporary")"
  [[ "$(/usr/bin/stat -f '%l' "$temporary")" == 1 ]] || die "$label temporary has more than one hard link." 124
  [[ ! -L "$destination" ]] || die "$label is a symlink; preserve the root." 124
  [[ "$(/usr/bin/dirname "$temporary")" == "$destination_directory" ]] || die "$label temporary is not inside the destination directory." 124
  private_directory "$destination_directory" || die "$label destination directory failed private identity validation." 124
  atomic_rename_replace "$temporary" "$destination" || die "$label could not be atomically replaced in its destination directory." 124
  private_file "$destination" || die "$label failed private replacement validation." 124
  [[ "$(/usr/bin/stat -f '%d' "$destination")" == "$temporary_device" \
    && "$(/usr/bin/stat -f '%i' "$destination")" == "$temporary_inode" \
    && "$(/usr/bin/stat -f '%l' "$destination")" == 1 ]] || die "$label changed device, inode, or nlink during replacement." 124
}

append_private_line() {
  local destination="$1" line="$2"
  private_file "$destination" || die 'Gate 15 append target is not a private regular file with one hard link.' 124
  /usr/bin/perl -MFcntl=O_WRONLY,O_APPEND,O_NOFOLLOW -e '
    my ($path, $line) = @ARGV;
    sysopen(my $handle, $path, O_WRONLY | O_APPEND | O_NOFOLLOW) or exit 1;
    print {$handle} $line or exit 1;
    close($handle) or exit 1;
  ' "$destination" "$line" || die 'Gate 15 append-only evidence write failed closed.' 124
  private_file "$destination" || die 'Gate 15 append target changed identity.' 124
}

validate_script_boundary() {
  local invocation canonical directory
  if [[ "$script_invocation" == /* ]]; then invocation="$script_invocation"; else invocation="$PWD/$script_invocation"; fi
  [[ -f "$invocation" && ! -L "$invocation" ]] || die 'Gate 15 qualification script invocation crosses a symlink boundary.' 66
  canonical="$(/bin/realpath "$invocation")" || die 'Gate 15 qualification script cannot be canonicalized.' 66
  directory="$(/usr/bin/dirname "$canonical")"
  [[ "$directory" == "$repository_path/scripts" && "$canonical" == "$repository_path/scripts/phase09-gate15-qualification.sh" \
    && ! -L "$directory" && "$(/bin/realpath "$directory")" == "$directory" ]] \
    || die 'Gate 15 qualification script must be the canonical Phase 09 repository script.' 66
  repo_root="$repository_path"
  script_absolute="$canonical"
  cd "$repo_root"
}

contract() {
  /bin/cat <<'EOF'
Phase 09 Gate 15 qualification harness contract v1
Gate 15 — 93.75% — one continuous 72-hour macOS qualification.
Commands: contract, diagnose, prepare 15, run 15, and status 15.
Exactly one immutable Gate 15 root may run. Formal evidence uses one same-process
runner, mach_continuous_time as duration authority, at least 259200 continuous
seconds, an initial sample plus 864
completed 300-second intervals, and canonical SHA-256 chained append-only samples.
Every sample binds runner and daemon process identities, boot-session identity,
signed executable identity, state-database integrity, runtime identity, bounded
metrics, scheduled fault, recovery result, and ordered sleep/wake coverage.
U/I/L/M/S/R cells run strictly serially. Dependencies are revalidated before and
after every cell and at every sample. Failure freezes the root and both locks;
failed roots are never rerun or repaired. Reuse requires exact checksum and CMS
verification. diagnose and status are read-only and non-qualifying. Test mode
cannot manufacture or claim a 72-hour passage. No elapsed-time resume exists.
EOF
}

diagnose() {
  /bin/cat <<'EOF'
{"claim":"none","gate":15,"status":"diagnostic","formal":false,"reason":"diagnose is read-only and non-qualifying","durationSeconds":259200,"intervalSeconds":300,"requiredIntervals":864,"sampleCount":865,"clock":"mach_continuous_time","evidenceClasses":["U","I","L","M","S","R"]}
EOF
}

qualification_parent() {
  if testing; then
    : "${HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT:?test parent required}"
    printf '%s\n' "$HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT"
  else
    printf '%s\n' "$live_parent"
  fi
}

validate_worktree() {
  validate_script_boundary
  testing && return 0
  [[ "$(/usr/bin/git -C "$repo_root" branch --show-current)" == "$branch" ]] || die "Gate 15 requires branch $branch." 66
  [[ "$(/bin/realpath "$(/usr/bin/git -C "$repo_root" rev-parse --show-toplevel)")" == "$repository_path" \
    && "$repository_path" != "$protected_repository_path" ]] \
    || die 'Gate 15 requires the isolated Phase 09 worktree.' 66
}

validate_parent() {
  parent="$(qualification_parent)"
  [[ "$parent" == /* && "$parent" != *$'\n'* && -d "$parent" && ! -L "$parent" ]] || die 'Gate 15 qualification parent is unavailable or symlinked.' 66
  [[ "$(/bin/realpath "$parent")" == "$parent" ]] || die 'Gate 15 qualification parent must be canonical.' 66
  [[ "$(/usr/bin/stat -f '%u' "$parent")" == "$user_id" && "$(/usr/bin/stat -f '%Lp' "$parent")" == 700 ]] \
    || die 'Gate 15 qualification parent must be current-user-owned and mode 0700.' 77
  if testing; then
    [[ "$parent" == /private/var/folders/*/T/hostwright-phase09-gate15-harness-* \
      || "$parent" == /var/folders/*/T/hostwright-phase09-gate15-harness-* ]] \
      || die 'test parent is outside the private harness boundary.' 66
  else
    [[ "$parent" == "$live_parent" ]] || die 'Gate 15 evidence must use the fixed qualification parent.' 66
  fi
}

validate_root() {
  : "${HOSTWRIGHT_PHASE09_GATE_ROOT:?HOSTWRIGHT_PHASE09_GATE_ROOT is required}"
  root="$HOSTWRIGHT_PHASE09_GATE_ROOT"
  validate_parent
  [[ "$root" == /* && "$root" != / && "$root" != */ && "$root" != *$'\n'* && ! -L "$root" && -d "$root" ]] \
    || die 'Gate 15 evidence root must be one existing absolute non-symlink directory.' 66
  [[ "$(/bin/realpath "$root")" == "$root" && "$(/usr/bin/dirname "$root")" == "$parent" \
    && "$(/bin/realpath "$(/usr/bin/dirname "$root")")" == "$parent" ]] \
    || die 'Gate 15 evidence root must be a direct child of the fixed qualification parent.' 66
  [[ "$(/usr/bin/basename "$root")" =~ $root_pattern ]] || die 'Gate 15 evidence root has an invalid canonical UUID name.' 66
  [[ "$(/usr/bin/stat -f '%u' "$root")" == "$user_id" && "$(/usr/bin/stat -f '%Lp' "$root")" == 700 ]] \
    || die 'Gate 15 evidence root must be current-user-owned and mode 0700.' 77
}

empty_root() {
  [[ -z "$(/usr/bin/find "$root" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || die 'Gate 15 evidence root must be empty before prepare.' 73
}

clean_source() {
  testing && return 0
  /usr/bin/git diff --quiet HEAD -- . ':(exclude)tmp/**' || die 'Gate 15 source must be clean and committed.' 73
  /usr/bin/git diff --cached --quiet -- . ':(exclude)tmp/**' || die 'Gate 15 source must be clean and committed.' 73
  local dirty
  dirty="$(/usr/bin/git status --porcelain=v1 --untracked-files=all | /usr/bin/awk '$0 !~ /^.. tmp\// {print}')"
  [[ -z "$dirty" ]] || die 'Gate 15 source must be clean and committed.' 73
}

source_digest() {
  {
    printf 'HEAD\t%s\n' "$(/usr/bin/git rev-parse HEAD)"
    /usr/bin/git diff --binary HEAD -- . ':(exclude)tmp/**'
    /usr/bin/git ls-files -s -- . ':(exclude)tmp/**'
    while IFS= read -r -d '' file; do
      [[ "$file" == tmp/* ]] && continue
      if [[ -L "$file" ]]; then
        printf 'untracked-symlink\t%s\t%s\n' "$(/usr/bin/readlink "$file")" "$file"
      elif [[ -f "$file" ]]; then
        printf 'untracked-file\t%s\t%s\t%s\n' "$(/usr/bin/stat -f '%Lp' "$file")" "$(sha "$file")" "$file"
      elif [[ -d "$file" ]]; then
        printf 'untracked-directory\t%s\t%s\n' "$(/usr/bin/stat -f '%Lp' "$file")" "$file"
      else
        printf 'untracked-other\t%s\n' "$file"
      fi
    done < <(/usr/bin/git ls-files --others --exclude-standard -z -- . ':(exclude)tmp/**')
    /usr/bin/git submodule status --recursive 2>/dev/null || true
  } | stream_sha
}

config_digest() {
  local file
  for file in \
    Package.swift Package.resolved \
    scripts/phase09-gate15-qualification.sh scripts/phase09-gate15-live.sh \
    Qualification/HostwrightPhase09QualificationTool/main.swift \
    Tests/HostwrightStateTests/Phase09Gate15QualificationHarnessTests.swift \
    Tests/HostwrightPhase09QualificationToolTests/HostwrightPhase09QualificationToolTests.swift; do
    [[ -f "$file" && ! -L "$file" ]] || die "Gate 15 configuration file is unavailable: $file" 69
    printf '%s  %s\n' "$(sha "$file")" "$file"
  done | stream_sha
}

toolchain_snapshot() {
  if testing; then
    /bin/cat <<'EOF'
qualification-toolchain=testing
clock=mach_continuous_time
duration-seconds=259200
interval-seconds=300
required-intervals=864
EOF
    return 0
  fi
  /usr/bin/swift --version
  /usr/bin/xcodebuild -version
  /usr/bin/sw_vers
  /usr/bin/xcrun --find codesign
  /usr/bin/xcrun --find spctl
  /usr/bin/xcrun --find notarytool
  printf 'clock=mach_continuous_time\nduration-seconds=%s\ninterval-seconds=%s\nrequired-intervals=%s\n' \
    "$duration_seconds" "$interval_seconds" "$required_intervals"
  formal_command_snapshot
}

toolchain_digest() { toolchain_snapshot | stream_sha; }

require_private_file() {
  local path="$1" label="$2"
  [[ "$path" == /* && "$path" != *$'\n'* && -f "$path" && ! -L "$path" ]] \
    || die "$label must be one absolute regular non-symlink file." 66
  private_file "$path" || die "$label must be canonical, current-user-owned, and mode 0600." 66
}

require_executable() {
  local path="$1" label="$2"
  [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\t'* && -f "$path" && ! -L "$path" \
    && "$(/bin/realpath "$path")" == "$path" && "$(/usr/bin/stat -f '%u' "$path")" == "$user_id" \
    && "$(/usr/bin/stat -f '%Lp' "$path")" == 755 && "$(/usr/bin/stat -f '%l' "$path")" == 1 \
    && -x "$path" ]] || die "$label must be one current-user-owned canonical mode-0755 executable with one hard link." 66
}

require_system_executable() {
  local path="$1" label="$2" owner
  owner="$(/usr/bin/stat -f '%u' "$path" 2>/dev/null || true)"
  [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\t'* && -f "$path" && ! -L "$path" \
    && "$(/bin/realpath "$path")" == "$path" && ("$owner" == 0 || "$owner" == "$user_id") \
    && "$(/usr/bin/stat -f '%l' "$path")" == 1 && -x "$path" ]] \
    || die "$label must be one canonical system executable with one hard link." 66
}

validate_checksum_manifest() {
  local bundle="$1" checksum="$2" entry name
  require_private_file "$checksum" 'Gate 15 checksum manifest'
  /usr/bin/awk '
    NF != 2 || $1 !~ /^[a-f0-9]{64}$/ || $2 ~ /^\// || $2 ~ /(^|\/)\.\.($|\/)/ ||
    $2 ~ /[*?[]/ || seen[$2]++ { bad=1 }
    END { exit bad ? 1 : 0 }
  ' "$checksum" || die 'Gate 15 checksum manifest contains an invalid, duplicate, or shadow path.' 69
  (cd "$bundle" && /usr/bin/shasum -a 256 -c "$(/usr/bin/basename "$checksum")" >/dev/null) \
    || die 'Gate 15 checksum manifest verification failed.' 69
  /usr/bin/awk '{print $2}' "$checksum" | while IFS= read -r name; do
    [[ -n "$name" && -f "$bundle/$name" && ! -L "$bundle/$name" ]] \
      || die 'Gate 15 checksum manifest references a missing or symlinked artifact.' 69
    require_private_file "$bundle/$name" 'Gate 15 checksummed artifact'
  done
  entry=manifest-v1.json
  /usr/bin/awk -v expected="$entry" 'NF == 2 && $2 == expected {found=1} END {exit found ? 0 : 1}' "$checksum" \
    || die 'Gate 15 checksum manifest does not bind manifest-v1.json.' 69
}

require_checksum_entry() {
  local checksum="$1" name="$2"
  /usr/bin/awk -v expected="$name" 'NF == 2 && $2 == expected {found=1} END {exit found ? 0 : 1}' "$checksum" \
    || die "Gate 15 checksum inventory does not bind $name." 69
}

verify_actual_cms_signer() {
  local cms="$1" decoded="$2" signer_cert="$3" actual_fingerprint actual_subject actual_common_name actual_team
  /usr/bin/openssl cms -verify -inform DER -binary -noverify -in "$cms" \
    -signer "$signer_cert" -out "$decoded" >/dev/null 2>&1 \
    || die 'Gate 15 CMS signature could not yield its actually verified signer certificate.' 69
  /bin/chmod 600 "$signer_cert" "$decoded"
  require_private_file "$signer_cert" 'Gate 15 extracted CMS signer certificate'
  actual_fingerprint="$(/usr/bin/openssl x509 -in "$signer_cert" -noout -fingerprint -sha1 \
    | /usr/bin/awk -F= '{gsub(":", "", $2); print tolower($2)}')"
  actual_subject="$(/usr/bin/openssl x509 -in "$signer_cert" -noout -subject -nameopt RFC2253)"
  actual_common_name="$(printf '%s\n' "$actual_subject" | /usr/bin/sed -n 's/^subject=.*CN=\\([^,]*\\).*/\\1/p')"
  actual_team="$(printf '%s\n' "$actual_subject" | /usr/bin/sed -n 's/^subject=.*OU=\\([^,]*\\).*/\\1/p')"
  [[ "$actual_fingerprint" == "$expected_certificate_fingerprint" \
    && "$actual_team" == "$expected_signing_team" \
    && "$actual_common_name ($actual_team)" == "$expected_signing_identity" ]] \
    || die 'Gate 15 CMS signer certificate identity, Team ID, or fingerprint is not the exact pinned signer.' 69
}

verify_cms_bundle() {
  local bundle="$1" checksum="$2" cms="$3" decoded signer_cert openssl_decoded output_directory
  require_private_file "$cms" 'Gate 15 CMS evidence'
  if ! /usr/bin/security cms -V -N "$expected_signing_identity" -u 9 -i "$cms" >/dev/null 2>&1; then
    die 'Gate 15 CMS signature failed verification under the pinned identity.' 69
  fi
  decoded="$(/usr/bin/security cms -D -N "$expected_signing_identity" -u 9 -i "$cms" -o /dev/stdout 2>/dev/null | write_private_temp_from_stdin cms-decoded)" \
    || die 'Gate 15 CMS payload could not be decoded under the pinned identity.' 69
  private_file "$decoded" || die 'Gate 15 CMS decode lost private-file identity.' 69
  output_directory="$(make_private_temp_directory cms-openssl)" || die 'Gate 15 CMS verification directory could not be created.' 69
  signer_cert="$output_directory/signer.der"
  openssl_decoded="$output_directory/payload.bin"
  verify_actual_cms_signer "$cms" "$openssl_decoded" "$signer_cert"
  /bin/unlink "$openssl_decoded"
  /bin/unlink "$signer_cert"
  /bin/rmdir "$output_directory"
  if ! /usr/bin/cmp -s "$checksum" "$decoded"; then
    /bin/unlink "$decoded"
    die 'Gate 15 CMS payload did not round-trip to the exact checksum manifest.' 69
  fi
  /bin/unlink "$decoded"
}

validate_gate11_notarization() {
  local gate11_root="$1" checksum="$2" manifest="$gate11_root/manifest-v1.json"
  local notary="$gate11_root/notarization-receipt-v1.json" stapled="$gate11_root/stapled-receipt-v1.json"
  require_private_file "$notary" 'Gate 11 notarization receipt'
  require_private_file "$stapled" 'Gate 11 stapled receipt'
  require_checksum_entry "$checksum" 'notarization-receipt-v1.json'
  require_checksum_entry "$checksum" 'stapled-receipt-v1.json'
  require_private_file "$manifest" 'Gate 11 manifest for notarization binding'
  local manifest_digest manifest_commit manifest_source notary_artifact notary_digest stapled_artifact stapled_digest notarization_digest
  manifest_digest="$(sha "$manifest")"
  manifest_commit="$(/usr/bin/jq -r '.sourceCommit // empty' "$manifest")"
  manifest_source="$(/usr/bin/jq -r '.sourceDigest // empty' "$manifest")"
  notary_artifact="$(/usr/bin/jq -r '.artifactPath // empty' "$notary")"
  notary_digest="$(/usr/bin/jq -r '.artifactSHA256 // empty' "$notary")"
  stapled_artifact="$(/usr/bin/jq -r '.artifactPath // empty' "$stapled")"
  stapled_digest="$(/usr/bin/jq -r '.artifactSHA256 // empty' "$stapled")"
  notarization_digest="$(/usr/bin/jq -r '.notarizationReceiptSHA256 // empty' "$stapled")"
  [[ "$manifest_commit" =~ ^[a-f0-9]{40}$ && "$manifest_source" =~ ^[a-f0-9]{64}$ \
    && "$notary_artifact" == "$stapled_artifact" && "$notary_digest" == "$stapled_digest" \
    && "$notarization_digest" == "$(sha "$notary")" ]] \
    || die 'Gate 11 notarization and stapled receipts are not cross-bound to the exact artifact.' 69
  /usr/bin/jq -e --arg identity "$expected_signing_identity" --arg fingerprint "$expected_signing_fingerprint" \
    --arg certificate "$expected_certificate_fingerprint" --arg team "$expected_signing_team" \
    --arg manifestDigest "$manifest_digest" --arg sourceCommit "$manifest_commit" --arg sourceDigest "$manifest_source" \
    --arg artifactPath "$notary_artifact" '
      (.schema == "hostwright.phase09.gate11.notarization-receipt.v1" and .status == "accepted"
       and (.submissionID | type == "string" and test("^[A-Za-z0-9._:-]{1,256}$"))
       and (.artifactSHA256 | type == "string" and test("^[a-f0-9]{64}$"))
       and .artifactPath == $artifactPath and .manifestDigest == $manifestDigest
       and .sourceCommit == $sourceCommit and .sourceDigest == $sourceDigest
       and .signingIdentity == $identity and .signingFingerprint == $fingerprint
       and .certificateFingerprint == $certificate and .teamID == $team)
    ' "$notary" >/dev/null || die 'Gate 11 notarization receipt is not bound to the pinned artifact, manifest, and signer.' 69
  local artifact artifact_digest
  artifact="$stapled_artifact"
  artifact_digest="$stapled_digest"
  [[ "$artifact" == "$gate11_root"/* && "$artifact" != *$'\n'* && "$artifact" != *$'\t'* ]] \
    || die 'Gate 11 stapled receipt names an unsafe or shadow artifact path.' 69
  require_private_file "$artifact" 'Gate 11 stapled artifact'
  [[ "$artifact_digest" =~ ^[a-f0-9]{64}$ && "$(sha "$artifact")" == "$artifact_digest" ]] \
    || die 'Gate 11 stapled artifact digest does not match its receipt.' 69
  /usr/bin/jq -e --arg identity "$expected_signing_identity" --arg fingerprint "$expected_signing_fingerprint" \
    --arg certificate "$expected_certificate_fingerprint" --arg team "$expected_signing_team" \
    --arg artifact "$artifact" --arg digest "$artifact_digest" --arg notarizationDigest "$(sha "$notary")" \
    --arg manifestDigest "$manifest_digest" --arg sourceCommit "$manifest_commit" --arg sourceDigest "$manifest_source" '
      (.schema == "hostwright.phase09.gate11.stapled-receipt.v1" and .stapled == true
       and .artifactPath == $artifact and .artifactSHA256 == $digest
       and .notarizationReceiptSHA256 == $notarizationDigest and .manifestDigest == $manifestDigest
       and .sourceCommit == $sourceCommit and .sourceDigest == $sourceDigest
       and .signingIdentity == $identity and .signingFingerprint == $fingerprint
       and .certificateFingerprint == $certificate and .teamID == $team)
    ' "$stapled" >/dev/null || die 'Gate 11 stapled receipt is not exact or signer-pinned.' 69
  /usr/bin/xcrun stapler validate "$artifact" >/dev/null 2>&1 \
    || die 'Gate 11 stapled receipt failed local stapler validation.' 69
}

validate_transitive_gate_root() {
  local entry="$1" number basename candidate manifest checksum cms expected_source signer_identity signer_fingerprint schema
  number="$(/usr/bin/jq -r '.gate' <<< "$entry")"
  basename="$(/usr/bin/jq -r '.rootBasename' <<< "$entry")"
  schema="hostwright.phase09.gate$(printf '%02d' "$number").qualification.manifest.v1"
  candidate="$(qualification_parent)/$basename"
  [[ "$number" =~ ^([1-9]|1[0-4])$ \
    && "$basename" =~ ^phase09-gate(0[1-9]|1[0-4])-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] \
    || die 'Gate 15 transitive dependency root namespace is invalid.' 69
  [[ "$(/usr/bin/dirname "$candidate")" == "$(qualification_parent)" && "$(/bin/realpath "$candidate")" == "$candidate" ]] \
    || die 'Gate 15 transitive dependency root escaped its fixed parent or uses a shadow path.' 69
  [[ -d "$candidate" && ! -L "$candidate" && "$(/usr/bin/stat -f '%u' "$candidate")" == "$user_id" \
    && "$(/usr/bin/stat -f '%Lp' "$candidate")" == 700 ]] || die 'Gate 15 transitive dependency root is not private.' 69
  manifest="$candidate/manifest-v1.json"; checksum="$candidate/evidence-v1.sha256"; cms="$candidate/evidence-v1.cms"
  require_private_file "$manifest" 'Gate 15 transitive manifest'
  require_private_file "$checksum" 'Gate 15 transitive checksum manifest'
  require_private_file "$cms" 'Gate 15 transitive CMS evidence'
  expected_source="$(/usr/bin/jq -r '.sourceCommit' <<< "$entry")"
  /usr/bin/jq -e --argjson number "$number" --arg schema "$schema" --arg expectedSource "$expected_source" '
      (.schema == $schema and .gate == $number and .status == "passed"
       and .sourceCommit == $expectedSource and (.sourceDigest | test("^[a-f0-9]{64}$"))
       and (.configDigest | test("^[a-f0-9]{64}$")) and (.toolchainDigest | test("^[a-f0-9]{64}$")))
    ' "$manifest" >/dev/null || die 'Gate 15 transitive manifest is not exact or formal.' 69
  signer_identity="$(/usr/bin/jq -r '.signingIdentity // .externalPrerequisites.cmsSigningIdentity // .externalPrerequisites.signingIdentity // empty' "$manifest")"
  signer_fingerprint="$(/usr/bin/jq -r '.signingFingerprint // .externalPrerequisites.cmsSigningFingerprint // empty' "$manifest")"
  [[ "$signer_identity" == "$expected_signing_identity" && "$signer_fingerprint" == "$expected_signing_fingerprint" ]] \
    || die 'Gate 15 transitive manifest signer is not pinned.' 69
  [[ "$(sha "$manifest")" == "$(/usr/bin/jq -r '.manifestDigest' <<< "$entry")" \
    && "$(sha "$checksum")" == "$(/usr/bin/jq -r '.checksumDigest' <<< "$entry")" \
    && "$(sha "$cms")" == "$(/usr/bin/jq -r '.cmsDigest' <<< "$entry")" ]] \
    || die 'Gate 15 transitive manifest/checksum/CMS digest binding failed.' 69
  validate_checksum_manifest "$candidate" "$checksum"
  verify_cms_bundle "$candidate" "$checksum" "$cms"
  [[ "$number" != 11 ]] || validate_gate11_notarization "$candidate" "$checksum"
}

validate_dependency_evidence() {
  local verify_only="${1:-0}"
  if testing; then
    dependency_digest_value="$(printf 'testing-gates-1-14\n' | stream_sha)"
    return 0
  fi
  local receipt="${HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE:-}" entry gate_count canonical_tmp
  require_private_file "$receipt" 'HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE'
  /usr/bin/jq -e --arg currentSource "$source_commit" '
    (.schema == "hostwright.phase09.gate15.dependencies.v1" and .status == "passed"
     and (.gates | type == "array" and length == 14)
     and ((.gates | map(.gate) | sort) == [1,2,3,4,5,6,7,8,9,10,11,12,13,14])
     and ((.gates | map(.gate) | unique | length) == 14)
     and all(.gates[]; .status == "passed" and (.rootBasename | type == "string")
       and .sourceCommit == $currentSource
       and (.manifestDigest | test("^[a-f0-9]{64}$"))
       and (.checksumDigest | test("^[a-f0-9]{64}$"))
       and (.cmsDigest | test("^[a-f0-9]{64}$"))))
  ' "$receipt" >/dev/null || die 'current Gate 1–14 dependency evidence is missing or structurally invalid.' 69
  if [[ "$verify_only" == 1 ]]; then
    require_private_file "$root/dependency-evidence-v1.json" 'prepared Gate 15 dependency evidence'
    /usr/bin/jq -cS . "$receipt" | /usr/bin/cmp -s - "$root/dependency-evidence-v1.json" \
      || die 'Gate 1–14 dependency evidence changed; status verification refuses to repair it.' 73
    dependency_digest_value="$(sha "$root/dependency-evidence-v1.json")"
    while IFS= read -r entry; do validate_transitive_gate_root "$entry"; done < <(/usr/bin/jq -c '.gates[]' "$receipt")
    gate_count="$(/usr/bin/jq -r '.gates | length' "$receipt")"
    [[ "$gate_count" == 14 ]] || die 'Gate 15 requires exactly fourteen transitive Gate 1–14 roots.' 69
    return 0
  fi
  canonical_tmp="$(/usr/bin/jq -cS . "$receipt" | write_private_temp_from_stdin dependency-input)" \
    || die 'canonical Gate 15 dependency input could not be written exclusively.' 124
  private_file "$canonical_tmp" || die 'canonical Gate 15 dependency input failed private validation.' 69
  if [[ -e "$root/dependency-evidence-v1.json" || -L "$root/dependency-evidence-v1.json" ]]; then
    require_private_file "$root/dependency-evidence-v1.json" 'prepared Gate 15 dependency evidence'
    [[ "$(sha "$root/dependency-evidence-v1.json")" == "$(sha "$canonical_tmp")" ]] \
      || die 'Gate 1–14 dependency evidence changed; preserve the root.' 73
    /bin/unlink "$canonical_tmp"
  else
    [[ "$verify_only" == 0 ]] || die 'Gate 15 status verification refuses to create dependency evidence.' 69
    publish_temp_absent "$canonical_tmp" "$root/dependency-evidence-v1.json" 'Gate 15 dependency evidence'
  fi
  dependency_digest_value="$(sha "$root/dependency-evidence-v1.json")"
  while IFS= read -r entry; do validate_transitive_gate_root "$entry"; done < <(/usr/bin/jq -c '.gates[]' "$receipt")
  gate_count="$(/usr/bin/jq -r '.gates | length' "$receipt")"
  [[ "$gate_count" == 14 ]] || die 'Gate 15 requires exactly fourteen transitive Gate 1–14 roots.' 69
}

validate_executable_pinset() {
  if testing; then
    pinset_digest_value="$(printf 'testing-executable-pinset\n' | stream_sha)"
    return 0
  fi
  local pinset="${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET:-}"
  require_private_file "$pinset" 'HOSTWRIGHT_GATE15_EXECUTABLE_PINSET'
  /usr/bin/jq -e '
    .schema == "hostwright.phase09.gate15.executable-pinset.v1" and
    (.executables | type == "array" and length > 0) and
    all(.executables[]; (.name | test("^[A-Za-z0-9._-]{1,128}$")) and
      (.sha256 | test("^[0-9a-f]{64}$")) and
      (.cdHash | test("^[0-9a-f]{40}([0-9a-f]{24})?$")) and
      (.teamID | test("^[A-Za-z0-9]{1,32}$")) and
      (.identifier | test("^[A-Za-z0-9._-]{1,128}$"))) and
    (.systemContainer.path == "/usr/local/bin/container") and
    (.systemContainer.sha256 | test("^[a-f0-9]{64}$")) and
    (.systemContainer.cdHash | test("^[a-f0-9]{40}([a-f0-9]{24})?$")) and
    (.systemContainer.teamID | test("^[A-Za-z0-9]{1,32}$")) and
    (.systemContainer.identifier | test("^[A-Za-z0-9._-]{1,128}$"))
  ' "$pinset" >/dev/null || die 'the signed executable pinset is missing or invalid.' 69
  pinset_path_value="$(/bin/realpath "$pinset")"
  pinset_device_value="$(/usr/bin/stat -f '%d' "$pinset")"
  pinset_inode_value="$(/usr/bin/stat -f '%i' "$pinset")"
  pinset_digest_value="$(sha "$pinset")"
}

validate_canonical_tool() {
  if testing; then
    tool_path_value="$canonical_tool_path"
    tool_device_value=0
    tool_inode_value=0
    tool_mode_value=493
    tool_digest_value='testing-qualification-tool'
    tool_build_identity_value='testing-qualification-tool-build'
    return 0
  fi
  [[ "${HOSTWRIGHT_GATE15_TOOL:-}" == "$canonical_tool_path" ]] \
    || die 'Gate 15 formal execution may use only the canonical built HostwrightPhase09QualificationTool artifact.' 69
  require_executable "$canonical_tool_path" 'HostwrightPhase09QualificationTool artifact'
  [[ "$(/bin/realpath "$canonical_tool_path")" == "$canonical_tool_path" \
    && "$(/usr/bin/stat -f '%Lp' "$canonical_tool_path")" == 755 ]] \
    || die 'HostwrightPhase09QualificationTool artifact must be canonical and mode 0755.' 69
  tool_path_value="$canonical_tool_path"
  tool_device_value="$(/usr/bin/stat -f '%d' "$canonical_tool_path")"
  tool_inode_value="$(/usr/bin/stat -f '%i' "$canonical_tool_path")"
  local tool_mode_octal
  tool_mode_octal="$(/usr/bin/stat -f '%Lp' "$canonical_tool_path")"
  [[ "$tool_mode_octal" == 755 ]] || die 'HostwrightPhase09QualificationTool artifact must be mode 0755.' 69
  tool_mode_value="$((8#$tool_mode_octal))"
  tool_digest_value="$(sha_executable "$canonical_tool_path")"
  tool_build_identity_value="$(tool_build_identity)"
}

validate_observation_inputs() {
  local provider trusted sleep_provider path provider_identity trusted_identity sleep_identity
  provider="${HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER:-}"
  trusted="${HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER:-}"
  sleep_provider="${HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER:-}"
  for path in "$provider" "$trusted" "$sleep_provider"; do
    require_executable "$path" 'Gate 15 independent observation executable'
  done
  observation_provider_path_value="$(/bin/realpath "$provider")"
  observation_provider_device_value="$(/usr/bin/stat -f '%d' "$provider")"
  observation_provider_inode_value="$(/usr/bin/stat -f '%i' "$provider")"
  observation_provider_digest_value="$(sha_executable "$provider")"
  trusted_observation_provider_path_value="$(/bin/realpath "$trusted")"
  trusted_observation_provider_device_value="$(/usr/bin/stat -f '%d' "$trusted")"
  trusted_observation_provider_inode_value="$(/usr/bin/stat -f '%i' "$trusted")"
  trusted_observation_provider_digest_value="$(sha_executable "$trusted")"
  sleep_wake_provider_path_value="$(/bin/realpath "$sleep_provider")"
  sleep_wake_provider_device_value="$(/usr/bin/stat -f '%d' "$sleep_provider")"
  sleep_wake_provider_inode_value="$(/usr/bin/stat -f '%i' "$sleep_provider")"
  sleep_wake_provider_digest_value="$(sha_executable "$sleep_provider")"
  provider_identity="$observation_provider_device_value:$observation_provider_inode_value:$observation_provider_digest_value"
  trusted_identity="$trusted_observation_provider_device_value:$trusted_observation_provider_inode_value:$trusted_observation_provider_digest_value"
  sleep_identity="$sleep_wake_provider_device_value:$sleep_wake_provider_inode_value:$sleep_wake_provider_digest_value"
  [[ "$observation_provider_path_value" != "$trusted_observation_provider_path_value" \
    && "$observation_provider_path_value" != "$sleep_wake_provider_path_value" \
    && "$trusted_observation_provider_path_value" != "$sleep_wake_provider_path_value" \
    && "$observation_provider_path_value" != "$canonical_tool_path" \
    && "$trusted_observation_provider_path_value" != "$canonical_tool_path" \
    && "$sleep_wake_provider_path_value" != "$canonical_tool_path" \
    && "$provider_identity" != "$trusted_identity" \
    && "$provider_identity" != "$sleep_identity" \
    && "$trusted_identity" != "$sleep_identity" ]] \
    || die 'Gate 15 provider, observer, and OS sleep receipt identities must be separately pinned and distinct from the tool.' 69
}

validate_canonical_validator_inputs() {
  local dependency_validator="${HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR:-$canonical_dependency_validator_path}"
  local boundary_validator="${HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR:-$canonical_boundary_validator_path}"
  [[ "$dependency_validator" == "$canonical_dependency_validator_path" ]] \
    || die 'Gate 15 formal runs may use only the canonical Gate 15 revalidate-sample harness.' 69
  [[ "$boundary_validator" == "$canonical_boundary_validator_path" ]] \
    || die 'Gate 15 formal runs may use only the canonical live boundary script.' 69
  require_executable "$dependency_validator" 'Gate 15 dependency validator'
  require_executable "$boundary_validator" 'Gate 15 live boundary validator'
  [[ "$(/bin/realpath "$dependency_validator")" == "$canonical_dependency_validator_path" \
    && "$(/bin/realpath "$boundary_validator")" == "$canonical_boundary_validator_path" ]] \
    || die 'Gate 15 validator paths must resolve to the canonical Phase 09 repository.' 69
  dependency_validator_device_value="$(/usr/bin/stat -f '%d' "$dependency_validator")"
  dependency_validator_inode_value="$(/usr/bin/stat -f '%i' "$dependency_validator")"
  dependency_validator_digest_value="$(sha_executable "$dependency_validator")"
  boundary_validator_device_value="$(/usr/bin/stat -f '%d' "$boundary_validator")"
  boundary_validator_inode_value="$(/usr/bin/stat -f '%i' "$boundary_validator")"
  boundary_validator_digest_value="$(sha_executable "$boundary_validator")"
}

validate_notary_and_signing() {
  local verify_only="${1:-0}"
  if testing; then
    signing_identity="$test_signing_identity"
    signing_fingerprint="$test_signing_fingerprint"
    signing_certificate_fingerprint="$test_certificate_fingerprint"
    signing_team_id="$test_signing_team"
    validate_executable_pinset
    return 0
  fi
  [[ -n "${HOSTWRIGHT_NOTARY_PROFILE:-}" ]] || die 'HOSTWRIGHT_NOTARY_PROFILE is required for Gate 15 notarized evidence.' 69
  signing_identity="${HOSTWRIGHT_GATE15_SIGNING_IDENTITY:-}"
  signing_fingerprint="${HOSTWRIGHT_GATE15_SIGNING_FINGERPRINT:-}"
  signing_certificate_fingerprint="${HOSTWRIGHT_GATE15_CERTIFICATE_FINGERPRINT:-}"
  signing_team_id="${HOSTWRIGHT_GATE15_TEAM_ID:-}"
  [[ "$signing_identity" == "$expected_signing_identity" ]] \
    || die 'the exact pinned Developer ID Application identity is required.' 69
  [[ "$signing_fingerprint" == "$expected_signing_fingerprint" \
    && "$signing_certificate_fingerprint" == "$expected_certificate_fingerprint" ]] \
    || die 'the exact pinned Developer ID fingerprint is required.' 69
  [[ "$signing_team_id" == "$expected_signing_team" ]] \
    || die 'the exact pinned Team ID is required.' 69
  local path entry details cdhash team identifier digest ledger_existing=0
  : "${HOSTWRIGHT_GATE15_SIGNED_EXECUTABLES:?HOSTWRIGHT_GATE15_SIGNED_EXECUTABLES is required}"
  IFS=':' read -r -a entries <<< "$HOSTWRIGHT_GATE15_SIGNED_EXECUTABLES"
  ((${#entries[@]} > 0)) || die 'at least one signed qualification executable is required.' 69
  validate_executable_pinset
  if assert_absent "$root/signed-executables-v1.tsv"; then
    [[ "$verify_only" == 0 ]] || die 'Gate 15 status verification refuses to create the signed executable ledger.' 69
    printf '%s\n' $'path\tsha256\tcdhash\tteamID\tidentifier' \
      | write_private "$root/signed-executables-v1.tsv" 'signed executable ledger' signed
  else
    ledger_existing=1
    require_private_file "$root/signed-executables-v1.tsv" 'signed executable ledger'
    [[ "$(/usr/bin/head -n 1 "$root/signed-executables-v1.tsv")" == $'path\tsha256\tcdhash\tteamID\tidentifier' ]] \
      || die 'signed executable ledger header is invalid.' 69
    [[ "$(/usr/bin/wc -l < "$root/signed-executables-v1.tsv" | /usr/bin/tr -d ' ')" == "$(( ${#entries[@]} + 1 ))" ]] \
      || die 'signed executable ledger has an unexpected entry count.' 69
  fi
  local pinset_count
  pinset_count="$(/usr/bin/jq -r '.executables | length' "$HOSTWRIGHT_GATE15_EXECUTABLE_PINSET")"
  [[ "$pinset_count" == "${#entries[@]}" ]] || die 'the signed executable list and pinset entry count differ.' 69
  for path in "${entries[@]}"; do
    require_executable "$path" 'signed qualification executable'
    /usr/bin/codesign --verify --strict --verbose=2 "$path" >/dev/null 2>&1 \
      || die 'a pinned qualification executable failed codesign verification.' 69
    details="$(/usr/bin/codesign -dvv "$path" 2>&1)"
    cdhash="$(printf '%s\n' "$details" | /usr/bin/awk -F= '$1=="CDHash"{print tolower($2); exit}')"
    team="$(printf '%s\n' "$details" | /usr/bin/awk -F= '$1=="TeamIdentifier"{print $2; exit}')"
    identifier="$(printf '%s\n' "$details" | /usr/bin/awk -F= '$1=="Identifier"{print $2; exit}')"
    local expected_sha expected_cdhash expected_team expected_identifier
    expected_sha="$(/usr/bin/jq -r --arg name "${path##*/}" '.executables[] | select(.name == $name) | .sha256' "${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET:-}" 2>/dev/null || true)"
    expected_cdhash="$(/usr/bin/jq -r --arg name "${path##*/}" '.executables[] | select(.name == $name) | .cdHash' "${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET:-}" 2>/dev/null || true)"
    expected_team="$(/usr/bin/jq -r --arg name "${path##*/}" '.executables[] | select(.name == $name) | .teamID' "${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET:-}" 2>/dev/null || true)"
    expected_identifier="$(/usr/bin/jq -r --arg name "${path##*/}" '.executables[] | select(.name == $name) | .identifier' "${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET:-}" 2>/dev/null || true)"
    [[ -n "$expected_sha" && "$expected_cdhash" == "$cdhash" && "$expected_team" == "$team" \
      && "$expected_identifier" == "$identifier" && "$cdhash" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ && "$team" == "$signing_team_id" \
      && "$identifier" =~ ^[A-Za-z0-9._-]{1,128}$ ]] \
      || die 'a signed qualification executable does not match the pinned CDHash, Team ID, or identifier.' 69
    digest="$(sha_executable "$path")"
    [[ "$digest" == "$expected_sha" ]] || die 'a signed qualification executable digest changed from the pinset.' 69
    if [[ "$ledger_existing" == 0 ]]; then
      append_private_line "$root/signed-executables-v1.tsv" \
        "$(printf '%s\t%s\t%s\t%s\t%s\n' "${path##*/}" "$digest" "$cdhash" "$team" "$identifier")"
    else
      /usr/bin/awk -F $'\t' -v path="${path##*/}" -v digest="$digest" -v cdhash="$cdhash" \
        -v team="$team" -v identifier="$identifier" \
        'NR > 1 && $1 == path && $2 == digest && $3 == cdhash && $4 == team && $5 == identifier {found=1} END {exit found ? 0 : 1}' \
        "$root/signed-executables-v1.tsv" || die 'signed executable ledger changed from its pinned identity.' 69
    fi
  done
}

validate_live_boundary() {
  if testing; then return 0; fi
  local runtime_root provider
  runtime_root="${HOSTWRIGHT_GATE15_LIVE_RUNTIME_ROOT:-}"
  provider="${HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER:-}"
  require_executable "$provider" 'HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER'
  [[ -d "$runtime_root" && ! -L "$runtime_root" && "$(/bin/realpath "$runtime_root")" == "$runtime_root" ]] \
    || die 'the exclusive Gate 15 live runtime root is unavailable or unsafe.' 69
  [[ "$(/usr/bin/stat -f '%u' "$runtime_root")" == "$user_id" && "$(/usr/bin/stat -f '%Lp' "$runtime_root")" == 700 ]] \
    || die 'the exclusive Gate 15 live runtime root must be private.' 69
  validate_canonical_validator_inputs
  validate_canonical_tool
  validate_observation_inputs
  [[ -n "$pinset_path_value" && -n "$pinset_device_value" && -n "$pinset_inode_value" ]] \
    || die 'Gate 15 executable pinset identity was not collected before live launch.' 69
  export HOSTWRIGHT_GATE15_ROOT="$root"
  export HOSTWRIGHT_GATE15_SOURCE_COMMIT="$source_commit"
  export HOSTWRIGHT_GATE15_SOURCE_DIGEST="$source_digest_value"
  export HOSTWRIGHT_GATE15_CONFIG_DIGEST="$config_digest_value"
  export HOSTWRIGHT_GATE15_TOOLCHAIN_DIGEST="$toolchain_digest_value"
  export HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE_DIGEST="$dependency_digest_value"
  export HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST="$pinset_digest_value"
  export HOSTWRIGHT_GATE15_MANIFEST_DIGEST="$(sha "$root/manifest-v1.json")"
  export HOSTWRIGHT_GATE15_SIGNING_IDENTITY="$signing_identity"
  export HOSTWRIGHT_GATE15_SIGNING_FINGERPRINT="$signing_fingerprint"
  export HOSTWRIGHT_GATE15_CERTIFICATE_FINGERPRINT="$signing_certificate_fingerprint"
  export HOSTWRIGHT_GATE15_TEAM_ID="$signing_team_id"
  export HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR="$canonical_dependency_validator_path"
  export HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR_DIGEST="$dependency_validator_digest_value"
  export HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR_DEVICE="$dependency_validator_device_value"
  export HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR_INODE="$dependency_validator_inode_value"
  export HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR="$canonical_boundary_validator_path"
  export HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR_DIGEST="$boundary_validator_digest_value"
  export HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR_DEVICE="$boundary_validator_device_value"
  export HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR_INODE="$boundary_validator_inode_value"
  export HOSTWRIGHT_GATE15_EXECUTABLE_PINSET="$pinset_path_value"
  export HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DEVICE="$pinset_device_value"
  export HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_INODE="$pinset_inode_value"
  export HOSTWRIGHT_GATE15_TOOL="$canonical_tool_path"
  export HOSTWRIGHT_GATE15_TOOL_DEVICE="$tool_device_value"
  export HOSTWRIGHT_GATE15_TOOL_INODE="$tool_inode_value"
  export HOSTWRIGHT_GATE15_TOOL_MODE="$tool_mode_value"
  export HOSTWRIGHT_GATE15_TOOL_DIGEST="$tool_digest_value"
  export HOSTWRIGHT_GATE15_TOOL_BUILD_IDENTITY="$tool_build_identity_value"
  export HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER="$observation_provider_path_value"
  export HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER_DEVICE="$observation_provider_device_value"
  export HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER_INODE="$observation_provider_inode_value"
  export HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER_DIGEST="$observation_provider_digest_value"
  export HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER="$trusted_observation_provider_path_value"
  export HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER_DEVICE="$trusted_observation_provider_device_value"
  export HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER_INODE="$trusted_observation_provider_inode_value"
  export HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER_DIGEST="$trusted_observation_provider_digest_value"
  export HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER="$sleep_wake_provider_path_value"
  export HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER_DEVICE="$sleep_wake_provider_device_value"
  export HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER_INODE="$sleep_wake_provider_inode_value"
  export HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER_DIGEST="$sleep_wake_provider_digest_value"
  HOSTWRIGHT_GATE15_ROOT="$root" "$repository_path/scripts/phase09-gate15-live.sh" preflight --root "$root" >/dev/null
}

collect() {
  local verify_only="${1:-0}"
  clean_source
  source_commit="$(/usr/bin/git rev-parse HEAD)"
  source_digest_value="$(source_digest)"
  config_digest_value="$(config_digest)"
  validate_dependency_evidence "$verify_only"
  validate_notary_and_signing "$verify_only"
  toolchain_digest_value="$(toolchain_digest)"
  validate_canonical_tool
  if testing; then
    observation_provider_path_value='testing-observation-provider'
    observation_provider_device_value=0
    observation_provider_inode_value=0
    observation_provider_digest_value='testing-observation-provider'
    trusted_observation_provider_path_value='testing-trusted-observation-provider'
    trusted_observation_provider_device_value=0
    trusted_observation_provider_inode_value=0
    trusted_observation_provider_digest_value='testing-trusted-observation-provider'
    sleep_wake_provider_path_value='testing-sleep-wake-provider'
    sleep_wake_provider_device_value=0
    sleep_wake_provider_inode_value=0
    sleep_wake_provider_digest_value='testing-sleep-wake-provider'
  fi
}

prepare_manifest() {
  toolchain_snapshot | write_private "$root/toolchain-v1.txt" 'Gate 15 toolchain snapshot' toolchain
  printf '%s\n' "$ownership_header" | write_private "$root/ownership-v1.tsv" 'Gate 15 ownership ledger' ownership
  printf '%s\n' "$state_header" | write_private "$root/state-v1.tsv" 'Gate 15 state ledger' state
  if testing; then
    printf '%s\n' '{"schema":"hostwright.phase09.gate15.dependencies.v1","status":"testing","testOnly":true,"gates":[]}' \
      | write_private "$root/dependency-evidence-v1.json" 'Gate 15 test dependency fixture' dependency
    printf '%s\n' $'path\tsha256\tcdhash\tteamID\tidentifier\ntesting\ttesting\ttesting\ttesting\ttesting' \
      | write_private "$root/signed-executables-v1.tsv" 'Gate 15 test executable fixture' signed
  fi
  local test_value=false
  testing && test_value=true
  /usr/bin/jq -n \
    --arg schema "$manifest_schema" --arg commit "$source_commit" \
    --arg source "$source_digest_value" --arg config "$config_digest_value" \
    --arg toolchain "$toolchain_digest_value" --arg dependency "$dependency_digest_value" \
    --arg pinset "$pinset_digest_value" \
    --arg toolPath "$tool_path_value" --argjson toolDevice "$tool_device_value" --argjson toolInode "$tool_inode_value" \
    --argjson toolMode "$tool_mode_value" --arg toolDigest "$tool_digest_value" --arg toolBuildIdentity "$tool_build_identity_value" \
    --arg invocation "run --root $root" \
    --arg observationProviderPath "$observation_provider_path_value" --arg observationProviderDigest "$observation_provider_digest_value" \
    --arg trustedObservationProviderPath "$trusted_observation_provider_path_value" --arg trustedObservationProviderDigest "$trusted_observation_provider_digest_value" \
    --arg sleepWakeProviderPath "$sleep_wake_provider_path_value" --arg sleepWakeProviderDigest "$sleep_wake_provider_digest_value" \
    --arg signingIdentity "$signing_identity" --arg signingFingerprint "$signing_fingerprint" \
    --arg certificateFingerprint "$signing_certificate_fingerprint" --arg teamID "$signing_team_id" \
    --argjson testOnly "$test_value" \
    '{schema:$schema,gate:15,status:"prepared",claim:"none",formal:false,preparedAt:(now|todate),completedAt:null,
      sourceCommit:$commit,sourceDigest:$source,configDigest:$config,toolchainDigest:$toolchain,
      dependencyEvidenceDigest:$dependency,executablePinsetDigest:$pinset,signingIdentity:$signingIdentity,signingFingerprint:$signingFingerprint,
      certificateFingerprint:$certificateFingerprint,teamID:$teamID,testOnly:$testOnly,
      toolPath:$toolPath,toolDevice:$toolDevice,toolInode:$toolInode,toolMode:$toolMode,toolDigest:$toolDigest,toolBuildIdentity:$toolBuildIdentity,
      invocation:$invocation,observationProviderPath:$observationProviderPath,observationProviderDigest:$observationProviderDigest,
      trustedObservationProviderPath:$trustedObservationProviderPath,trustedObservationProviderDigest:$trustedObservationProviderDigest,
      sleepWakeProviderPath:$sleepWakeProviderPath,sleepWakeProviderDigest:$sleepWakeProviderDigest,
      durationSeconds:259200,intervalSeconds:300,requiredIntervals:864,requiredSampleCount:865,
      clock:"mach_continuous_time",cellOrder:[1,2,3,4,5,6],evidenceClasses:["U","I","L","M","S","R"]}' \
    | write_private "$root/manifest-v1.json" 'Gate 15 manifest' manifest
}

prepared() {
  require_private_file "$root/manifest-v1.json" 'Gate 15 manifest'
  require_private_file "$root/dependency-evidence-v1.json" 'Gate 15 dependency evidence'
  require_private_file "$root/signed-executables-v1.tsv" 'Gate 15 signed executable ledger'
  require_private_file "$root/ownership-v1.tsv" 'Gate 15 ownership ledger'
  require_private_file "$root/state-v1.tsv" 'Gate 15 state ledger'
  [[ "$(/usr/bin/jq -r .schema "$root/manifest-v1.json")" == "$manifest_schema" ]] || die 'Gate 15 manifest schema mismatch.' 73
  local status
  status="$(/usr/bin/jq -r .status "$root/manifest-v1.json")"
  [[ "$status" == prepared || "$status" == passed ]] || die 'Gate 15 evidence is frozen after failure or completion.' 73
  [[ ! -f "$root/failure-v1.tsv" ]] || die 'Gate 15 failure evidence is immutable; do not rerun this root.' 73
  if [[ "$status" == passed ]]; then
    [[ -f "$root/evidence-v1.sha256" && -f "$root/evidence-v1.cms" ]] \
      || die 'completed evidence is incomplete or changed; preserve this root and do not rerun.' 73
  fi
  [[ "$(/usr/bin/jq -r .sourceDigest "$root/manifest-v1.json")" == "$source_digest_value" \
    && "$(/usr/bin/jq -r .configDigest "$root/manifest-v1.json")" == "$config_digest_value" \
    && "$(/usr/bin/jq -r .toolchainDigest "$root/manifest-v1.json")" == "$toolchain_digest_value" \
    && "$(/usr/bin/jq -r .dependencyEvidenceDigest "$root/manifest-v1.json")" == "$dependency_digest_value" \
    && "$(/usr/bin/jq -r .executablePinsetDigest "$root/manifest-v1.json")" == "$pinset_digest_value" \
    && "$(/usr/bin/jq -r .signingIdentity "$root/manifest-v1.json")" == "$signing_identity" \
    && "$(/usr/bin/jq -r .signingFingerprint "$root/manifest-v1.json")" == "$signing_fingerprint" \
    && "$(/usr/bin/jq -r .certificateFingerprint "$root/manifest-v1.json")" == "$signing_certificate_fingerprint" \
    && "$(/usr/bin/jq -r .teamID "$root/manifest-v1.json")" == "$signing_team_id" \
    && "$(/usr/bin/jq -r .toolPath "$root/manifest-v1.json")" == "$tool_path_value" \
    && "$(/usr/bin/jq -r .toolDigest "$root/manifest-v1.json")" == "$tool_digest_value" \
    && "$(/usr/bin/jq -r .toolBuildIdentity "$root/manifest-v1.json")" == "$tool_build_identity_value" ]] \
    || die 'prepared evidence dependencies changed; preserve this root.' 73
}

revalidate_dependencies() {
  local current_commit current_source current_config current_toolchain current_dependency current_pinset current_tool_digest current_tool_build expected_dependency expected_pinset expected_tool_digest expected_tool_build
  expected_dependency="$dependency_digest_value"
  expected_pinset="$pinset_digest_value"
  expected_tool_digest="$tool_digest_value"
  expected_tool_build="$tool_build_identity_value"
  clean_source
  current_commit="$(/usr/bin/git rev-parse HEAD)"
  current_source="$(source_digest)"
  current_config="$(config_digest)"
  current_toolchain="$(toolchain_digest)"
  validate_dependency_evidence
  validate_executable_pinset
  current_dependency="$dependency_digest_value"
  current_pinset="$pinset_digest_value"
  validate_canonical_tool
  current_tool_digest="$tool_digest_value"
  current_tool_build="$tool_build_identity_value"
  [[ "$current_commit" == "$source_commit" && "$current_source" == "$source_digest_value" && "$current_config" == "$config_digest_value" \
    && "$current_toolchain" == "$toolchain_digest_value" && "$current_dependency" == "$expected_dependency" \
    && "$current_pinset" == "$expected_pinset" && "$current_tool_digest" == "$expected_tool_digest" \
    && "$current_tool_build" == "$expected_tool_build" ]] \
    || die 'Gate 15 dependencies changed; progress is frozen and locks are preserved.' 73
}

revalidate_bound_inputs() {
  local expected_commit expected_source expected_config expected_toolchain expected_dependency expected_pinset
  local current_commit current_source current_config current_toolchain current_dependency current_pinset
  expected_commit="${HOSTWRIGHT_GATE15_SOURCE_COMMIT:-}"
  expected_source="${HOSTWRIGHT_GATE15_SOURCE_DIGEST:-}"
  expected_config="${HOSTWRIGHT_GATE15_CONFIG_DIGEST:-}"
  expected_toolchain="${HOSTWRIGHT_GATE15_TOOLCHAIN_DIGEST:-}"
  expected_dependency="${HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE_DIGEST:-}"
  expected_pinset="${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST:-}"
  [[ "$expected_commit" =~ ^[a-f0-9]{40}$ && "$expected_source" =~ ^[a-f0-9]{64}$ \
    && "$expected_config" =~ ^[a-f0-9]{64}$ && "$expected_toolchain" =~ ^[a-f0-9]{64}$ \
    && "$expected_dependency" =~ ^[a-f0-9]{64}$ && "$expected_pinset" =~ ^[a-f0-9]{64}$ ]] \
    || die 'Gate 15 revalidation requires complete authenticated digest bindings.' 73
  clean_source
  current_commit="$(/usr/bin/git rev-parse HEAD)"
  current_source="$(source_digest)"
  current_config="$(config_digest)"
  current_toolchain="$(toolchain_digest)"
  validate_dependency_evidence
  current_dependency="$dependency_digest_value"
  validate_executable_pinset
  current_pinset="$pinset_digest_value"
  [[ "$current_commit" == "$expected_commit" && "$current_source" == "$expected_source" \
    && "$current_config" == "$expected_config" && "$current_toolchain" == "$expected_toolchain" \
    && "$current_dependency" == "$expected_dependency" && "$current_pinset" == "$expected_pinset" ]] \
    || die 'Gate 15 immutable source, configuration, toolchain, transitive evidence, or pinset changed.' 73
  /usr/bin/jq -e --arg commit "$expected_commit" --arg source "$expected_source" --arg config "$expected_config" \
    --arg toolchain "$expected_toolchain" --arg dependency "$expected_dependency" --arg pinset "$expected_pinset" \
    '(.status == "prepared" and .sourceCommit == $commit and .sourceDigest == $source and .configDigest == $config
      and .toolchainDigest == $toolchain and .dependencyEvidenceDigest == $dependency and .executablePinsetDigest == $pinset)' \
    "$root/manifest-v1.json" >/dev/null || die 'Gate 15 manifest is stale for the authenticated revalidation binding.' 73
}

create_run_started() {
  local marker="$root/run-started-v1.json" lock="$parent/.phase09-gate15-active-v1"
  local root_device root_inode gate_device gate_inode validator_path validator_digest validator_device validator_inode
  local boundary_path boundary_digest boundary_device boundary_inode pinset_path pinset_digest pinset_device pinset_inode
  local gate_info_device gate_info_inode
  local tool_path tool_digest tool_device tool_inode tool_mode tool_build_identity
  local observation_path observation_digest observation_device observation_inode trusted_path trusted_digest trusted_device trusted_inode
  local sleep_path sleep_digest sleep_device sleep_inode
  assert_absent "$marker" || die 'Gate 15 run-started marker already exists; preserve and freeze the root.' 73
  private_directory "$root/active-run-v1" || die 'Gate 15 run-started marker requires the exact root lock.' 73
  private_directory "$lock" || die 'Gate 15 run-started marker requires the exact gate lock.' 73
  root_device="$(/usr/bin/stat -f '%d' "$root/active-run-v1")"; root_inode="$(/usr/bin/stat -f '%i' "$root/active-run-v1")"
  gate_device="$(/usr/bin/stat -f '%d' "$lock")"; gate_inode="$(/usr/bin/stat -f '%i' "$lock")"
  gate_info_device="$(/usr/bin/stat -f '%d' "$lock/info-v1.tsv")"; gate_info_inode="$(/usr/bin/stat -f '%i' "$lock/info-v1.tsv")"
  if testing; then
    validator_path="$canonical_dependency_validator_path"; validator_digest='testing-validator'; validator_device=0; validator_inode=0
    boundary_path="$canonical_boundary_validator_path"; boundary_digest='testing-boundary'; boundary_device=0; boundary_inode=0
    pinset_path='testing-pinset'; pinset_digest='testing-pinset'; pinset_device=0; pinset_inode=0
  else
    validate_canonical_validator_inputs
    validator_path="$canonical_dependency_validator_path"; validator_digest="$dependency_validator_digest_value"
    validator_device="$dependency_validator_device_value"; validator_inode="$dependency_validator_inode_value"
    boundary_path="$canonical_boundary_validator_path"; boundary_digest="$boundary_validator_digest_value"
    boundary_device="$boundary_validator_device_value"; boundary_inode="$boundary_validator_inode_value"
    pinset_path="$pinset_path_value"; pinset_digest="$pinset_digest_value"
    pinset_device="$pinset_device_value"; pinset_inode="$pinset_inode_value"
  fi
  tool_path="$tool_path_value"; tool_digest="$tool_digest_value"; tool_device="$tool_device_value"; tool_inode="$tool_inode_value"
  tool_mode="$tool_mode_value"; tool_build_identity="$tool_build_identity_value"
  observation_path="$observation_provider_path_value"; observation_digest="$observation_provider_digest_value"
  observation_device="$observation_provider_device_value"; observation_inode="$observation_provider_inode_value"
  trusted_path="$trusted_observation_provider_path_value"; trusted_digest="$trusted_observation_provider_digest_value"
  trusted_device="$trusted_observation_provider_device_value"; trusted_inode="$trusted_observation_provider_inode_value"
  sleep_path="$sleep_wake_provider_path_value"; sleep_digest="$sleep_wake_provider_digest_value"
  sleep_device="$sleep_wake_provider_device_value"; sleep_inode="$sleep_wake_provider_inode_value"
  /usr/bin/jq -n \
    --arg schema "$run_started_schema" --arg root "$root" --arg status 'launch-pending' \
    --arg rootLockPath "$root/active-run-v1" --arg gateLockPath "$lock" \
    --arg rootLockInfoPath "$root/gate-active-run-v1-info.tsv" --arg gateLockInfoPath "$lock/info-v1.tsv" \
    --argjson rootLockDevice "$root_device" --argjson rootLockInode "$root_inode" \
    --argjson gateLockDevice "$gate_device" --argjson gateLockInode "$gate_inode" \
    --argjson gateLockInfoDevice "$gate_info_device" --argjson gateLockInfoInode "$gate_info_inode" \
    --argjson runnerPID 0 --arg runnerStartIdentity pending \
    --arg sourceCommit "$source_commit" --arg sourceDigest "$source_digest_value" \
    --arg configDigest "$config_digest_value" --arg toolchainDigest "$toolchain_digest_value" \
    --arg dependencyEvidenceDigest "$dependency_digest_value" --arg executablePinsetDigest "$pinset_digest_value" \
    --arg manifestDigest "$(sha "$root/manifest-v1.json")" \
    --arg dependencyValidatorPath "$validator_path" --arg dependencyValidatorDigest "$validator_digest" \
    --argjson dependencyValidatorDevice "$validator_device" --argjson dependencyValidatorInode "$validator_inode" \
    --arg boundaryValidatorPath "$boundary_path" --arg boundaryValidatorDigest "$boundary_digest" \
    --argjson boundaryValidatorDevice "$boundary_device" --argjson boundaryValidatorInode "$boundary_inode" \
    --arg executablePinsetPath "$pinset_path" --arg executablePinsetDigest "$pinset_digest" \
    --argjson executablePinsetDevice "$pinset_device" --argjson executablePinsetInode "$pinset_inode" \
    --arg toolPath "$tool_path" --argjson toolDevice "$tool_device" --argjson toolInode "$tool_inode" \
    --argjson toolMode "$tool_mode" --arg toolDigest "$tool_digest" --arg toolBuildIdentity "$tool_build_identity" \
    --arg invocation "run --root $root" \
    --arg observationProviderPath "$observation_path" --argjson observationProviderDevice "$observation_device" \
    --argjson observationProviderInode "$observation_inode" --arg observationProviderDigest "$observation_digest" \
    --arg trustedObservationProviderPath "$trusted_path" --argjson trustedObservationProviderDevice "$trusted_device" \
    --argjson trustedObservationProviderInode "$trusted_inode" --arg trustedObservationProviderDigest "$trusted_digest" \
    --arg sleepWakeProviderPath "$sleep_path" --argjson sleepWakeProviderDevice "$sleep_device" \
    --argjson sleepWakeProviderInode "$sleep_inode" --arg sleepWakeProviderDigest "$sleep_digest" \
    --arg startedAtUTC "$(now)" \
    '{schema:$schema,root:$root,status:$status,rootLockPath:$rootLockPath,rootLockDevice:$rootLockDevice,rootLockInode:$rootLockInode,
      gateLockPath:$gateLockPath,gateLockDevice:$gateLockDevice,gateLockInode:$gateLockInode,
      rootLockInfoPath:$rootLockInfoPath,gateLockInfoPath:$gateLockInfoPath,gateLockInfoDevice:$gateLockInfoDevice,gateLockInfoInode:$gateLockInfoInode,
      runnerPID:$runnerPID,runnerStartIdentity:$runnerStartIdentity,
      sourceCommit:$sourceCommit,sourceDigest:$sourceDigest,configDigest:$configDigest,toolchainDigest:$toolchainDigest,
      dependencyEvidenceDigest:$dependencyEvidenceDigest,executablePinsetDigest:$executablePinsetDigest,manifestDigest:$manifestDigest,
      dependencyValidatorPath:$dependencyValidatorPath,dependencyValidatorDevice:$dependencyValidatorDevice,dependencyValidatorInode:$dependencyValidatorInode,
      dependencyValidatorDigest:$dependencyValidatorDigest,boundaryValidatorPath:$boundaryValidatorPath,boundaryValidatorDevice:$boundaryValidatorDevice,
      boundaryValidatorInode:$boundaryValidatorInode,boundaryValidatorDigest:$boundaryValidatorDigest,executablePinsetPath:$executablePinsetPath,
      executablePinsetDevice:$executablePinsetDevice,executablePinsetInode:$executablePinsetInode,executablePinsetDigest:$executablePinsetDigest,
      toolPath:$toolPath,toolDevice:$toolDevice,toolInode:$toolInode,toolMode:$toolMode,toolDigest:$toolDigest,toolBuildIdentity:$toolBuildIdentity,
      invocation:$invocation,observationProviderPath:$observationProviderPath,observationProviderDevice:$observationProviderDevice,
      observationProviderInode:$observationProviderInode,observationProviderDigest:$observationProviderDigest,
      trustedObservationProviderPath:$trustedObservationProviderPath,trustedObservationProviderDevice:$trustedObservationProviderDevice,
      trustedObservationProviderInode:$trustedObservationProviderInode,trustedObservationProviderDigest:$trustedObservationProviderDigest,
      sleepWakeProviderPath:$sleepWakeProviderPath,sleepWakeProviderDevice:$sleepWakeProviderDevice,
      sleepWakeProviderInode:$sleepWakeProviderInode,sleepWakeProviderDigest:$sleepWakeProviderDigest,
      startedAtUTC:$startedAtUTC}' \
    | write_private "$marker" 'Gate 15 durable run-started marker' run-started
  run_started_created=1
}

live_runner_start_identity() {
  local marker="$1" pid="$2" identity marker_tool marker_device marker_inode marker_mode marker_digest
  local expected_tool expected_device expected_inode expected_mode expected_digest current_mode_octal
  /usr/bin/jq -e --arg schema "$run_started_schema" '
    .schema == $schema and
    (.toolPath | type == "string") and
    (.toolDevice | type == "number" and . >= 0 and floor == .) and
    (.toolInode | type == "number" and . >= 0 and floor == .) and
    (.toolMode | type == "number" and . == 493) and
    (.toolDigest | type == "string")
  ' "$marker" >/dev/null 2>&1 || return 1
  marker_tool="$(/usr/bin/jq -r '.toolPath // empty' "$marker" 2>/dev/null)"
  marker_device="$(/usr/bin/jq -r '.toolDevice // -1' "$marker" 2>/dev/null)"
  marker_inode="$(/usr/bin/jq -r '.toolInode // -1' "$marker" 2>/dev/null)"
  marker_mode="$(/usr/bin/jq -r '.toolMode // -1' "$marker" 2>/dev/null)"
  marker_digest="$(/usr/bin/jq -r '.toolDigest // empty' "$marker" 2>/dev/null)"
  if testing; then
    expected_tool="$canonical_tool_path"
    expected_device=0
    expected_inode=0
    expected_mode=493
    expected_digest='testing-qualification-tool'
    identity="${HOSTWRIGHT_PHASE09_HARNESS_TEST_PROCESS_IDENTITY:-}"
  else
    [[ -f "$canonical_tool_path" && ! -L "$canonical_tool_path" && -x "$canonical_tool_path" \
      && "$(/bin/realpath "$canonical_tool_path" 2>/dev/null)" == "$canonical_tool_path" \
      ]] || return 1
    current_mode_octal="$(/usr/bin/stat -f '%Lp' "$canonical_tool_path" 2>/dev/null)"
    [[ "$current_mode_octal" == 755 ]] || return 1
    expected_tool="$canonical_tool_path"
    expected_device="$(/usr/bin/stat -f '%d' "$canonical_tool_path" 2>/dev/null)"
    expected_inode="$(/usr/bin/stat -f '%i' "$canonical_tool_path" 2>/dev/null)"
    expected_mode="$((8#$current_mode_octal))"
    expected_digest="$(sha_executable "$canonical_tool_path" 2>/dev/null)" || return 1
    identity="$("$canonical_tool_path" process-identity --pid "$pid" 2>/dev/null)" || return 1
  fi
  [[ "$marker_device" =~ ^[0-9]+$ && "$marker_inode" =~ ^[0-9]+$ \
    && "$marker_mode" =~ ^[0-9]+$ && "$marker_mode" == 493 \
    && "$marker_tool" == "$expected_tool" && "$marker_device" == "$expected_device" \
    && "$marker_inode" == "$expected_inode" && "$marker_mode" == "$expected_mode" \
    && "$marker_digest" == "$expected_digest" ]] || return 1
  [[ "$identity" =~ ^v1\.[a-f0-9]{64}\.[a-f0-9]{64}\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "$identity"
}

valid_existing_runner_marker() {
  local marker="$root/run-started-v1.json" state marker_pid marker_start state_pid state_start live_start
  [[ -f "$marker" && ! -L "$marker" ]] || return 1
  private_file "$marker" || return 1
  marker_pid="$(/usr/bin/jq -r '.runnerPID // 0' "$marker" 2>/dev/null)"
  marker_start="$(/usr/bin/jq -r '.runnerStartIdentity // empty' "$marker" 2>/dev/null)"
  [[ "$marker_pid" =~ ^[1-9][0-9]*$ && "$marker_start" =~ ^v1\.[a-f0-9]{64}\.[a-f0-9]{64}\.[0-9]+\.[0-9]+$ ]] || return 1
  /bin/kill -0 "$marker_pid" >/dev/null 2>&1 || return 1
  live_start="$(live_runner_start_identity "$marker" "$marker_pid")" || return 1
  [[ "$live_start" == "$marker_start" ]] || return 1
  state="$root/runner-state-v1.json"
  require_private_file "$state" 'Gate 15 existing runner state' 2>/dev/null || return 1
  state_pid="$(/usr/bin/jq -r '.runnerPID // 0' "$state" 2>/dev/null)"
  state_start="$(/usr/bin/jq -r '.runnerStartIdentity // empty' "$state" 2>/dev/null)"
  [[ "$state_pid" == "$marker_pid" && "$state_start" == "$marker_start" ]] || return 1
  [[ "$(/usr/bin/jq -r '.status // empty' "$marker" 2>/dev/null)" == 'runner-started' ]] || return 1
  [[ "$(/usr/bin/jq -r '.root // empty' "$marker" 2>/dev/null)" == "$root" ]] || return 1
  private_directory "$root/active-run-v1" && private_directory "$parent/.phase09-gate15-active-v1" || return 1
  return 0
}

freeze_stale_run_marker() {
  local marker="$root/run-started-v1.json"
  if assert_absent "$root/failure-v1.tsv"; then
    printf '%s\n%s\n' $'recorded_at\tgate\tcell\texit_status\tcommand\tstdout_sha256\tstderr_sha256' \
      "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$(now)" "$gate" 0 73 'stale run-started-v1 marker' '-' '-')" \
      | write_private "$root/failure-v1.tsv" 'Gate 15 stale-run failure ledger' stale-run-failure
  fi
  if [[ -f "$root/manifest-v1.json" && ! -L "$root/manifest-v1.json" ]]; then
    /usr/bin/jq --arg completed "$(now)" \
      '.status="failed"|.claim="none"|.formal=false|.completedAt=$completed' "$root/manifest-v1.json" \
      | replace_private "$root/manifest-v1.json" 'Gate 15 stale-run failed manifest' stale-run-manifest
  fi
  die 'Gate 15 found a run-started marker without the same live runner; the root is failed and permanently frozen.' 73
}

reject_frozen_root() {
  [[ ! -f "$root/failure-v1.tsv" ]] || die 'Gate 15 failure evidence is immutable; do not rerun this root.' 73
  if [[ -e "$root/run-started-v1.json" || -L "$root/run-started-v1.json" ]]; then
    valid_existing_runner_marker \
      && die 'Gate 15 run-started marker belongs to an already live runner; duplicate execution is refused.' 75
    freeze_stale_run_marker
  fi
  if [[ -f "$root/manifest-v1.json" ]]; then
    local manifest_status_value
    manifest_status_value="$(/usr/bin/jq -r .status "$root/manifest-v1.json")"
    if [[ "$manifest_status_value" == passed ]]; then
      return 0
    fi
    [[ "$manifest_status_value" == prepared ]] \
      || die 'Gate 15 run cannot resume a root that is already running or failed; use a new root.' 73
  fi
  [[ ! -e "$root/samples-v1.ndjson" && ! -e "$root/runner-state-v1.json" ]] \
    || die 'Gate 15 elapsed-time resume is forbidden; use a new root and retain this root.' 73
}

record_root() {
  local path="$1" identifier="$2"
  [[ -d "$path" && ! -L "$path" && "$path" == "$root"/* \
    && "$(/bin/realpath "$path")" == "$path" && "$identifier" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] \
    || die 'Gate 15 owned root is unsafe.' 124
  append_private_line "$root/ownership-v1.tsv" \
    "$(printf '%s\ttemporary-root\t%s\t%s\t%s\t%s\towned=gate15\n' \
      "$(now)" "$identifier" "$path" "$(/usr/bin/stat -f '%d' "$path")" "$(/usr/bin/stat -f '%i' "$path")")"
}

cell_command() {
  case "$1" in
    1) printf '%s\n' '/usr/bin/swift test --jobs 1 --filter Gate15 continuity contract, identity, and hash-chain tests' ;;
    2) printf '%s\n' '/usr/bin/swift build --configuration release --jobs 1 --target HostwrightPhase09QualificationTool and signed-boundary inputs' ;;
    3) printf '%s\n' 'scripts/phase09-gate15-live.sh run --root <fixed-root>' ;;
    4) printf '%s\n' '/usr/bin/swift test --jobs 1 --filter HostwrightPhase09QualificationToolTests and continuity persistence' ;;
    5) printf '%s\n' '/usr/bin/swift test --jobs 1 --filter Gate15 adversarial replacement, reboot, gap, sleep, and tamper tests' ;;
    6) printf '%s\n' 'Gate15 harness tests; /usr/bin/swift build --configuration release; lint; docs; diff verification' ;;
    *) die 'unknown Gate 15 cell.' 64 ;;
  esac
}

run_cell() {
  local cell="$1"
  if testing; then
    [[ "${HOSTWRIGHT_PHASE09_HARNESS_TEST_FORCE_FAILURE:-}" != 1 ]] || return 47
    [[ "$cell" != 3 ]] || die 'test mode cannot manufacture or claim a 72-hour Gate 15 passage.' 70
    printf 'test-mode cell %s: local contract fixture only\n' "$cell"
    return 0
  fi
  case "$cell" in
    1) /usr/bin/swift test --jobs 1 --filter 'HostwrightPhase09QualificationToolTests|Phase09Gate15QualificationHarnessTests' ;;
    2) /usr/bin/swift build --configuration release --jobs 1 --target HostwrightPhase09QualificationTool ;;
    3) "$repository_path/scripts/phase09-gate15-live.sh" run --root "$root" ;;
    4) /usr/bin/swift test --jobs 1 --filter 'HostwrightPhase09QualificationToolTests' ;;
    5) /usr/bin/swift test --jobs 1 --filter 'HostwrightPhase09QualificationToolTests/testReplacement|HostwrightPhase09QualificationToolTests/testSleep|HostwrightPhase09QualificationToolTests/testHash' ;;
    6) /usr/bin/swift test --jobs 1 --filter 'Phase09Gate15QualificationHarnessTests'; /usr/bin/swift build --configuration release --jobs 1 --target HostwrightPhase09QualificationTool; "$repository_path/scripts/lint.sh"; "$repository_path/scripts/check-docs.sh"; /usr/bin/git diff --check ;;
    *) die 'unknown Gate 15 cell.' 64 ;;
  esac
}

capture_cell_legacy() {
  local cell="$1" capture status out_tmp err_tmp
  capture="$(/usr/bin/python3 -c '
import os, secrets, subprocess, sys
root, script, cell, cwd = sys.argv[1:]
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
def open_capture(kind):
    for _ in range(64):
        path = os.path.join(root, ".gate15-cell-" + kind + "." + secrets.token_hex(12))
        try:
            descriptor = os.open(path, flags, 0o600)
        except FileExistsError:
            continue
        return path, os.fdopen(descriptor, "wb", buffering=0)
    raise OSError("could not allocate an exclusive cell capture")
out_path, out_file = open_capture("stdout")
err_path, err_file = open_capture("stderr")
try:
    allowed = {
        "PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "DEVELOPER_DIR", "SDKROOT",
        "HOSTWRIGHT_NOTARY_PROFILE", "HOSTWRIGHT_PHASE09_HARNESS_TESTING", "HOSTWRIGHT_PHASE09_HARNESS_TEST_FORCE_FAILURE",
        "HOSTWRIGHT_GATE15_ROOT", "HOSTWRIGHT_GATE15_SOURCE_COMMIT", "HOSTWRIGHT_GATE15_SOURCE_DIGEST",
        "HOSTWRIGHT_GATE15_CONFIG_DIGEST", "HOSTWRIGHT_GATE15_TOOLCHAIN_DIGEST",
        "HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE_DIGEST", "HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST",
        "HOSTWRIGHT_GATE15_MANIFEST_DIGEST", "HOSTWRIGHT_GATE15_SIGNING_IDENTITY",
        "HOSTWRIGHT_GATE15_SIGNING_FINGERPRINT", "HOSTWRIGHT_GATE15_CERTIFICATE_FINGERPRINT",
        "HOSTWRIGHT_GATE15_TEAM_ID", "HOSTWRIGHT_GATE15_LAUNCH_AUTHORIZATION",
        "HOSTWRIGHT_GATE15_LAUNCH_REQUEST", "HOSTWRIGHT_GATE15_RUN_STARTED",
        "HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR", "HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR_DEVICE",
        "HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR_INODE", "HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR_DIGEST",
        "HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR", "HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR_DEVICE",
        "HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR_INODE", "HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR_DIGEST",
        "HOSTWRIGHT_GATE15_EXECUTABLE_PINSET", "HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DEVICE",
        "HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_INODE", "HOSTWRIGHT_GATE15_TOOL",
        "HOSTWRIGHT_GATE15_TOOL_DEVICE", "HOSTWRIGHT_GATE15_TOOL_INODE", "HOSTWRIGHT_GATE15_TOOL_MODE",
        "HOSTWRIGHT_GATE15_TOOL_DIGEST", "HOSTWRIGHT_GATE15_TOOL_BUILD_IDENTITY",
        "HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER", "HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER_DEVICE",
        "HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER_INODE", "HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER_DIGEST",
        "HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER", "HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER_DEVICE",
        "HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER_INODE", "HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER_DIGEST",
        "HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER", "HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER_DEVICE",
        "HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER_INODE", "HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER_DIGEST",
        "HOSTWRIGHT_GATE15_RUNTIME_SETUP", "HOSTWRIGHT_GATE15_LIVE_RUNTIME_ROOT",
        "HOSTWRIGHT_GATE15_PROJECT", "HOSTWRIGHT_GATE15_IMAGE_DIGEST", "HOSTWRIGHT_GATE15_RUNTIME_UUID",
        "HOSTWRIGHT_GATE15_SIGNED_EXECUTABLES"
    }
    child_env = {key: value for key, value in os.environ.items() if key in allowed}
    child_env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    for key in ("BASH_ENV", "ENV", "CDPATH", "PYTHONPATH", "DYLD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD"):
        child_env.pop(key, None)
    result = subprocess.run(["/bin/bash", script, "__run-cell", cell], cwd=cwd, env=child_env,
                            stdout=out_file, stderr=err_file, check=False)
    out_file.flush(); os.fsync(out_file.fileno())
    err_file.flush(); os.fsync(err_file.fileno())
finally:
    out_file.close(); err_file.close()
print("{}\t{}\t{}".format(result.returncode, out_path, err_path))
' "$root" "$script_absolute" "$cell" "$repo_root")" \
    || die 'Gate 15 cell capture helper failed closed.' 124
  IFS=$'\t' read -r status out_tmp err_tmp <<< "$capture"
  [[ "$status" =~ ^[0-9]+$ && -n "$out_tmp" && -n "$err_tmp" ]] \
    || die 'Gate 15 cell capture result was malformed.' 124
  private_file "$out_tmp" || die 'Gate 15 cell stdout temporary failed private validation.' 124
  private_file "$err_tmp" || die 'Gate 15 cell stderr temporary failed private validation.' 124
  printf '%s\t%s\t%s\n' "$status" "$out_tmp" "$err_tmp"
}

capture_cell() {
  local cell="$1" result_tmp python_status capture
  result_tmp="$(make_private_temp capture-result)"
  /usr/bin/python3 -c '
import os, secrets, signal, subprocess, sys
root, script, cell, cwd = sys.argv[1:]
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
child = None

def open_capture(kind):
    for _ in range(64):
        path = os.path.join(root, ".gate15-cell-" + kind + "." + secrets.token_hex(12))
        try:
            descriptor = os.open(path, flags, 0o600)
        except FileExistsError:
            continue
        return path, os.fdopen(descriptor, "wb", buffering=0)
    raise OSError("could not allocate an exclusive cell capture")

def stop(signum, _frame):
    if child is not None and child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
    raise SystemExit(128 + signum)

for signal_number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(signal_number, stop)

out_path, out_file = open_capture("stdout")
err_path, err_file = open_capture("stderr")
try:
    allowed = {
        "PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "DEVELOPER_DIR", "SDKROOT",
        "HOSTWRIGHT_NOTARY_PROFILE", "HOSTWRIGHT_PHASE09_HARNESS_TESTING", "HOSTWRIGHT_PHASE09_HARNESS_TEST_FORCE_FAILURE",
        "HOSTWRIGHT_GATE15_ROOT", "HOSTWRIGHT_GATE15_SOURCE_COMMIT", "HOSTWRIGHT_GATE15_SOURCE_DIGEST",
        "HOSTWRIGHT_GATE15_CONFIG_DIGEST", "HOSTWRIGHT_GATE15_TOOLCHAIN_DIGEST",
        "HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE_DIGEST", "HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST",
        "HOSTWRIGHT_GATE15_MANIFEST_DIGEST", "HOSTWRIGHT_GATE15_SIGNING_IDENTITY",
        "HOSTWRIGHT_GATE15_SIGNING_FINGERPRINT", "HOSTWRIGHT_GATE15_CERTIFICATE_FINGERPRINT",
        "HOSTWRIGHT_GATE15_TEAM_ID", "HOSTWRIGHT_GATE15_LAUNCH_AUTHORIZATION",
        "HOSTWRIGHT_GATE15_LAUNCH_REQUEST", "HOSTWRIGHT_GATE15_RUN_STARTED",
        "HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR", "HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR_DEVICE",
        "HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR_INODE", "HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR_DIGEST",
        "HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR", "HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR_DEVICE",
        "HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR_INODE", "HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR_DIGEST",
        "HOSTWRIGHT_GATE15_EXECUTABLE_PINSET", "HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DEVICE",
        "HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_INODE", "HOSTWRIGHT_GATE15_TOOL", "HOSTWRIGHT_GATE15_TOOL_DEVICE",
        "HOSTWRIGHT_GATE15_TOOL_INODE", "HOSTWRIGHT_GATE15_TOOL_MODE", "HOSTWRIGHT_GATE15_TOOL_DIGEST",
        "HOSTWRIGHT_GATE15_TOOL_BUILD_IDENTITY", "HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER",
        "HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER_DEVICE", "HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER_INODE",
        "HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER_DIGEST", "HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER",
        "HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER_DEVICE", "HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER_INODE",
        "HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER_DIGEST", "HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER",
        "HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER_DEVICE", "HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER_INODE",
        "HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER_DIGEST", "HOSTWRIGHT_GATE15_RUNTIME_SETUP",
        "HOSTWRIGHT_GATE15_LIVE_RUNTIME_ROOT", "HOSTWRIGHT_GATE15_PROJECT", "HOSTWRIGHT_GATE15_IMAGE_DIGEST",
        "HOSTWRIGHT_GATE15_RUNTIME_UUID", "HOSTWRIGHT_GATE15_SIGNED_EXECUTABLES"
    }
    child_env = {key: value for key, value in os.environ.items() if key in allowed}
    child_env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    for key in ("BASH_ENV", "ENV", "CDPATH", "PYTHONPATH", "DYLD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD"):
        child_env.pop(key, None)
    child = subprocess.Popen(
        ["/bin/bash", script, "__run-cell", cell], cwd=cwd, env=child_env,
        stdout=out_file, stderr=err_file, start_new_session=True
    )
    result_status = child.wait()
    out_file.flush(); os.fsync(out_file.fileno())
    err_file.flush(); os.fsync(err_file.fileno())
finally:
    out_file.close(); err_file.close()
if child is None:
    raise SystemExit("cell child was not started")
print("{}\t{}\t{}".format(result_status, out_path, err_path))
' "$root" "$script_absolute" "$cell" "$repo_root" > "$result_tmp" 2>/dev/null &
  qualification_child_pid=$!
  if wait "$qualification_child_pid"; then
    python_status=0
  else
    python_status=$?
  fi
  qualification_child_pid=0
  [[ "$python_status" == 0 ]] || die 'Gate 15 cell capture helper failed closed.' 124
  capture="$(/bin/cat "$result_tmp")"
  /bin/unlink "$result_tmp"
  IFS=$'\t' read -r capture_status capture_out_tmp capture_err_tmp <<< "$capture"
  [[ "$capture_status" =~ ^[0-9]+$ && -n "$capture_out_tmp" && -n "$capture_err_tmp" ]] \
    || die 'Gate 15 cell capture result was malformed.' 124
  private_file "$capture_out_tmp" || die 'Gate 15 cell stdout temporary failed private validation.' 124
  private_file "$capture_err_tmp" || die 'Gate 15 cell stderr temporary failed private validation.' 124
}

state() {
  append_private_line "$root/state-v1.tsv" \
    "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$gate" "$1" "$2" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" \
      "$3" "$4" "$5" "$6")"
}

failure() {
  if assert_absent "$root/failure-v1.tsv"; then
    printf '%s\n' $'recorded_at\tgate\tcell\texit_status\tcommand\tstdout_sha256\tstderr_sha256' \
      | write_private "$root/failure-v1.tsv" 'Gate 15 failure ledger' failure
  else
    require_private_file "$root/failure-v1.tsv" 'Gate 15 failure ledger'
  fi
  append_private_line "$root/failure-v1.tsv" \
    "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$gate" "$1" "$2" "$3" "$4" "$5")"
}

validate_complete_sample_ledger() {
  local validation_mode="${1:-finalize}" provider_identity trusted_identity sleep_identity tool_identity
  [[ "$validation_mode" == finalize || "$validation_mode" == reuse ]] \
    || die 'Gate 15 sample-ledger validation mode is invalid.' 124
  provider_identity="$observation_provider_path_value|$observation_provider_device_value|$observation_provider_inode_value|$observation_provider_digest_value"
  trusted_identity="$trusted_observation_provider_path_value|$trusted_observation_provider_device_value|$trusted_observation_provider_inode_value|$trusted_observation_provider_digest_value"
  sleep_identity="$sleep_wake_provider_path_value|$sleep_wake_provider_device_value|$sleep_wake_provider_inode_value|$sleep_wake_provider_digest_value"
  tool_identity="$tool_path_value|$tool_device_value|$tool_inode_value|$tool_digest_value"
  /usr/bin/python3 - "$root" "$sample_count" "$interval_seconds" "$duration_seconds" \
    "$source_commit" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" \
    "$dependency_digest_value" "$pinset_digest_value" "$provider_identity" "$trusted_identity" \
    "$sleep_identity" "$tool_identity" "$tool_path_value" "$tool_digest_value" \
    "${HOSTWRIGHT_GATE15_PROJECT:-}" "${HOSTWRIGHT_GATE15_IMAGE_DIGEST:-}" "${HOSTWRIGHT_GATE15_RUNTIME_UUID:-}" \
    "$validation_mode" <<'PY'
import datetime
import hashlib
import json
import math
import os
import re
import stat
import sys


def fail(message):
    raise SystemExit(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def digest(value, prefix="sha256:"):
    return prefix + hashlib.sha256(canonical(value)).hexdigest()


def file_digest(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def require_single_link(path):
    information = os.lstat(path)
    if stat.S_ISLNK(information.st_mode) or not stat.S_ISREG(information.st_mode) or information.st_nlink != 1:
        fail("unsafe ledger identity: " + path)


def parse_utc(value):
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?Z", value):
        fail("non-canonical UTC timestamp")
    fraction = value[:-1]
    if "." in fraction:
        head, digits = fraction.split(".", 1)
        value = head + "." + (digits + "000000")[:6] + "Z"
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def ceil_ticks(seconds, numer, denom):
    scaled = seconds * 1_000_000_000 * denom
    return (scaled + numer - 1) // numer


(root, expected_count, interval_seconds, duration_seconds, expected_commit, expected_source,
 expected_config, expected_toolchain, expected_dependency, expected_pinset, provider_identity,
 trusted_identity, sleep_identity, tool_identity, expected_tool_path, expected_tool_digest,
 expected_project, expected_image, expected_runtime, validation_mode) = sys.argv[1:]
expected_count = int(expected_count)
interval_seconds = int(interval_seconds)
duration_seconds = int(duration_seconds)
if validation_mode not in ("finalize", "reuse"):
    fail("sample-ledger validation mode is invalid")
state_path = os.path.join(root, "runner-state-v1.json")
marker_path = os.path.join(root, "run-started-v1.json")
samples_path = os.path.join(root, "samples-v1.ndjson")
manifest_path = os.path.join(root, "manifest-v1.json")
signed_path = os.path.join(root, "signed-executables-v1.tsv")
for path in (state_path, marker_path, samples_path, manifest_path, signed_path):
    require_single_link(path)

with open(state_path, encoding="utf-8") as handle:
    state = json.load(handle)
expected_states = ("finalizing", "pre-pass") if validation_mode == "finalize" else ("passed",)
if state.get("schema") != "hostwright.phase09.gate15.runner-state.v1" or state.get("status") not in expected_states:
    fail("runner state is not in the required validation state")
if state.get("root") != root or state.get("sampleCount") != expected_count:
    fail("runner state sample/root binding is incomplete")
if state.get("sourceCommit") != expected_commit or state.get("sourceDigest") != expected_source:
    fail("runner state source binding changed")
if state.get("configDigest") != expected_config or state.get("toolchainDigest") != expected_toolchain:
    fail("runner state configuration binding changed")
if state.get("dependencyEvidenceDigest") != expected_dependency or state.get("executablePinsetDigest") != expected_pinset:
    fail("runner state dependency binding changed")
if state.get("toolPath") != expected_tool_path or state.get("toolDigest") != expected_tool_digest or state.get("toolMode") != 493:
    fail("runner state tool binding changed")
if state.get("timebaseNumer", 0) <= 0 or state.get("timebaseDenom", 0) <= 0:
    fail("runner state timebase is missing")

with open(marker_path, encoding="utf-8") as handle:
    marker = json.load(handle)
if marker.get("schema") != "hostwright.phase09.gate15.run-started.v1" or marker.get("root") != root:
    fail("run-started marker is not bound to the root")
if file_digest(marker_path) != state.get("runStartedDigest"):
    fail("run-started marker digest changed")
if marker.get("rootLockPath") != os.path.join(root, "active-run-v1") or marker.get("gateLockPath") != os.path.join(os.path.dirname(root), ".phase09-gate15-active-v1"):
    fail("run-started marker lock paths are not canonical")
if marker.get("runnerPID") != state.get("runnerPID") or marker.get("runnerStartIdentity") != state.get("runnerStartIdentity"):
    fail("runner identity changed between marker and state")
if not isinstance(marker.get("runnerPID"), int) or marker.get("runnerPID") <= 0 or not re.fullmatch(r"v1\\.[a-f0-9]{64}\\.[a-f0-9]{64}\\.[0-9]+\\.[0-9]+", str(marker.get("runnerStartIdentity", ""))):
    fail("runner identity is not bound")
if marker.get("manifestDigest") != state.get("manifestDigest"):
    fail("run-started marker manifest binding changed")
for field in ("rootLockDevice", "rootLockInode", "gateLockDevice", "gateLockInode",
              "toolPath", "toolDevice", "toolInode", "toolMode", "toolDigest", "toolBuildIdentity"):
    if marker.get(field) != state.get(field):
        fail("run-started marker binding changed: " + field)
for field in ("sourceCommit", "sourceDigest", "configDigest", "toolchainDigest", "dependencyEvidenceDigest", "executablePinsetDigest"):
    if marker.get(field) != state.get(field):
        fail("run-started marker binding changed: " + field)

with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
if manifest.get("schema") != "hostwright.phase09.gate15.qualification.manifest.v1" or manifest.get("status") not in (("prepared",) if validation_mode == "finalize" else ("passed",)):
    fail("manifest is not in the required validation state")
for field, expected in (("sourceCommit", expected_commit), ("sourceDigest", expected_source),
                        ("configDigest", expected_config), ("toolchainDigest", expected_toolchain),
                        ("dependencyEvidenceDigest", expected_dependency), ("executablePinsetDigest", expected_pinset)):
    if manifest.get(field) != expected:
        fail("manifest binding changed: " + field)
if validation_mode == "finalize" and file_digest(manifest_path) != state.get("manifestDigest"):
    fail("manifest digest changed")

root_lock_path = os.path.join(root, "active-run-v1")
gate_lock_path = os.path.join(os.path.dirname(root), ".phase09-gate15-active-v1")
root_info_path = os.path.join(root, "gate-active-run-v1-info.tsv")
gate_info_path = os.path.join(gate_lock_path, "info-v1.tsv")
if validation_mode == "finalize":
    locks = ((root_lock_path, state.get("rootLockDevice"), state.get("rootLockInode")),
             (gate_lock_path, state.get("gateLockDevice"), state.get("gateLockInode")))
    for path, device, inode in locks:
        information = os.lstat(path)
        if not stat.S_ISDIR(information.st_mode) or stat.S_ISLNK(information.st_mode) or information.st_uid != os.getuid() or (information.st_mode & 0o777) != 0o700:
            fail("active lock identity is unsafe")
        if information.st_dev != int(device) or information.st_ino != int(inode):
            fail("active lock device or inode changed")
else:
    if os.path.lexists(root_lock_path) or os.path.lexists(gate_lock_path) or os.path.lexists(gate_info_path):
        fail("passed evidence still has an active lock")
    require_single_link(root_info_path)
    root_info = os.lstat(root_info_path)
    if root_info.st_uid != os.getuid() or (root_info.st_mode & 0o777) != 0o600:
        fail("released lock info identity is unsafe")
    lock_lines = open(root_info_path, encoding="utf-8").read().splitlines()
    expected_lock_row = "\\t".join(str(value) for value in (
        root, marker["runnerPID"], marker["runnerStartIdentity"], marker["startedAtUTC"], expected_commit,
        expected_source, expected_config, expected_toolchain, expected_dependency, expected_pinset,
        state["manifestDigest"]
    ))
    if lock_lines != ["root\\tpid\\trunner_start_identity\\tstarted_at\\tsource_commit\\tsource_digest\\tconfig_digest\\ttoolchain_digest\\tdependency_digest\\tpinset_digest\\tmanifest_digest", expected_lock_row]:
        fail("released lock binding is not exact")

allowed_executables = set()
with open(signed_path, encoding="utf-8") as handle:
    rows = handle.read().splitlines()
if not rows or rows[0] != "path\tsha256\tcdhash\tteamID\tidentifier":
    fail("signed executable ledger header is invalid")
for row in rows[1:]:
    fields = row.split("\t")
    if len(fields) != 5:
        fail("signed executable ledger row is invalid")
    allowed_executables.add(tuple(fields[1:]))
if not allowed_executables:
    fail("signed executable ledger is empty")

with open(samples_path, "rb") as handle:
    raw = handle.read()
if not raw.endswith(b"\n"):
    fail("sample ledger is not newline terminated")
lines = raw.splitlines(keepends=True)
if len(lines) != expected_count:
    fail("sample ledger count is not exactly 865")
samples = []
for index, line in enumerate(lines):
    if not line.endswith(b"\n") or line.endswith(b"\r\n"):
        fail("sample ledger line ending is not canonical")
    payload = line[:-1]
    try:
        sample = json.loads(payload)
    except Exception:
        fail("sample ledger contains malformed JSON")
    if canonical(sample) + b"\n" != line:
        fail("sample ledger JSON is not canonical")
    if sample.get("sequence") != index:
        fail("sample sequence is not contiguous")
    sample_input = dict(sample)
    actual_hash = sample_input.pop("sampleSHA256", None)
    if not isinstance(actual_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", actual_hash) or actual_hash != hashlib.sha256(canonical(sample_input)).hexdigest():
        fail("sample hash chain record is invalid")
    previous_hash = sample.get("previousSampleSHA256")
    if index == 0:
        if previous_hash is not None:
            fail("initial sample has a previous hash")
    elif previous_hash != samples[-1].get("sampleSHA256"):
        fail("sample hash chain is not append-only")
    samples.append(sample)

first = samples[0]
last = samples[-1]
timebase_numer = int(state["timebaseNumer"])
timebase_denom = int(state["timebaseDenom"])
if (last["continuousTicks"] - first["continuousTicks"]) * timebase_numer < duration_seconds * 1_000_000_000 * timebase_denom:
    fail("continuous duration is below 259200 seconds")
expected_binding = {
    "sourceDigest": expected_source,
    "configDigest": expected_config,
    "toolchainDigest": expected_toolchain,
    "dependencyEvidenceDigest": expected_dependency,
    "executablePinsetDigest": expected_pinset,
}
runner_identity = first.get("runner")
boot_identity = first.get("bootSessionID")
previous_date = None
previous_ticks = None
previous_daemon = None
seen_sleep_event_ids = set()
lower_ticks = ceil_ticks(max(1, interval_seconds - 30), timebase_numer, timebase_denom)
upper_ticks = ceil_ticks(interval_seconds + 30, timebase_numer, timebase_denom)
scheduled_ticks = ceil_ticks(interval_seconds, timebase_numer, timebase_denom)

for index, sample in enumerate(samples):
    if not isinstance(sample.get("continuousTicks"), int) or sample.get("continuousTicks") < 0:
        fail("sample continuous time is malformed")
    if previous_ticks is not None and sample["continuousTicks"] <= previous_ticks:
        fail("continuous time is not strictly monotonic")
    if sample.get("runner") != runner_identity or sample.get("bootSessionID") != boot_identity:
        fail("runner or boot identity changed")
    if not sample.get("boundaryBinding") == expected_binding:
        fail("formal source/tool/dependency binding changed in a sample")
    if not sample.get("fault", {}).get("recoveryWithinBound"):
        fail("sample fault recovery is unbounded")
    executable = sample.get("executable", {})
    executable_tuple = (executable.get("sha256", "").removeprefix("sha256:"), executable.get("cdHash"), executable.get("teamID"), executable.get("identifier"))
    if executable_tuple not in allowed_executables:
        fail("sample executable identity is not in the pinned ledger")
    runtime = sample.get("runtime", {})
    if expected_project and (runtime.get("project") != expected_project or runtime.get("imageDigest") != expected_image or runtime.get("runtimeUUID") != expected_runtime):
        fail("sample runtime/container identity changed")
    receipt = sample.get("independentReceipt")
    if not isinstance(receipt, dict) or receipt.get("source") != "hostwright.live-wrapper.system-observation-receipt-v1":
        fail("sample is missing the independent system observation receipt")
    observer_identity = receipt.get("observerIdentity", "")
    if not re.fullmatch(r"macos-system-observer-v1:[A-Za-z0-9._:-]{1,256}", observer_identity):
        fail("sample observer identity is not pinned")
    if observer_identity in (provider_identity, trusted_identity, sleep_identity, tool_identity):
        fail("provider, observer, and tool identities are not independent")
    if receipt.get("inventoryDigest") != runtime.get("inventoryDigest") or receipt.get("daemonStateDigest") != sample.get("stateDatabase", {}).get("identityDigest") or receipt.get("executableIdentityDigest") != executable.get("sha256"):
        fail("independent receipt identity fields do not match the sample")
    observation = {key: value for key, value in sample.items() if key != "independentReceipt" and key not in ("sequence", "previousSampleSHA256", "sampleSHA256")}
    observation["sleepWakeCoverage"] = []
    expected_component_digests = {
        "executableReceiptDigest": digest(executable),
        "daemonReceiptDigest": digest(sample.get("daemon")),
        "stateReceiptDigest": digest(sample.get("stateDatabase")),
        "containerReceiptDigest": digest({"runtimeUUID": runtime.get("runtimeUUID"), "project": runtime.get("project"), "imageDigest": runtime.get("imageDigest")}),
        "runtimeReceiptDigest": digest(runtime),
    }
    if any(receipt.get(key) != value for key, value in expected_component_digests.items()):
        fail("independent receipt component digest changed")
    receipt_input = {key: receipt.get(key) for key in (
        "source", "observerIdentity", "inventoryDigest", "daemonStateDigest", "executableIdentityDigest",
        "executableReceiptDigest", "daemonReceiptDigest", "stateReceiptDigest", "containerReceiptDigest", "runtimeReceiptDigest")}
    if receipt.get("receiptDigest") != digest(receipt_input):
        fail("independent receipt digest changed")
    auth_input = {
        "observation": observation,
        "source": receipt.get("source"),
        "inventoryDigest": receipt.get("inventoryDigest"),
        "daemonStateDigest": receipt.get("daemonStateDigest"),
        "executableIdentityDigest": receipt.get("executableIdentityDigest"),
        "receipt": receipt_input,
    }
    if receipt.get("authorizationDigest") != digest(auth_input):
        fail("independent receipt authorization digest changed")
    if previous_date is not None and parse_utc(sample["observedAtUTC"]) < previous_date:
        fail("wall clock moved backwards")
    current_date = parse_utc(sample["observedAtUTC"])
    for interval in sample.get("sleepWakeCoverage") or []:
        for event_key in ("sleepEventID", "wakeEventID"):
            event_id = interval.get(event_key)
            if not isinstance(event_id, str) or not re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", event_id) or event_id in seen_sleep_event_ids:
                fail("sleep/wake event IDs are not globally unique")
            seen_sleep_event_ids.add(event_id)
    if previous_ticks is not None:
        delta_ticks = sample["continuousTicks"] - previous_ticks
        if delta_ticks < lower_ticks:
            fail("sample cadence is too early")
        coverage = sample.get("sleepWakeCoverage") or []
        if delta_ticks <= upper_ticks and coverage:
            fail("awake cadence sample contains unneeded sleep proof")
        if delta_ticks > upper_ticks:
            if not coverage:
                fail("extended cadence sample has no sleep proof")
            covered = 0
            previous_end = None
            previous_wake = None
            for interval in coverage:
                if interval.get("source") != "macos-iokit-power-events-v1" or interval.get("observerIdentity") in (provider_identity, trusted_identity, sleep_identity, tool_identity):
                    fail("sleep coverage is not OS-observer pinned")
                if previous_end is not None and interval.get("continuousStartTicks") != previous_end:
                    fail("sleep coverage has a gap or overlap")
                sleep_date = parse_utc(interval["sleepStartUTC"])
                wake_date = parse_utc(interval["wakeUTC"])
                if not (interval["continuousStartTicks"] >= previous_ticks and interval["continuousEndTicks"] <= sample["continuousTicks"] and sleep_date > previous_date and wake_date < current_date and wake_date > sleep_date):
                    fail("sleep coverage is outside the sample interval")
                if previous_wake is not None and sleep_date < previous_wake:
                    fail("sleep timestamps are not ordered")
                for kind, event_id, observed_at, ticks, key in (("sleep", interval["sleepEventID"], interval["sleepStartUTC"], interval["continuousStartTicks"], "sleepObserverReceiptDigest"), ("wake", interval["wakeEventID"], interval["wakeUTC"], interval["continuousEndTicks"], "wakeObserverReceiptDigest")):
                    receipt_input = {"observerIdentity": interval["observerIdentity"], "eventID": event_id, "kind": kind, "observedAtUTC": observed_at, "continuousTicks": ticks}
                    if interval.get(key) != digest(receipt_input):
                        fail("sleep/wake observer receipt digest changed")
                interval_input = {key: interval.get(key) for key in ("sleepStartUTC", "wakeUTC", "continuousStartTicks", "continuousEndTicks", "sleepEventID", "wakeEventID", "source", "observerIdentity", "sleepObserverReceiptDigest", "wakeObserverReceiptDigest")}
                if interval.get("authenticationDigest") != digest(interval_input):
                    fail("sleep/wake interval authentication digest changed")
                covered += interval["continuousEndTicks"] - interval["continuousStartTicks"]
                previous_end = interval["continuousEndTicks"]
                previous_wake = wake_date
            if covered != delta_ticks - scheduled_ticks:
                fail("sleep coverage does not exactly account for the extended cadence")
    daemon = sample.get("daemon")
    if previous_daemon is not None and daemon != previous_daemon:
        fault = sample.get("fault", {})
        restart = fault.get("daemonRestart") or {}
        if not fault.get("plannedDaemonRestart") or restart.get("previous") != previous_daemon or restart.get("current") != daemon or daemon.get("generation") != previous_daemon.get("generation", 0) + 1 or not restart.get("recoveryWithinBound"):
            fail("daemon replacement is not a planned bounded fault")
    previous_daemon = daemon
    previous_date = current_date
    previous_ticks = sample["continuousTicks"]

ledger_digest = file_digest(samples_path)
if state.get("finalLedgerDigest") != ledger_digest:
    fail("final ledger digest is not bound to the pre-pass runner state")
PY
}

manifest_status() {
  local status="$1" completed="${2:-}"
  assert_absent "$root/.manifest-v1.next" || die 'staged Gate 15 manifest already exists; preserve the root.' 73
  /usr/bin/jq --arg status "$status" --arg completed "$completed" \
    '.status=$status|.claim=(if $status=="passed" then "formal" else "none" end)|.formal=($status=="passed")|.completedAt=(if $completed=="" then null else $completed end)' \
    "$root/manifest-v1.json" | replace_private "$root/manifest-v1.json" 'Gate 15 manifest status' manifest-status
}

validate_final_evidence() {
  local file cell sample_lines
  assert_absent "$root/failure-v1.tsv" || die 'Gate 15 final evidence cannot be sealed after any failure evidence exists.' 74
  for file in \
    dependency-evidence-v1.json state-v1.tsv ownership-v1.tsv owned-runtime-v1.tsv toolchain-v1.txt \
    signed-executables-v1.tsv fault-schedule-v1.tsv runtime-inventory-before-v1.json runtime-inventory-after-v1.json \
    gate-active-run-v1-info.tsv run-attempt-v1.json run-started-v1.json samples-v1.ndjson runner-state-v1.json \
    launch-request-v1.json launch-authorization-v1.consumed.cms; do
    require_private_file "$root/$file" "Gate 15 final evidence $file"
  done
  for cell in 1 2 3 4 5 6; do
    file="$root/cell-$(printf '%02d' "$cell").stdout.log"
    require_private_file "$file" "Gate 15 cell $cell stdout evidence"
    file="$root/cell-$(printf '%02d' "$cell").stderr.log"
    require_private_file "$file" "Gate 15 cell $cell stderr evidence"
  done
  validate_complete_sample_ledger
  sample_lines="$(/usr/bin/wc -l < "$root/samples-v1.ndjson" | /usr/bin/tr -d ' ')"
  [[ "$sample_lines" == "$sample_count" ]] || die 'Gate 15 final evidence does not contain exactly 865 samples.' 74
  /usr/bin/jq -s -e --argjson expected "$sample_count" '
    length == $expected and .[0].sequence == 0 and .[-1].sequence == ($expected - 1)
    and .[0].previousSampleSHA256 == null
    and all(.[]; has("sampleSHA256") and has("previousSampleSHA256") and has("sleepWakeCoverage")
      and has("continuousTicks") and has("runner") and has("daemon") and has("executable")
      and has("stateDatabase") and has("runtime") and has("fault"))
  ' "$root/samples-v1.ndjson" >/dev/null || die 'Gate 15 final sample chain or trusted coverage fields are incomplete.' 74
  /usr/bin/jq -e --argjson expected "$sample_count" '
    .schema == "hostwright.phase09.gate15.runner-state.v1" and (.status == "finalizing" or .status == "pre-pass")
    and .sampleCount == $expected and (.runStartedDigest | type == "string" and test("^[a-f0-9]{64}$"))
    and (.finalLedgerDigest | type == "string" and test("^[a-f0-9]{64}$"))
    and (.toolPath == "/Users/dev/Documents/hostwright-phase09/.build/release/HostwrightPhase09QualificationTool")
  ' "$root/runner-state-v1.json" >/dev/null || die 'Gate 15 final runner state is missing or not bound to the canonical tool.' 74
}

validate_staged_checksum_manifest() {
  local manifest_tmp="$1" checksum_tmp="$2" expected actual name
  /usr/bin/awk 'NF != 2 || $1 !~ /^[a-f0-9]{64}$/ || $2 !~ /^[A-Za-z0-9._/-]+$/ || $2 ~ /(^|\/)\.\.($|\/)/ || $2 ~ /^\// || seen[$2]++ {bad=1} END {exit bad ? 1 : 0}' "$checksum_tmp" \
    || die 'Gate 15 staged checksum manifest is invalid or ambiguous.' 74
  while read -r expected name; do
    if [[ "$name" == manifest-v1.json ]]; then
      actual="$(sha "$manifest_tmp")"
    else
      require_private_file "$root/$name" 'Gate 15 staged checksummed artifact'
      actual="$(sha "$root/$name")"
    fi
    [[ "$actual" == "$expected" ]] || die 'Gate 15 staged checksum manifest does not match the exact final evidence.' 74
  done < "$checksum_tmp"
  require_checksum_entry "$checksum_tmp" manifest-v1.json
}

validate_consumed_launch_authorization() {
  local authorization="$root/launch-authorization-v1.consumed.cms" original="$root/launch-authorization-v1.cms"
  local before after
  require_private_file "$authorization" 'Gate 15 consumed launch authorization'
  assert_absent "$original" || die 'Gate 15 one-time launch authorization was not consumed.' 74
  [[ "$HOSTWRIGHT_GATE15_LAUNCH_AUTHORIZATION" == "$authorization" ]] \
    || die 'Gate 15 consumed launch authorization binding is not canonical.' 74
  export HOSTWRIGHT_GATE15_SOURCE_COMMIT="$source_commit"
  export HOSTWRIGHT_GATE15_SOURCE_DIGEST="$source_digest_value"
  export HOSTWRIGHT_GATE15_CONFIG_DIGEST="$config_digest_value"
  export HOSTWRIGHT_GATE15_TOOLCHAIN_DIGEST="$toolchain_digest_value"
  export HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE_DIGEST="$dependency_digest_value"
  export HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST="$pinset_digest_value"
  export HOSTWRIGHT_GATE15_SIGNING_IDENTITY="$signing_identity"
  export HOSTWRIGHT_GATE15_SIGNING_FINGERPRINT="$signing_fingerprint"
  export HOSTWRIGHT_GATE15_CERTIFICATE_FINGERPRINT="$signing_certificate_fingerprint"
  export HOSTWRIGHT_GATE15_TEAM_ID="$signing_team_id"
  before="$(/usr/bin/stat -f '%d:%i:%l:%Lp' "$authorization")|$(sha "$authorization")"
  HOSTWRIGHT_GATE15_TOOL="$canonical_tool_path" \
  HOSTWRIGHT_GATE15_LAUNCH_AUTHORIZATION="$authorization" \
  "$canonical_tool_path" status --root "$root" >/dev/null \
    || die 'Gate 15 consumed launch authorization failed immediate formal revalidation.' 74
  after="$(/usr/bin/stat -f '%d:%i:%l:%Lp' "$authorization")|$(sha "$authorization")"
  [[ "$before" == "$after" ]] || die 'Gate 15 consumed launch authorization changed during final revalidation.' 74
  assert_absent "$original" || die 'Gate 15 one-time launch authorization was recreated.' 74
}

verify_staged_cms_bundle() {
  local checksum_tmp="$1" cms_tmp="$2" decoded_tmp output_directory signer_cert openssl_decoded
  private_file "$cms_tmp" || die 'Gate 15 staged CMS evidence is not private.' 74
  /usr/bin/security cms -V -N "$signing_identity" -u 9 -i "$cms_tmp" >/dev/null 2>&1 \
    || die 'Gate 15 staged CMS evidence failed pinned verification.' 74
  decoded_tmp="$(/usr/bin/security cms -D -N "$signing_identity" -u 9 -i "$cms_tmp" -o /dev/stdout 2>/dev/null | write_private_temp_from_stdin staged-cms-decoded)" \
    || die 'Gate 15 staged CMS evidence could not be decoded.' 74
  output_directory="$(make_private_temp_directory staged-cms-openssl)"
  signer_cert="$output_directory/signer.der"
  openssl_decoded="$output_directory/payload.bin"
  verify_actual_cms_signer "$cms_tmp" "$openssl_decoded" "$signer_cert"
  /bin/unlink "$openssl_decoded"; /bin/unlink "$signer_cert"; /bin/rmdir "$output_directory"
  /usr/bin/cmp -s "$checksum_tmp" "$decoded_tmp" || die 'Gate 15 staged CMS evidence did not round-trip.' 74
  /bin/unlink "$decoded_tmp"
}

write_evidence_digest() {
  local completed_at="$1" file cell
  testing && die 'test mode cannot seal formal CMS evidence.' 70
  validate_final_evidence
  sealed_manifest_tmp="$(/usr/bin/jq --arg completed "$completed_at" \
    '.status="passed"|.claim="formal"|.formal=true|.completedAt=$completed' \
    "$root/manifest-v1.json" | write_private_temp_from_stdin manifest-passed)" \
    || die 'Gate 15 passed manifest could not be written exclusively.' 124
  sealed_digest_tmp="$({
    printf '%s  manifest-v1.json\n' "$(sha "$sealed_manifest_tmp")"
    for file in dependency-evidence-v1.json state-v1.tsv ownership-v1.tsv owned-runtime-v1.tsv toolchain-v1.txt \
      signed-executables-v1.tsv fault-schedule-v1.tsv runtime-inventory-before-v1.json runtime-inventory-after-v1.json \
      gate-active-run-v1-info.tsv run-attempt-v1.json run-started-v1.json samples-v1.ndjson \
      launch-request-v1.json launch-authorization-v1.consumed.cms; do
      printf '%s  %s\n' "$(sha "$root/$file")" "$file"
    done
    for cell in 1 2 3 4 5 6; do
      for file in "$root/cell-$(printf '%02d' "$cell").stdout.log" "$root/cell-$(printf '%02d' "$cell").stderr.log"; do
        printf '%s  %s\n' "$(sha "$file")" "${file#"$root/"}"
      done
    done
  } | LC_ALL=C /usr/bin/sort | write_private_temp_from_stdin evidence-digest)" \
    || die 'Gate 15 checksum evidence could not be written exclusively.' 124
  export HOSTWRIGHT_GATE15_LAUNCH_AUTHORIZATION="$root/launch-authorization-v1.consumed.cms"
  validate_consumed_launch_authorization
  sealed_cms_tmp="$(/usr/bin/security cms -S -N "$signing_identity" -H SHA256 -u 9 -i "$sealed_digest_tmp" -o /dev/stdout 2>/dev/null | write_private_temp_from_stdin evidence-cms)" \
    || die 'Gate 15 evidence CMS signing failed.' 74
  validate_staged_checksum_manifest "$sealed_manifest_tmp" "$sealed_digest_tmp"
  verify_staged_cms_bundle "$sealed_digest_tmp" "$sealed_cms_tmp"
}

publish_sealed_evidence() {
  pass_publication_started=1
  [[ -n "$sealed_manifest_tmp" && -n "$sealed_digest_tmp" && -n "$sealed_cms_tmp" ]] \
    || die 'Gate 15 final evidence seal is incomplete.' 124
  assert_absent "$root/evidence-v1.sha256" || die 'Gate 15 checksum evidence already exists; preserve the root.' 124
  assert_absent "$root/evidence-v1.cms" || die 'Gate 15 CMS evidence already exists; preserve the root.' 124
  publish_temp_absent "$sealed_digest_tmp" "$root/evidence-v1.sha256" 'Gate 15 checksum evidence'
  sealed_digest_tmp=''
  publish_temp_absent "$sealed_cms_tmp" "$root/evidence-v1.cms" 'Gate 15 CMS evidence'
  sealed_cms_tmp=''
  [[ ! -L "$root/manifest-v1.json" ]] || die 'Gate 15 manifest became a symlink during final publication.' 124
  local manifest_input="$sealed_manifest_tmp"
  /bin/cat "$manifest_input" | replace_private "$root/manifest-v1.json" 'Gate 15 passed manifest' manifest-published
  /bin/unlink "$manifest_input"
  sealed_manifest_tmp=''
  local evidence_digest evidence_cms_digest
  evidence_digest="$(sha "$root/evidence-v1.sha256")"
  evidence_cms_digest="$(sha "$root/evidence-v1.cms")"
  require_private_file "$root/runner-state-v1.json" 'Gate 15 pre-pass runner state'
  /usr/bin/jq --arg completed "$(now)" --arg evidence "$evidence_digest" --arg cms "$evidence_cms_digest" \
    '.status="passed"|.claim="formal"|.formal=true|.evidenceDigest=$evidence|.evidenceCMSDigest=$cms|.completedAt=$completed' \
    "$root/runner-state-v1.json" | replace_private "$root/runner-state-v1.json" 'Gate 15 passed runner state' runner-state-passed
  /usr/bin/jq -e --argjson expected "$sample_count" --arg ledger "$(sha "$root/samples-v1.ndjson")" \
    '(.status == "passed" and .claim == "formal" and .formal == true and .sampleCount == $expected and .finalLedgerDigest == $ledger and .evidenceDigest != "" and .evidenceCMSDigest != "")' \
    "$root/runner-state-v1.json" >/dev/null || die 'Gate 15 passed runner state was not atomically bound to the final ledger and CMS seal.' 124
  /usr/bin/jq -e '.status == "passed" and .claim == "formal" and .formal == true' "$root/manifest-v1.json" >/dev/null \
    || die 'Gate 15 passed manifest was not atomically bound after CMS seal.' 124
  final_state_exposed=1
}

verify_reuse() {
  private_file "$root/evidence-v1.sha256" && private_file "$root/evidence-v1.cms" || return 1
  if testing; then return 1; fi
  validate_complete_sample_ledger reuse || return 1
  validate_consumed_launch_authorization || return 1
  validate_checksum_manifest "$root" "$root/evidence-v1.sha256" || return 1
  verify_cms_bundle "$root" "$root/evidence-v1.sha256" "$root/evidence-v1.cms" || return 1
}

cleanup_owned() {
  [[ -f "$root/ownership-v1.tsv" ]] || return 0
  require_private_file "$root/ownership-v1.tsv" 'Gate 15 ownership ledger'
  [[ "$(/usr/bin/head -n 1 "$root/ownership-v1.tsv")" == "$ownership_header" ]] \
    || die 'Gate 15 ownership ledger header is invalid.' 124
  /usr/bin/awk -F $'\t' 'NR == 1 {next} NF != 7 || $1 == "" || $2 != "temporary-root" || $3 == "" || $4 == "" || $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/ || $7 != "owned=gate15" || seen[$4]++ {bad=1} END {exit bad ? 1 : 0}' "$root/ownership-v1.tsv" \
    || die 'Gate 15 ownership ledger contains a malformed, foreign, or ambiguous row.' 124
  local recorded type identifier path device inode identity
  while IFS=$'\t' read -r recorded type identifier path device inode identity; do
    [[ "$recorded" == recorded_at ]] && continue
    [[ "$recorded" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z$ \
      && "$type" == temporary-root && "$identity" == owned=gate15 \
      && "$path" == "$root"/* && "$(/bin/realpath "$path")" == "$path" \
      && -d "$path" && ! -L "$path" \
      && "$(/usr/bin/stat -f '%d' "$path")" == "$device" && "$(/usr/bin/stat -f '%i' "$path")" == "$inode" ]] \
      || die 'Gate 15 owned resource identity changed; cleanup is refused.' 124
    [[ -z "$(/usr/bin/find "$path" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
      || die 'Gate 15 owned resource is not empty; cleanup is frozen.' 124
    /bin/rmdir "$path" || die 'Gate 15 owned resource could not be removed exactly.' 124
  done < "$root/ownership-v1.tsv"
}

validate_lock_info_identity() {
  local path="$1" expected_path="$2" expected_device="$3" expected_inode="$4" marker="$root/run-started-v1.json"
  local marker_pid marker_start started_at expected_row
  [[ "$path" == "$expected_path" && "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\t'* ]] \
    || die 'Gate 15 lock info path is not the exact owned path.' 124
  require_private_file "$path" 'Gate 15 lock info file'
  [[ "$(/usr/bin/stat -f '%d' "$path")" == "$expected_device" \
    && "$(/usr/bin/stat -f '%i' "$path")" == "$expected_inode" \
    && "$(/usr/bin/stat -f '%Lp' "$path")" == 600 ]] \
    || die 'Gate 15 lock info device, inode, or mode changed during release.' 124
  marker_pid="$(/usr/bin/jq -r '.runnerPID' "$marker")"
  marker_start="$(/usr/bin/jq -r '.runnerStartIdentity' "$marker")"
  started_at="$(/usr/bin/jq -r '.startedAtUTC' "$marker")"
  expected_row="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$root" "$marker_pid" "$marker_start" "$started_at" "$source_commit" "$source_digest_value" \
    "$config_digest_value" "$toolchain_digest_value" "$dependency_digest_value" "$pinset_digest_value" \
    "$(/usr/bin/jq -r '.manifestDigest' "$marker")")"
  {
    printf '%s\n' "$lock_info_header"
    printf '%s\n' "$expected_row"
  } | /usr/bin/cmp -s - "$path" || die 'Gate 15 lock info content identity changed during release.' 124
}

release_locks() {
  [[ "$root_lock_created" == 1 && "$gate_lock_created" == 1 ]] || return 0
  [[ "$final_state_exposed" == 1 ]] || die 'Gate 15 locks remain held until the atomic passed state is exposed.' 124
  local marker="$root/run-started-v1.json"
  local gate_lock="$parent/.phase09-gate15-active-v1"
  local gate_info="$gate_lock/info-v1.tsv"
  local root_info="$root/gate-active-run-v1-info.tsv"
  require_private_file "$marker" 'Gate 15 run-started marker for lock release'
  [[ "$(/usr/bin/jq -r '.rootLockPath' "$marker")" == "$root/active-run-v1" \
    && "$(/usr/bin/jq -r '.gateLockPath' "$marker")" == "$gate_lock" \
    && "$(/usr/bin/jq -r '.gateLockInfoPath' "$marker")" == "$gate_info" ]] \
    || die 'Gate 15 lock release is not bound to the exact signed lock paths.' 124
  private_directory "$root/active-run-v1" || die 'Gate 15 root lock changed during release.' 124
  private_directory "$gate_lock" || die 'Gate 15 gate lock changed during release.' 124
  [[ "$(/usr/bin/stat -f '%d' "$root/active-run-v1")" == "$(/usr/bin/jq -r '.rootLockDevice' "$marker")" \
    && "$(/usr/bin/stat -f '%i' "$root/active-run-v1")" == "$(/usr/bin/jq -r '.rootLockInode' "$marker")" \
    && "$(/usr/bin/stat -f '%d' "$gate_lock")" == "$(/usr/bin/jq -r '.gateLockDevice' "$marker")" \
    && "$(/usr/bin/stat -f '%i' "$gate_lock")" == "$(/usr/bin/jq -r '.gateLockInode' "$marker")" ]] \
    || die 'Gate 15 lock device or inode changed during release.' 124
  validate_lock_info_identity "$gate_info" "$gate_info" \
    "$(/usr/bin/jq -r '.gateLockInfoDevice' "$marker")" "$(/usr/bin/jq -r '.gateLockInfoInode' "$marker")"
  validate_lock_info_identity "$root_info" "$root_info" \
    "$(/usr/bin/stat -f '%d' "$root_info")" "$(/usr/bin/stat -f '%i' "$root_info")"
  /bin/unlink "$gate_info" || die 'Gate 15 owned gate-lock info file could not be removed exactly.' 124
  assert_absent "$gate_info" || die 'Gate 15 gate-lock info file remained after exact removal.' 124
  /bin/rmdir "$gate_lock" || die 'Gate 15 gate lock could not be removed after exact info removal.' 124
  /bin/rmdir "$root/active-run-v1" || die 'Gate 15 root lock could not be removed after exact info removal.' 124
  assert_absent "$gate_lock" || die 'Gate 15 gate lock remained after release.' 124
  assert_absent "$root/active-run-v1" || die 'Gate 15 root lock remained after release.' 124
  root_lock_created=0
  gate_lock_created=0
  locks_released=1
}

validate_active_locks() {
  [[ -d "$root/active-run-v1" && ! -L "$root/active-run-v1" \
    && "$(/bin/realpath "$root/active-run-v1")" == "$root/active-run-v1" \
    && "$(/usr/bin/stat -f '%u' "$root/active-run-v1")" == "$user_id" && "$(/usr/bin/stat -f '%Lp' "$root/active-run-v1")" == 700 ]] \
    || die 'Gate 15 status requires the exact active root lock.' 75
  [[ -d "$parent/.phase09-gate15-active-v1" && ! -L "$parent/.phase09-gate15-active-v1" \
    && "$(/bin/realpath "$parent/.phase09-gate15-active-v1")" == "$parent/.phase09-gate15-active-v1" \
    && "$(/usr/bin/stat -f '%u' "$parent/.phase09-gate15-active-v1")" == "$user_id" \
    && "$(/usr/bin/stat -f '%Lp' "$parent/.phase09-gate15-active-v1")" == 700 ]] \
    || die 'Gate 15 status requires the exact active gate lock.' 75
}

write_run_attempt() {
  local attempt="$root/run-attempt-v1.json"
  assert_absent "$attempt" || die 'Gate 15 run-attempt evidence already exists; preserve and freeze the root.' 73
  /usr/bin/jq -n \
    --arg schema 'hostwright.phase09.gate15.run-attempt.v1' --arg rootPath "$root" \
    --arg sourceCommit "$source_commit" --arg sourceDigest "$source_digest_value" \
    --arg configDigest "$config_digest_value" --arg toolchainDigest "$toolchain_digest_value" \
    --arg dependencyDigest "$dependency_digest_value" --arg pinsetDigest "$pinset_digest_value" \
    --arg toolPath "$tool_path_value" --arg toolDigest "$tool_digest_value" \
    --arg toolBuildIdentity "$tool_build_identity_value" --arg startedAtUTC "$(now)" \
    '{schema:$schema,root:$rootPath,status:"started",sourceCommit:$sourceCommit,sourceDigest:$sourceDigest,
      configDigest:$configDigest,toolchainDigest:$toolchainDigest,dependencyEvidenceDigest:$dependencyDigest,
      executablePinsetDigest:$pinsetDigest,toolPath:$toolPath,toolDigest:$toolDigest,
      toolBuildIdentity:$toolBuildIdentity,startedAtUTC:$startedAtUTC}' \
    | write_private "$attempt" 'Gate 15 durable run-attempt marker' run-attempt
}

freeze_interrupted_root() {
  local manifest_status_value=''
  if assert_absent "$root/failure-v1.tsv"; then
    failure 0 "${1:-70}" 'Gate 15 interrupted before final evidence publication' '-' '-'
  fi
  if [[ -f "$root/manifest-v1.json" && ! -L "$root/manifest-v1.json" ]]; then
    manifest_status_value="$(/usr/bin/jq -r '.status // empty' "$root/manifest-v1.json" 2>/dev/null || true)"
    if [[ "$manifest_status_value" != failed ]]; then
      manifest_status failed "$(now)"
    fi
  fi
  if [[ -f "$root/runner-state-v1.json" && ! -L "$root/runner-state-v1.json" ]]; then
    require_private_file "$root/runner-state-v1.json" 'Gate 15 interrupted runner state'
    /usr/bin/jq --arg failedAt "$(now)" \
      '.status="failed"|.claim="none"|.formal=false|.failureAt=$failedAt' "$root/runner-state-v1.json" \
      | replace_private "$root/runner-state-v1.json" 'Gate 15 interrupted runner state' runner-state-failed
  fi
  if [[ -f "$root/ownership-v1.tsv" && ! -L "$root/ownership-v1.tsv" ]]; then
    cleanup_owned || true
  fi
}

on_signal() {
  local signal="$1" status="$2"
  trap - INT TERM HUP EXIT
  terminate_and_wait_qualification_child
  if [[ "$trap_armed" == 1 && "$final_state_exposed" == 0 && "$pass_publication_started" == 0 && -d "$root" ]]; then
    freeze_interrupted_root "$status" || status=$?
  fi
  exit "$status"
}

on_exit() {
  local status=$?
  trap - INT TERM HUP EXIT
  terminate_and_wait_qualification_child
  if [[ "$status" != 0 ]]; then
    if [[ "$trap_armed" == 1 && "$final_state_exposed" == 0 && "$pass_publication_started" == 0 && -d "$root" ]]; then
      freeze_interrupted_root "$status" || status=$?
    fi
    exit "$status"
  fi
  if [[ "$trap_armed" == 1 && "$final_state_exposed" == 0 && "$pass_publication_started" == 0 ]]; then
    freeze_interrupted_root 70
    exit 70
  fi
  exit 0
}

run_qualification() {
  arm_traps
  prepared
  if [[ -e "$root/evidence-v1.sha256" || -e "$root/evidence-v1.cms" ]]; then
    export HOSTWRIGHT_GATE15_LAUNCH_AUTHORIZATION="$root/launch-authorization-v1.consumed.cms"
    verify_reuse || die 'completed evidence is incomplete or changed; preserve this root and do not rerun.' 73
    disarm_traps
    printf '%s\n' 'Gate 15 evidence is valid and reused; no cells were rerun.'
    return 0
  fi
  write_run_attempt
  validate_live_boundary
  local lock="$parent/.phase09-gate15-active-v1"
  [[ ! -e "$lock" && ! -e "$root/active-run-v1" ]] || die 'An active Gate 15 qualification already exists; do not duplicate it.' 75
  /bin/mkdir "$lock"; /bin/chmod 700 "$lock"; gate_lock_created=1
  printf '%s\n%s\n' \
    "$lock_info_header" \
    "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$root" 0 pending "$(now)" "$source_commit" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" "$dependency_digest_value" "$pinset_digest_value" "$(sha "$root/manifest-v1.json")")" \
    | write_private "$lock/info-v1.tsv" 'Gate 15 active gate lock info' lock-info
  /bin/mkdir "$root/active-run-v1"; /bin/chmod 700 "$root/active-run-v1"; root_lock_created=1
  /bin/cat "$lock/info-v1.tsv" | write_private "$root/gate-active-run-v1-info.tsv" 'Gate 15 active-run info' active-info
  export HOSTWRIGHT_GATE15_ROOT="$root"
  export HOSTWRIGHT_GATE15_SOURCE_COMMIT="$source_commit"
  export HOSTWRIGHT_GATE15_SOURCE_DIGEST="$source_digest_value"
  export HOSTWRIGHT_GATE15_CONFIG_DIGEST="$config_digest_value"
  export HOSTWRIGHT_GATE15_TOOLCHAIN_DIGEST="$toolchain_digest_value"
  export HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE_DIGEST="$dependency_digest_value"
  export HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST="$pinset_digest_value"
  export HOSTWRIGHT_GATE15_MANIFEST_DIGEST="$(sha "$root/manifest-v1.json")"
  export HOSTWRIGHT_GATE15_SIGNING_IDENTITY="$signing_identity"
  export HOSTWRIGHT_GATE15_SIGNING_FINGERPRINT="$signing_fingerprint"
  export HOSTWRIGHT_GATE15_CERTIFICATE_FINGERPRINT="$signing_certificate_fingerprint"
  export HOSTWRIGHT_GATE15_TEAM_ID="$signing_team_id"
  export HOSTWRIGHT_GATE15_LAUNCH_AUTHORIZATION="$root/launch-authorization-v1.cms"
  export HOSTWRIGHT_GATE15_LAUNCH_REQUEST="$root/launch-request-v1.json"
  export HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR="$canonical_dependency_validator_path"
  export HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR="$canonical_boundary_validator_path"
  local cell command out err out_tmp err_tmp started ended status
  for cell in 1 2 3 4 5 6; do
    revalidate_dependencies
    if [[ "$cell" == 3 ]]; then
      create_run_started
      export HOSTWRIGHT_GATE15_RUN_STARTED="$root/run-started-v1.json"
    fi
    command="$(cell_command "$cell")"
    out="$root/cell-$(printf '%02d' "$cell").stdout.log"
    err="$root/cell-$(printf '%02d' "$cell").stderr.log"
    [[ ! -e "$out" && ! -e "$err" ]] || die 'Cell logs already exist; preserve this root and do not rerun.' 73
    started="$(now)"
    capture_cell "$cell"
    status="$capture_status"
    out_tmp="$capture_out_tmp"
    err_tmp="$capture_err_tmp"
    publish_temp_absent "$out_tmp" "$out" 'Gate 15 cell stdout'
    publish_temp_absent "$err_tmp" "$err" 'Gate 15 cell stderr'
    private_file "$out" && private_file "$err" || die 'Gate 15 cell logs failed private identity validation.' 124
    ended="$(now)"
    if [[ "$status" != 0 ]]; then
      state "$cell" failed "$started" "$ended" "$(sha "$out")" "$(sha "$err")"
      failure "$cell" "$status" "$command" "$(sha "$out")" "$(sha "$err")"
      manifest_status failed "$ended"
      die "Gate 15 cell $cell failed; progress is frozen and locks are preserved." "$status"
    fi
    revalidate_dependencies
    state "$cell" pass "$started" "$ended" "$(sha "$out")" "$(sha "$err")"
  done
  cleanup_owned
  write_evidence_digest "$(now)"
  publish_sealed_evidence
  release_locks
  run_succeeded=1
  printf '%s\n' 'Gate 15 qualification passed.'
}

status() {
  validate_worktree
  validate_root
  export HOSTWRIGHT_GATE15_TOOL="${HOSTWRIGHT_GATE15_TOOL:-$canonical_tool_path}"
  local state="$root/state-v1.tsv"
  require_private_file "$state" 'Gate 15 status ledger'
  if testing; then
    /usr/bin/jq -c -n --arg root "$(/usr/bin/basename "$root")" \
      '{claim:"none",gate:15,status:"read-only",formal:false,readOnly:true,root:$root}'
    return 0
  fi
  collect 1
  prepared
  [[ "${HOSTWRIGHT_GATE15_TOOL:-}" == "$canonical_tool_path" ]] || die 'Gate 15 status requires the canonical built qualification tool.' 74
  require_executable "$canonical_tool_path" 'HostwrightPhase09QualificationTool artifact'
  export HOSTWRIGHT_GATE15_SOURCE_COMMIT="$source_commit"
  export HOSTWRIGHT_GATE15_SOURCE_DIGEST="$source_digest_value"
  export HOSTWRIGHT_GATE15_CONFIG_DIGEST="$config_digest_value"
  export HOSTWRIGHT_GATE15_TOOLCHAIN_DIGEST="$toolchain_digest_value"
  export HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE_DIGEST="$dependency_digest_value"
  export HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST="$pinset_digest_value"
  export HOSTWRIGHT_GATE15_MANIFEST_DIGEST="$(sha "$root/manifest-v1.json")"
  export HOSTWRIGHT_GATE15_LAUNCH_AUTHORIZATION="$root/launch-authorization-v1.consumed.cms"
  export HOSTWRIGHT_GATE15_SIGNING_IDENTITY="$signing_identity"
  export HOSTWRIGHT_GATE15_SIGNING_FINGERPRINT="$signing_fingerprint"
  export HOSTWRIGHT_GATE15_CERTIFICATE_FINGERPRINT="$signing_certificate_fingerprint"
  export HOSTWRIGHT_GATE15_TEAM_ID="$signing_team_id"
  "$canonical_tool_path" status --root "$root"
}

main() {
  [[ "$#" -ge 1 ]] || die 'usage: phase09-gate15-qualification.sh contract|diagnose|prepare 15|run 15|status 15.' 64
  case "$1" in
    contract) [[ "$#" == 1 ]] || die 'contract accepts no arguments.' 64; contract ;;
    diagnose) [[ "$#" == 1 ]] || die 'diagnose accepts no arguments.' 64; diagnose ;;
    prepare)
      [[ "$#" == 2 && "$2" == 15 ]] || die 'Gate 15 harness accepts only prepare 15.' 64
      validate_worktree; validate_root; arm_traps; empty_root
      [[ ! -e "$parent/.phase09-gate15-active-v1" ]] || die 'An active Gate 15 qualification already exists; do not duplicate it.' 75
      export HOSTWRIGHT_GATE15_TOOL="${HOSTWRIGHT_GATE15_TOOL:-$canonical_tool_path}"
      collect; prepare_manifest; validate_live_boundary
      disarm_traps
      printf '%s\n' 'Gate 15 evidence root prepared.' ;;
    run)
      [[ "$#" == 2 && "$2" == 15 ]] || die 'Gate 15 harness accepts only run 15.' 64
      export HOSTWRIGHT_GATE15_TOOL="${HOSTWRIGHT_GATE15_TOOL:-$canonical_tool_path}"
      validate_worktree; validate_root; arm_traps; reject_frozen_root; collect; run_qualification ;;
    revalidate-sample)
      [[ "$#" == 3 && "$2" == --root ]] || die 'usage: phase09-gate15-qualification.sh revalidate-sample --root PATH.' 64
      export HOSTWRIGHT_PHASE09_GATE_ROOT="$3"
      validate_worktree; validate_root; require_private_file "$root/manifest-v1.json" 'Gate 15 manifest'; revalidate_bound_inputs ;;
    status)
      [[ "$#" == 2 && "$2" == 15 ]] || die 'Gate 15 harness accepts only status 15.' 64
      status ;;
    __run-cell)
      [[ "$#" == 2 && "$2" =~ ^[1-6]$ ]] || die 'Gate 15 internal cell runner request is invalid.' 64
      run_cell "$2" ;;
    *) die 'unknown qualification command.' 64 ;;
  esac
}

main "$@"
