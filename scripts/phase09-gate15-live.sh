#!/usr/bin/env bash
set -euo pipefail

readonly repository_path='/Users/dev/Documents/hostwright-phase09'
readonly live_parent='/Volumes/T9/hostwright/qualification'
readonly canonical_dependency_validator_path='/Users/dev/Documents/hostwright-phase09/scripts/phase09-gate15-qualification.sh'
readonly canonical_boundary_validator_path='/Users/dev/Documents/hostwright-phase09/scripts/phase09-gate15-live.sh'
readonly canonical_tool_path='/Users/dev/Documents/hostwright-phase09/.build/release/HostwrightPhase09QualificationTool'
readonly formal_path='/usr/bin:/bin:/usr/sbin:/sbin'
readonly root_pattern='^phase09-gate15-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
readonly user_id="$(/usr/bin/id -u)"
readonly system_container='/usr/local/bin/container'
readonly expected_signing_identity='Developer ID Application: Dev Trivedi (993YC3JY4Q)'
readonly expected_signing_fingerprint='A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB'
readonly expected_certificate_fingerprint='A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB'
readonly expected_signing_team='993YC3JY4Q'
readonly ownership_header=$'recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity'
readonly run_started_schema='hostwright.phase09.gate15.run-started.v1'
readonly lock_info_header=$'root\tpid\trunner_start_identity\tstarted_at\tsource_commit\tsource_digest\tconfig_digest\ttoolchain_digest\tdependency_digest\tpinset_digest\tmanifest_digest'

export PATH="$formal_path"

root=''
cleanup_attempted=0
live_tool_pid=0
live_authorizer_pid=0
signing_identity=''
signing_fingerprint=''
signing_certificate_fingerprint=''
signing_team_id=''
dependency_validator_digest=''
dependency_validator_device=''
dependency_validator_inode=''
boundary_validator_digest=''
boundary_validator_device=''
boundary_validator_inode=''
pinset_path=''
pinset_device=''
pinset_inode=''
tool_device=''
tool_inode=''
tool_mode=''
tool_digest=''
tool_build_identity=''
observation_provider_path=''
observation_provider_device=''
observation_provider_inode=''
observation_provider_digest=''
trusted_observation_provider_path=''
trusted_observation_provider_device=''
trusted_observation_provider_inode=''
trusted_observation_provider_digest=''
sleep_wake_provider_path=''
sleep_wake_provider_device=''
sleep_wake_provider_inode=''
sleep_wake_provider_digest=''

die() {
  printf '%s\n' "$1" >&2
  exit "${2:-70}"
}

now() { /bin/date -u '+%Y-%m-%dT%H:%M:%S.%3NZ'; }
sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
sha_executable() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
assert_absent() { [[ ! -e "$1" && ! -L "$1" ]]; }

tool_build_identity() {
  printf 'path=%s\nmode=%s\ndevice=%s\ninode=%s\ndigest=%s\nsourceCommit=%s\nsourceDigest=%s\nconfigDigest=%s\ntoolchainDigest=%s\n' \
    "$canonical_tool_path" "$tool_mode" "$tool_device" "$tool_inode" "$tool_digest" \
    "${HOSTWRIGHT_GATE15_SOURCE_COMMIT:-}" "${HOSTWRIGHT_GATE15_SOURCE_DIGEST:-}" \
    "${HOSTWRIGHT_GATE15_CONFIG_DIGEST:-}" "${HOSTWRIGHT_GATE15_TOOLCHAIN_DIGEST:-}" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

validate_script_boundary() {
  local invocation canonical
  invocation="${BASH_SOURCE[0]}"
  if [[ "$invocation" != /* ]]; then invocation="$PWD/$invocation"; fi
  [[ -f "$invocation" && ! -L "$invocation" ]] || die 'Gate 15 live boundary script crosses a symlink boundary.' 66
  canonical="$(/bin/realpath "$invocation")" || die 'Gate 15 live boundary script cannot be canonicalized.' 66
  [[ "$canonical" == "$repository_path/scripts/phase09-gate15-live.sh" ]] \
    || die 'Gate 15 live boundary script must be the canonical Phase 09 repository script.' 66
  cd "$repository_path"
}

private_file() {
  local path="$1"
  [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\t'* && -f "$path" && ! -L "$path" \
    && "$(/bin/realpath "$path")" == "$path" && "$(/usr/bin/stat -f '%u' "$path")" == "$user_id" \
    && "$(/usr/bin/stat -f '%Lp' "$path")" == 600 && "$(/usr/bin/stat -f '%l' "$path")" == 1 ]]
}

private_directory() {
  local path="$1"
  [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\t'* && -d "$path" && ! -L "$path" \
    && "$(/bin/realpath "$path")" == "$path" && "$(/usr/bin/stat -f '%u' "$path")" == "$user_id" \
    && "$(/usr/bin/stat -f '%Lp' "$path")" == 700 ]]
}

require_private_file() {
  local path="$1" label="$2"
  private_file "$path" || die "$label must be canonical, current-user-owned, mode 0600, and non-symlinked." 66
}

make_private_temp() {
  local prefix="$1" temporary
  temporary="$(/usr/bin/python3 -c '
import os, secrets, sys
root, prefix = sys.argv[1:]
for _ in range(64):
    path = os.path.join(root, ".gate15-live-" + prefix + "." + secrets.token_hex(12))
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        continue
    os.close(descriptor)
    print(path)
    raise SystemExit(0)
raise SystemExit(73)
' "$root" "$prefix")" || die 'Gate 15 live boundary could not create an exclusive private temporary.' 73
  private_file "$temporary" || die 'Gate 15 live temporary failed private identity validation.' 73
  printf '%s\n' "$temporary"
}

write_private_temp_from_stdin() {
  local prefix="$1"
  local directory="${2:-$root}"
  private_directory "$directory" || die 'Gate 15 live publication destination directory is not private and canonical.' 124
  /usr/bin/python3 -c '
import os, secrets, sys
root, prefix = sys.argv[1:]
for _ in range(64):
    path = os.path.join(root, ".gate15-live-" + prefix + "." + secrets.token_hex(12))
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
    path = os.path.join(root, ".gate15-live-dir-" + prefix + "." + secrets.token_hex(12))
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        continue
    print(path)
    raise SystemExit(0)
raise SystemExit(73)
' "$root" "$prefix")" || die 'Gate 15 live private temporary directory could not be created.' 73
  private_directory "$path" || die 'Gate 15 live private temporary directory failed identity validation.' 73
  printf '%s\n' "$path"
}

write_private() {
  local destination="$1" label="$2" prefix="$3" temporary destination_directory
  destination_directory="$(/usr/bin/dirname "$destination")"
  temporary="$(write_private_temp_from_stdin "$prefix" "$destination_directory")" \
    || die "$label could not be written by the exclusive private writer." 124
  private_file "$temporary" || die "$label temporary failed private identity validation." 73
  publish_temp_absent "$temporary" "$destination" "$label"
}

atomic_rename_exclusive() {
  local temporary="$1" destination="$2"
  /usr/bin/python3 - "$temporary" "$destination" <<'PY'
import ctypes
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

replace_private() {
  local destination="$1" label="$2" prefix="$3" temporary destination_directory temporary_device temporary_inode
  destination_directory="$(/usr/bin/dirname "$destination")"
  temporary="$(write_private_temp_from_stdin "$prefix" "$destination_directory")" \
    || die "$label could not be written by the exclusive private writer." 124
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

publish_temp_absent() {
  local temporary="$1" destination="$2" label="$3" temporary_device temporary_inode destination_directory
  private_file "$temporary" || die "$label temporary failed private identity validation." 124
  destination_directory="$(/usr/bin/dirname "$destination")"
  [[ "$(/usr/bin/dirname "$temporary")" == "$destination_directory" ]] || die "$label temporary is not inside the destination directory." 124
  private_directory "$destination_directory" || die "$label destination directory failed private identity validation." 124
  temporary_device="$(/usr/bin/stat -f '%d' "$temporary")"
  temporary_inode="$(/usr/bin/stat -f '%i' "$temporary")"
  [[ "$(/usr/bin/stat -f '%l' "$temporary")" == 1 ]] || die "$label temporary has more than one hard link." 124
  assert_absent "$destination" || die "$label already exists or is a symlink." 124
  atomic_rename_exclusive "$temporary" "$destination" || die "$label could not be published with an exclusive same-directory atomic rename." 124
  private_file "$destination" || die "$label failed private publication validation." 124
  [[ "$(/usr/bin/stat -f '%d' "$destination")" == "$temporary_device" \
    && "$(/usr/bin/stat -f '%i' "$destination")" == "$temporary_inode" \
    && "$(/usr/bin/stat -f '%l' "$destination")" == 1 ]] || die "$label changed device, inode, or nlink during publication." 124
}

require_executable() {
  local path="$1" label="$2"
  [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\t'* && -f "$path" && ! -L "$path" \
    && "$(/bin/realpath "$path")" == "$path" && "$(/usr/bin/stat -f '%u' "$path")" == "$user_id" \
    && "$(/usr/bin/stat -f '%Lp' "$path")" == 755 && "$(/usr/bin/stat -f '%l' "$path")" == 1 && -x "$path" ]] \
    || die "$label must be one canonical current-user-owned mode-0755 executable with one hard link." 66
}

require_system_executable() {
  local path="$1" label="$2" owner
  owner="$(/usr/bin/stat -f '%u' "$path" 2>/dev/null || true)"
  [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\t'* && -f "$path" && ! -L "$path" \
    && "$(/bin/realpath "$path")" == "$path" && ("$owner" == 0 || "$owner" == "$user_id") \
    && "$(/usr/bin/stat -f '%l' "$path")" == 1 && -x "$path" ]] \
    || die "$label must be one canonical system executable with one hard link." 66
}

validate_root() {
  : "${HOSTWRIGHT_GATE15_ROOT:?HOSTWRIGHT_GATE15_ROOT is required}"
  root="$HOSTWRIGHT_GATE15_ROOT"
  [[ "$root" == /* && "$root" != / && "$root" != */ && "$root" != *$'\n'* && "$root" != *$'\t'* ]] \
    || die 'Gate 15 live root path is not canonical.' 66
  private_directory "$live_parent" || die 'Gate 15 live evidence requires the fixed private T9 parent.' 66
  [[ -d "$root" && ! -L "$root" && "$(/bin/realpath "$root")" == "$root" \
    && "$(/usr/bin/dirname "$root")" == "$live_parent" \
    && "$(/bin/realpath "$(/usr/bin/dirname "$root")")" == "$live_parent" ]] \
    || die 'Gate 15 live root must be a direct child of the fixed qualification parent.' 66
  [[ "$(/usr/bin/basename "$root")" =~ $root_pattern ]] || die 'Gate 15 live root has an invalid lowercase UUID name.' 66
  private_directory "$root" || die 'Gate 15 live root must be current-user-owned mode 0700.' 77
}

validate_system_container_pinset() {
  local pinset="$1" expected_sha expected_cdhash expected_team expected_identifier details cdhash team identifier
  expected_sha="$(/usr/bin/jq -r '.systemContainer.sha256' "$pinset")"
  expected_cdhash="$(/usr/bin/jq -r '.systemContainer.cdHash' "$pinset")"
  expected_team="$(/usr/bin/jq -r '.systemContainer.teamID' "$pinset")"
  expected_identifier="$(/usr/bin/jq -r '.systemContainer.identifier' "$pinset")"
  [[ "$expected_sha" =~ ^[a-f0-9]{64}$ && "$expected_cdhash" =~ ^[a-f0-9]{40}([a-f0-9]{24})?$ \
    && "$expected_team" =~ ^[A-Za-z0-9]{1,32}$ && "$expected_identifier" =~ ^[A-Za-z0-9._-]{1,128}$ ]] \
    || die 'the exact system container pinset entry is missing or malformed.' 69
  require_system_executable "$system_container" 'the system container command'
  [[ "$(sha_executable "$system_container")" == "$expected_sha" ]] || die 'the system container command changed from its pinset.' 69
  /usr/bin/codesign --verify --strict "$system_container" >/dev/null 2>&1 \
    || die 'the system container command failed strict code-signature verification.' 69
  details="$(/usr/bin/codesign -dvv "$system_container" 2>&1)"
  cdhash="$(printf '%s\n' "$details" | /usr/bin/awk -F= '$1=="CDHash"{print tolower($2); exit}')"
  team="$(printf '%s\n' "$details" | /usr/bin/awk -F= '$1=="TeamIdentifier"{print $2; exit}')"
  identifier="$(printf '%s\n' "$details" | /usr/bin/awk -F= '$1=="Identifier"{print $2; exit}')"
  [[ "$cdhash" == "$expected_cdhash" && "$team" == "$expected_team" && "$identifier" == "$expected_identifier" ]] \
    || die 'the system container command does not match its pinned CDHash, Team ID, or identifier.' 69
}

validate_pinned_signed_executables() {
  local pinset="${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET:-}" signed="${HOSTWRIGHT_GATE15_SIGNED_EXECUTABLES:-}"
  require_private_file "$pinset" 'HOSTWRIGHT_GATE15_EXECUTABLE_PINSET'
  /usr/bin/jq -e '
    (.schema == "hostwright.phase09.gate15.executable-pinset.v1" and (.executables | type == "array" and length > 0)
     and all(.executables[]; (.name | test("^[A-Za-z0-9._-]{1,128}$"))
       and (.sha256 | test("^[a-f0-9]{64}$"))
       and (.cdHash | test("^[a-f0-9]{40}([a-f0-9]{24})?$"))
       and (.teamID | test("^[A-Za-z0-9]{1,32}$"))
       and (.identifier | test("^[A-Za-z0-9._-]{1,128}$"))))
  ' "$pinset" >/dev/null || die 'the signed executable pinset is malformed.' 69
  validate_system_container_pinset "$pinset"
  [[ -n "$signed" ]] || die 'HOSTWRIGHT_GATE15_SIGNED_EXECUTABLES is required for live revalidation.' 69
  local -a entries=()
  IFS=':' read -r -a entries <<< "$signed"
  local expected_count path details cdhash team identifier digest expected_sha expected_cdhash expected_team expected_identifier
  expected_count="$(/usr/bin/jq -r '.executables | length' "$pinset")"
  [[ "$expected_count" == "${#entries[@]}" ]] || die 'the live signed executable list and pinset differ.' 69
  [[ -z "$(printf '%s\n' "${entries[@]}" | LC_ALL=C /usr/bin/sort | /usr/bin/uniq -d)" ]] || die 'the live signed executable list is ambiguous.' 69
  for path in "${entries[@]}"; do
    require_executable "$path" 'live signed qualification executable'
    /usr/bin/codesign --verify --strict "$path" >/dev/null 2>&1 \
      || die 'a live signed qualification executable failed strict verification.' 69
    details="$(/usr/bin/codesign -dvv "$path" 2>&1)"
    cdhash="$(printf '%s\n' "$details" | /usr/bin/awk -F= '$1=="CDHash"{print tolower($2); exit}')"
    team="$(printf '%s\n' "$details" | /usr/bin/awk -F= '$1=="TeamIdentifier"{print $2; exit}')"
    identifier="$(printf '%s\n' "$details" | /usr/bin/awk -F= '$1=="Identifier"{print $2; exit}')"
    expected_sha="$(/usr/bin/jq -r --arg name "${path##*/}" '[.executables[] | select(.name == $name)] | if length == 1 then .[0].sha256 else empty end' "$pinset")"
    expected_cdhash="$(/usr/bin/jq -r --arg name "${path##*/}" '[.executables[] | select(.name == $name)] | if length == 1 then .[0].cdHash else empty end' "$pinset")"
    expected_team="$(/usr/bin/jq -r --arg name "${path##*/}" '[.executables[] | select(.name == $name)] | if length == 1 then .[0].teamID else empty end' "$pinset")"
    expected_identifier="$(/usr/bin/jq -r --arg name "${path##*/}" '[.executables[] | select(.name == $name)] | if length == 1 then .[0].identifier else empty end' "$pinset")"
    digest="$(sha_executable "$path")"
    [[ -n "$expected_sha" && "$digest" == "$expected_sha" && "$cdhash" == "$expected_cdhash" \
      && "$team" == "$expected_team" && "$team" == "$signing_team_id" && "$identifier" == "$expected_identifier" ]] \
      || die 'a live signed qualification executable changed from its exact pinned identity.' 69
  done
}

validate_inputs() {
  local observation_identity trusted_identity sleep_identity tool_identity
  : "${HOSTWRIGHT_GATE15_TOOL:?HOSTWRIGHT_GATE15_TOOL is required}"
  : "${HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER:?HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER is required}"
  : "${HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER:?HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER is required}"
  : "${HOSTWRIGHT_GATE15_RUNTIME_SETUP:?HOSTWRIGHT_GATE15_RUNTIME_SETUP is required}"
  : "${HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER:?HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER is required}"
  : "${HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR:?HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR is required}"
  [[ "$HOSTWRIGHT_GATE15_TOOL" == "$canonical_tool_path" ]] || die 'Gate 15 continuity tool must be the canonical built HostwrightPhase09QualificationTool artifact.' 69
  require_executable "$canonical_tool_path" 'Gate 15 continuity tool'
  [[ "$(/usr/bin/stat -f '%Lp' "$canonical_tool_path")" == 755 ]] || die 'Gate 15 continuity tool must be mode 0755.' 69
  require_executable "$HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER" 'Gate 15 observation provider'
  require_executable "$HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER" 'Gate 15 trusted observation provider'
  require_executable "$HOSTWRIGHT_GATE15_RUNTIME_SETUP" 'Gate 15 runtime setup'
  require_executable "$HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER" 'Gate 15 sleep/wake provider'
  require_executable "$HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR" 'Gate 15 dependency validator'
  [[ "$HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR" == "$canonical_dependency_validator_path" ]] \
    || die 'Gate 15 formal runs may use only the canonical Gate 15 revalidate-sample harness.' 69
  [[ "${HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR:-}" == "$canonical_boundary_validator_path" ]] \
    || die 'Gate 15 formal runs may use only the canonical live boundary script.' 69
  [[ "${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET:-}" == /* ]] \
    || die 'HOSTWRIGHT_GATE15_EXECUTABLE_PINSET is required for exact per-sample pinset validation.' 69
  require_private_file "$HOSTWRIGHT_GATE15_EXECUTABLE_PINSET" 'HOSTWRIGHT_GATE15_EXECUTABLE_PINSET'
  [[ "$(/bin/realpath "$canonical_tool_path")" == "$canonical_tool_path" ]] || die 'the canonical qualification tool path is not canonical.' 69
  tool_device="$(/usr/bin/stat -f '%d' "$canonical_tool_path")"
  tool_inode="$(/usr/bin/stat -f '%i' "$canonical_tool_path")"
  tool_mode="$(/usr/bin/stat -f '%Lp' "$canonical_tool_path")"
  [[ "$tool_mode" == 755 ]] || die 'Gate 15 continuity tool must be mode 0755.' 69
  tool_mode="$((8#$tool_mode))"
  tool_digest="$(sha_executable "$canonical_tool_path")"
  [[ "$tool_device" == "${HOSTWRIGHT_GATE15_TOOL_DEVICE:-}" && "$tool_inode" == "${HOSTWRIGHT_GATE15_TOOL_INODE:-}" \
    && "$tool_mode" == "${HOSTWRIGHT_GATE15_TOOL_MODE:-}" && "$tool_digest" == "${HOSTWRIGHT_GATE15_TOOL_DIGEST:-}" \
    && "$(tool_build_identity)" == "${HOSTWRIGHT_GATE15_TOOL_BUILD_IDENTITY:-}" ]] \
    || die 'the canonical qualification tool path, mode, digest, or build/source identity is not bound to the prepared launch.' 69
  observation_provider_path="$(/bin/realpath "$HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER")"
  observation_provider_device="$(/usr/bin/stat -f '%d' "$HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER")"
  observation_provider_inode="$(/usr/bin/stat -f '%i' "$HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER")"
  observation_provider_digest="$(sha_executable "$HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER")"
  trusted_observation_provider_path="$(/bin/realpath "$HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER")"
  trusted_observation_provider_device="$(/usr/bin/stat -f '%d' "$HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER")"
  trusted_observation_provider_inode="$(/usr/bin/stat -f '%i' "$HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER")"
  trusted_observation_provider_digest="$(sha_executable "$HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER")"
  sleep_wake_provider_path="$(/bin/realpath "$HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER")"
  sleep_wake_provider_device="$(/usr/bin/stat -f '%d' "$HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER")"
  sleep_wake_provider_inode="$(/usr/bin/stat -f '%i' "$HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER")"
  sleep_wake_provider_digest="$(sha_executable "$HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER")"
  observation_identity="$observation_provider_path|$observation_provider_device|$observation_provider_inode|$observation_provider_digest"
  trusted_identity="$trusted_observation_provider_path|$trusted_observation_provider_device|$trusted_observation_provider_inode|$trusted_observation_provider_digest"
  sleep_identity="$sleep_wake_provider_path|$sleep_wake_provider_device|$sleep_wake_provider_inode|$sleep_wake_provider_digest"
  tool_identity="$canonical_tool_path|$tool_device|$tool_inode|$tool_digest"
  [[ "$observation_identity" != "$trusted_identity" \
    && "$observation_identity" != "$sleep_identity" \
    && "$trusted_identity" != "$sleep_identity" \
    && "$observation_identity" != "$tool_identity" \
    && "$trusted_identity" != "$tool_identity" \
    && "$sleep_identity" != "$tool_identity" ]] \
    || die 'Gate 15 provider and tool executable identities must be separately pinned.' 69
  [[ "$observation_provider_device" == "${HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER_DEVICE:-}" \
    && "$observation_provider_inode" == "${HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER_INODE:-}" \
    && "$observation_provider_digest" == "${HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER_DIGEST:-}" \
    && "$trusted_observation_provider_device" == "${HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER_DEVICE:-}" \
    && "$trusted_observation_provider_inode" == "${HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER_INODE:-}" \
    && "$trusted_observation_provider_digest" == "${HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER_DIGEST:-}" \
    && "$sleep_wake_provider_device" == "${HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER_DEVICE:-}" \
    && "$sleep_wake_provider_inode" == "${HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER_INODE:-}" \
    && "$sleep_wake_provider_digest" == "${HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER_DIGEST:-}" ]] \
    || die 'independent observation and sleep/wake executable identities changed from the signed launch.' 69
  pinset_path="$(/bin/realpath "$HOSTWRIGHT_GATE15_EXECUTABLE_PINSET")"
  pinset_device="$(/usr/bin/stat -f '%d' "$pinset_path")"
  pinset_inode="$(/usr/bin/stat -f '%i' "$pinset_path")"
  [[ "$(sha "$pinset_path")" == "${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST:-}" ]] \
    || die 'Gate 15 executable pinset changed before live launch.' 69
  dependency_validator_device="$(/usr/bin/stat -f '%d' "$HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR")"
  dependency_validator_inode="$(/usr/bin/stat -f '%i' "$HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR")"
  dependency_validator_digest="$(sha_executable "$HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR")"
  boundary_validator_device="$(/usr/bin/stat -f '%d' "$HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR")"
  boundary_validator_inode="$(/usr/bin/stat -f '%i' "$HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR")"
  boundary_validator_digest="$(sha_executable "$HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR")"
  [[ "$dependency_validator_digest" == "${HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR_DIGEST:-}" \
    && "$dependency_validator_device" == "${HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR_DEVICE:-}" \
    && "$dependency_validator_inode" == "${HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR_INODE:-}" \
    && "$boundary_validator_digest" == "${HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR_DIGEST:-}" \
    && "$boundary_validator_device" == "${HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR_DEVICE:-}" \
    && "$boundary_validator_inode" == "${HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR_INODE:-}" ]] \
    || die 'Gate 15 canonical validator identity is not bound to the prepared launch.' 69
  [[ "$HOSTWRIGHT_GATE15_PROJECT" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || die 'HOSTWRIGHT_GATE15_PROJECT is required and bounded.' 69
  [[ "$HOSTWRIGHT_GATE15_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'HOSTWRIGHT_GATE15_IMAGE_DIGEST is not the pinned image digest.' 69
  [[ "$HOSTWRIGHT_GATE15_RUNTIME_UUID" =~ ^[A-Za-z0-9._-]{8,128}$ ]] || die 'HOSTWRIGHT_GATE15_RUNTIME_UUID is not the pinned runtime identity.' 69
  [[ "${HOSTWRIGHT_NOTARY_PROFILE:-}" != "" ]] || die 'HOSTWRIGHT_NOTARY_PROFILE is required for the signed Gate 15 boundary.' 69
  signing_identity="${HOSTWRIGHT_GATE15_SIGNING_IDENTITY:-}"
  signing_fingerprint="${HOSTWRIGHT_GATE15_SIGNING_FINGERPRINT:-}"
  signing_certificate_fingerprint="${HOSTWRIGHT_GATE15_CERTIFICATE_FINGERPRINT:-}"
  signing_team_id="${HOSTWRIGHT_GATE15_TEAM_ID:-}"
  [[ "$signing_identity" == "$expected_signing_identity" && "$signing_fingerprint" == "$expected_signing_fingerprint" \
    && "$signing_certificate_fingerprint" == "$expected_certificate_fingerprint" && "$signing_team_id" == "$expected_signing_team" ]] \
    || die 'Gate 15 live boundary signer pins are not exact.' 69
  validate_pinned_signed_executables
  local -a pinned_entries=()
  local required entry pinned
  IFS=':' read -r -a pinned_entries <<< "$HOSTWRIGHT_GATE15_SIGNED_EXECUTABLES"
  for required in \
    "$HOSTWRIGHT_GATE15_TOOL" \
    "$HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER" \
    "$HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER" \
    "$HOSTWRIGHT_GATE15_RUNTIME_SETUP" \
    "$HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER"; do
    pinned=0
    for entry in "${pinned_entries[@]}"; do
      if [[ "$entry" == "$required" ]]; then pinned=1; break; fi
    done
    [[ "$pinned" == 1 ]] || die 'a required live-boundary executable is not in the exact signed pinset.' 69
  done
  require_private_file "$root/manifest-v1.json" 'Gate 15 manifest'
  [[ "$(sha "$root/manifest-v1.json")" == "${HOSTWRIGHT_GATE15_MANIFEST_DIGEST:-}" ]] \
    || die 'Gate 15 live boundary manifest binding is stale.' 69
  /usr/bin/jq -e --arg source "${HOSTWRIGHT_GATE15_SOURCE_DIGEST:-}" --arg config "${HOSTWRIGHT_GATE15_CONFIG_DIGEST:-}" \
    --arg toolchain "${HOSTWRIGHT_GATE15_TOOLCHAIN_DIGEST:-}" --arg dependency "${HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE_DIGEST:-}" \
    --arg pinset "${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST:-}" '
      (.status == "prepared" and .sourceDigest == $source and .configDigest == $config and .toolchainDigest == $toolchain
       and .dependencyEvidenceDigest == $dependency and .executablePinsetDigest == $pinset)
    ' "$root/manifest-v1.json" >/dev/null || die 'Gate 15 live boundary dependency bindings are stale or ambiguous.' 69
  /usr/bin/codesign --verify --strict "$HOSTWRIGHT_GATE15_TOOL" >/dev/null 2>&1 || die 'Gate 15 tool signature failed.' 69
  /usr/bin/codesign --verify --strict "$HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER" >/dev/null 2>&1 || die 'Gate 15 observation provider signature failed.' 69
  /usr/bin/codesign --verify --strict "$HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER" >/dev/null 2>&1 || die 'Gate 15 trusted observation provider signature failed.' 69
  /usr/bin/codesign --verify --strict "$HOSTWRIGHT_GATE15_RUNTIME_SETUP" >/dev/null 2>&1 || die 'Gate 15 runtime setup signature failed.' 69
  /usr/bin/codesign --verify --strict "$HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER" >/dev/null 2>&1 || die 'Gate 15 sleep/wake provider signature failed.' 69
}

validate_bound_environment() {
  local dependency pinset
  dependency="$root/dependency-evidence-v1.json"
  pinset="${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET:-}"
  require_private_file "$dependency" 'Gate 15 dependency evidence'
  [[ "$(sha "$dependency")" == "${HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE_DIGEST:-}" ]] \
    || die 'Gate 15 transitive dependency evidence changed during the sample.' 73
  require_private_file "$pinset" 'Gate 15 executable pinset'
  [[ "$(sha "$pinset")" == "${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST:-}" ]] \
    || die 'Gate 15 executable pinset changed during the sample.' 73
  [[ "$(sha "$root/manifest-v1.json")" == "${HOSTWRIGHT_GATE15_MANIFEST_DIGEST:-}" ]] \
    || die 'Gate 15 manifest changed during the sample.' 73
}

container_inventory() {
  /usr/local/bin/container list --all --format json
}

validate_inventory_shape() {
  local inventory="$1"
  /usr/bin/jq -e --arg project "$HOSTWRIGHT_GATE15_PROJECT" --arg runtime "$HOSTWRIGHT_GATE15_RUNTIME_UUID" \
    --arg digest "$HOSTWRIGHT_GATE15_IMAGE_DIGEST" '
      . as $inventory
      | ($inventory | type == "array")
      and ([$inventory[] | .id] | all(. != null and type == "string" and length > 0))
      and ([$inventory[] | .id] | length == ([$inventory[] | .id] | unique | length))
      and all($inventory[];
        ((.configuration.labels // {}) as $configurationLabels | (.labels // {}) as $labels |
          (($configurationLabels["dev.hostwright.project"] // "") == "" or ($labels["dev.hostwright.project"] // "") == "" or
            $configurationLabels["dev.hostwright.project"] == $labels["dev.hostwright.project"])
          and (($configurationLabels["dev.hostwright.runtime"] // "") == "" or ($labels["dev.hostwright.runtime"] // "") == "" or
            $configurationLabels["dev.hostwright.runtime"] == $labels["dev.hostwright.runtime"])
          and (((.configuration.image.descriptor.digest // "") == "" or (.image.descriptor.digest // "") == "") or
            (.configuration.image.descriptor.digest // "") == (.image.descriptor.digest // ""))
          and (($configurationLabels["dev.hostwright.project"] // $labels["dev.hostwright.project"] // "") == $project)
          and (($configurationLabels["dev.hostwright.runtime"] // $labels["dev.hostwright.runtime"] // "") == $runtime)
          and ((.configuration.image.descriptor.digest // .image.descriptor.digest // "") == $digest)
          and .id == $runtime)
      )
    ' <<< "$inventory" >/dev/null || die 'Gate 15 inventory contains foreign, unlabelled, ambiguous, or unpinned resources.' 70
}

owned_runtime_count() {
  local inventory="$1"
  /usr/bin/jq -r --arg runtime "$HOSTWRIGHT_GATE15_RUNTIME_UUID" '[.[] | select(.id == $runtime)] | length' <<< "$inventory"
}

check_inventory() {
  local inventory count
  inventory="$(container_inventory)" || die 'the exact system container inventory command failed.' 70
  validate_inventory_shape "$inventory"
  count="$(owned_runtime_count "$inventory")"
  [[ "$count" == 1 ]] || die 'the exclusive Gate 15 inventory is not the exact pinned runtime.' 70
}

check_clean_boundary() {
  local inventory count
  inventory="$(container_inventory)" || die 'the exact system container inventory command failed.' 70
  validate_inventory_shape "$inventory"
  count="$(owned_runtime_count "$inventory")"
  [[ "$count" == 0 ]] || die 'an owned Gate 15 runtime already exists; do not attach or duplicate it.' 75
}

ensure_owned_runtime() {
  "$HOSTWRIGHT_GATE15_RUNTIME_SETUP" create --runtime "$HOSTWRIGHT_GATE15_RUNTIME_UUID" \
    --project "$HOSTWRIGHT_GATE15_PROJECT" --image-digest "$HOSTWRIGHT_GATE15_IMAGE_DIGEST" >/dev/null 2>&1 \
    || die 'the pinned Gate 15 runtime setup failed.' 70
  check_inventory
}

write_inventory() {
  local destination="$1" inventory temporary
  [[ "$destination" == "$root"/* && "$destination" != *$'\n'* && "$destination" != *$'\t'* ]] \
    || die 'runtime inventory destination is unsafe.' 124
  assert_absent "$destination" || die 'runtime inventory destination already exists or is a symlink.' 124
  inventory="$(container_inventory)" || die 'the exact system container inventory command failed.' 70
  validate_inventory_shape "$inventory"
  temporary="$(/usr/bin/jq -c --arg runtime "$HOSTWRIGHT_GATE15_RUNTIME_UUID" '
    [ .[] | select(.id == $runtime) | {id:.id, project:(.configuration.labels["dev.hostwright.project"] // .labels["dev.hostwright.project"]), runtime:(.configuration.labels["dev.hostwright.runtime"] // .labels["dev.hostwright.runtime"]), imageDigest:(.configuration.image.descriptor.digest // .image.descriptor.digest)} ]
  ' <<< "$inventory" | write_private_temp_from_stdin inventory)" \
    || die 'runtime inventory could not be written by the exclusive private writer.' 124
  publish_temp_absent "$temporary" "$destination" 'runtime inventory evidence'
}

record_owned_runtime() {
  [[ ! -e "$root/owned-runtime-v1.tsv" && ! -L "$root/owned-runtime-v1.tsv" ]] \
    || die 'owned runtime ledger already exists; preserve the root.' 124
  printf '%s\n%s\n' $'recorded_at\truntime_uuid\tproject\timage_digest' \
    "$(printf '%s\t%s\t%s\t%s' "$(now)" "$HOSTWRIGHT_GATE15_RUNTIME_UUID" "$HOSTWRIGHT_GATE15_PROJECT" "$HOSTWRIGHT_GATE15_IMAGE_DIGEST")" \
    | write_private "$root/owned-runtime-v1.tsv" 'owned runtime ledger' owned-runtime
}

validate_owned_runtime_ledger() {
  local line recorded runtime project digest
  require_private_file "$root/owned-runtime-v1.tsv" 'owned runtime ledger'
  [[ "$(/usr/bin/head -n 1 "$root/owned-runtime-v1.tsv")" == $'recorded_at\truntime_uuid\tproject\timage_digest' ]] \
    || die 'owned runtime ledger header is invalid.' 124
  /usr/bin/awk -F $'\t' 'NR == 1 {next} NF != 4 {bad=1} NR > 2 {bad=1} END {exit bad ? 1 : 0}' "$root/owned-runtime-v1.tsv" \
    || die 'owned runtime ledger is ambiguous or has foreign rows.' 124
  while IFS=$'\t' read -r recorded runtime project digest; do
    [[ "$recorded" == recorded_at ]] && continue
    [[ "$runtime" == "$HOSTWRIGHT_GATE15_RUNTIME_UUID" && "$project" == "$HOSTWRIGHT_GATE15_PROJECT" \
      && "$digest" == "$HOSTWRIGHT_GATE15_IMAGE_DIGEST" ]] || die 'owned runtime ledger does not bind the exact runtime.' 124
  done < "$root/owned-runtime-v1.tsv"
}

cleanup_owned_runtime() {
  [[ "$cleanup_attempted" == 0 ]] || return 0
  cleanup_attempted=1
  [[ -e "$root/owned-runtime-v1.tsv" ]] || return 0
  validate_owned_runtime_ledger
  validate_bound_environment
  validate_pinned_signed_executables
  local inventory count
  inventory="$(container_inventory)" || die 'owned runtime inventory failed during exact cleanup.' 124
  validate_inventory_shape "$inventory"
  count="$(owned_runtime_count "$inventory")"
  [[ "$count" == 0 ]] && return 0
  [[ "$count" == 1 ]] || die 'owned runtime identity became ambiguous; cleanup is refused.' 124
  /usr/local/bin/container delete --force "$HOSTWRIGHT_GATE15_RUNTIME_UUID" \
    || die 'the exact system container delete command failed; cleanup is frozen.' 124
  inventory="$(container_inventory)" || die 'post-cleanup system inventory failed.' 124
  validate_inventory_shape "$inventory"
  [[ "$(owned_runtime_count "$inventory")" == 0 ]] || die 'owned runtime remained after exact deletion.' 124
}

validate_run_started_marker() {
  local expected_status="$1" marker="${HOSTWRIGHT_GATE15_RUN_STARTED:-}"
  [[ "$marker" == "$root/run-started-v1.json" ]] \
    || die 'Gate 15 live execution requires the canonical qualification run-started authorization.' 74
  require_private_file "$marker" 'Gate 15 run-started marker'
  /usr/bin/jq -e --arg schema "$run_started_schema" --arg rootPath "$root" --arg status "$expected_status" \
    --arg rootLockPath "$root/active-run-v1" --arg gateLockPath "$(/usr/bin/dirname "$root")/.phase09-gate15-active-v1" \
    --arg rootLockInfoPath "$root/gate-active-run-v1-info.tsv" --arg gateLockInfoPath "$(/usr/bin/dirname "$root")/.phase09-gate15-active-v1/info-v1.tsv" \
    --arg sourceCommit "${HOSTWRIGHT_GATE15_SOURCE_COMMIT:-}" --arg sourceDigest "${HOSTWRIGHT_GATE15_SOURCE_DIGEST:-}" \
    --arg configDigest "${HOSTWRIGHT_GATE15_CONFIG_DIGEST:-}" --arg toolchainDigest "${HOSTWRIGHT_GATE15_TOOLCHAIN_DIGEST:-}" \
    --arg dependencyDigest "${HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE_DIGEST:-}" --arg pinsetDigest "${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST:-}" \
    --arg manifestDigest "${HOSTWRIGHT_GATE15_MANIFEST_DIGEST:-}" \
    --arg dependencyValidatorPath "${HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR:-}" \
    --arg dependencyValidatorDigest "${HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR_DIGEST:-}" \
    --argjson dependencyValidatorDevice "${HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR_DEVICE:-0}" \
    --argjson dependencyValidatorInode "${HOSTWRIGHT_GATE15_DEPENDENCY_VALIDATOR_INODE:-0}" \
    --arg boundaryValidatorPath "${HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR:-}" \
    --arg boundaryValidatorDigest "${HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR_DIGEST:-}" \
    --argjson boundaryValidatorDevice "${HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR_DEVICE:-0}" \
    --argjson boundaryValidatorInode "${HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR_INODE:-0}" \
    --arg executablePinsetPath "${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET:-}" \
    --arg executablePinsetDigest "${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST:-}" \
    --argjson executablePinsetDevice "${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DEVICE:-0}" \
    --argjson executablePinsetInode "${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_INODE:-0}" \
    --arg toolPath "${HOSTWRIGHT_GATE15_TOOL:-}" --argjson toolDevice "${HOSTWRIGHT_GATE15_TOOL_DEVICE:-0}" \
    --argjson toolInode "${HOSTWRIGHT_GATE15_TOOL_INODE:-0}" --argjson toolMode "${HOSTWRIGHT_GATE15_TOOL_MODE:-0}" \
    --arg toolDigest "${HOSTWRIGHT_GATE15_TOOL_DIGEST:-}" --arg toolBuildIdentity "${HOSTWRIGHT_GATE15_TOOL_BUILD_IDENTITY:-}" \
    --arg invocation "run --root $root" \
    --arg observationProviderPath "${HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER:-}" \
    --argjson observationProviderDevice "${HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER_DEVICE:-0}" \
    --argjson observationProviderInode "${HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER_INODE:-0}" \
    --arg observationProviderDigest "${HOSTWRIGHT_GATE15_OBSERVATION_PROVIDER_DIGEST:-}" \
    --arg trustedObservationProviderPath "${HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER:-}" \
    --argjson trustedObservationProviderDevice "${HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER_DEVICE:-0}" \
    --argjson trustedObservationProviderInode "${HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER_INODE:-0}" \
    --arg trustedObservationProviderDigest "${HOSTWRIGHT_GATE15_TRUSTED_OBSERVATION_PROVIDER_DIGEST:-}" \
    --arg sleepWakeProviderPath "${HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER:-}" \
    --argjson sleepWakeProviderDevice "${HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER_DEVICE:-0}" \
    --argjson sleepWakeProviderInode "${HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER_INODE:-0}" \
    --arg sleepWakeProviderDigest "${HOSTWRIGHT_GATE15_SLEEP_WAKE_PROVIDER_DIGEST:-}" \
    '(.schema == $schema and .root == $rootPath and .status == $status and .rootLockPath == $rootLockPath and .gateLockPath == $gateLockPath
      and .rootLockInfoPath == $rootLockInfoPath and .gateLockInfoPath == $gateLockInfoPath
      and .sourceCommit == $sourceCommit and .sourceDigest == $sourceDigest and .configDigest == $configDigest
      and .toolchainDigest == $toolchainDigest and .dependencyEvidenceDigest == $dependencyDigest
      and .executablePinsetDigest == $pinsetDigest and .manifestDigest == $manifestDigest
      and .dependencyValidatorPath == $dependencyValidatorPath and .dependencyValidatorDigest == $dependencyValidatorDigest
      and .dependencyValidatorDevice == $dependencyValidatorDevice and .dependencyValidatorInode == $dependencyValidatorInode
      and .boundaryValidatorPath == $boundaryValidatorPath and .boundaryValidatorDigest == $boundaryValidatorDigest
      and .boundaryValidatorDevice == $boundaryValidatorDevice and .boundaryValidatorInode == $boundaryValidatorInode
      and .executablePinsetPath == $executablePinsetPath and .executablePinsetDigest == $executablePinsetDigest
      and .executablePinsetDevice == $executablePinsetDevice and .executablePinsetInode == $executablePinsetInode
      and .toolPath == $toolPath and .toolDevice == $toolDevice and .toolInode == $toolInode and .toolMode == $toolMode
      and .toolDigest == $toolDigest and .toolBuildIdentity == $toolBuildIdentity and .invocation == $invocation
      and .observationProviderPath == $observationProviderPath and .observationProviderDevice == $observationProviderDevice
      and .observationProviderInode == $observationProviderInode and .observationProviderDigest == $observationProviderDigest
      and .trustedObservationProviderPath == $trustedObservationProviderPath
      and .trustedObservationProviderDevice == $trustedObservationProviderDevice
      and .trustedObservationProviderInode == $trustedObservationProviderInode
      and .trustedObservationProviderDigest == $trustedObservationProviderDigest
      and .sleepWakeProviderPath == $sleepWakeProviderPath and .sleepWakeProviderDevice == $sleepWakeProviderDevice
      and .sleepWakeProviderInode == $sleepWakeProviderInode and .sleepWakeProviderDigest == $sleepWakeProviderDigest)' \
    "$marker" >/dev/null || die 'Gate 15 run-started marker is stale or not bound to the exact prepared source.' 74
  local root_device root_inode gate_device gate_inode
  local gate_info_device gate_info_inode
  root_device="$(/usr/bin/jq -r '.rootLockDevice' "$marker")"; root_inode="$(/usr/bin/jq -r '.rootLockInode' "$marker")"
  gate_device="$(/usr/bin/jq -r '.gateLockDevice' "$marker")"; gate_inode="$(/usr/bin/jq -r '.gateLockInode' "$marker")"
  [[ "$root_device" =~ ^[1-9][0-9]*$ && "$root_inode" =~ ^[1-9][0-9]*$ && "$gate_device" =~ ^[1-9][0-9]*$ && "$gate_inode" =~ ^[1-9][0-9]*$ ]] \
    || die 'Gate 15 run-started marker has invalid lock identities.' 74
  for lock in "$root/active-run-v1" "$(/usr/bin/dirname "$root")/.phase09-gate15-active-v1"; do
    private_directory "$lock" || die 'Gate 15 run-started lock is missing, non-canonical, or not mode 0700.' 75
  done
  [[ "$(/usr/bin/stat -f '%d' "$root/active-run-v1")" == "$root_device" && "$(/usr/bin/stat -f '%i' "$root/active-run-v1")" == "$root_inode" \
    && "$(/usr/bin/stat -f '%d' "$(/usr/bin/dirname "$root")/.phase09-gate15-active-v1")" == "$gate_device" \
    && "$(/usr/bin/stat -f '%i' "$(/usr/bin/dirname "$root")/.phase09-gate15-active-v1")" == "$gate_inode" ]] \
    || die 'Gate 15 run-started lock device or inode changed.' 75
  gate_info_device="$(/usr/bin/jq -r '.gateLockInfoDevice' "$marker")"
  gate_info_inode="$(/usr/bin/jq -r '.gateLockInfoInode' "$marker")"
  require_private_file "$(/usr/bin/dirname "$root")/.phase09-gate15-active-v1/info-v1.tsv" 'Gate 15 gate lock info'
  [[ "$gate_info_device" =~ ^[1-9][0-9]*$ && "$gate_info_inode" =~ ^[1-9][0-9]*$ \
    && "$(/usr/bin/stat -f '%d' "$(/usr/bin/dirname "$root")/.phase09-gate15-active-v1/info-v1.tsv")" == "$gate_info_device" \
    && "$(/usr/bin/stat -f '%i' "$(/usr/bin/dirname "$root")/.phase09-gate15-active-v1/info-v1.tsv")" == "$gate_info_inode" ]] \
    || die 'Gate 15 gate lock info device or inode changed.' 75
}

validate_lock_info() {
  local path="$1" expected_pid="$2" expected_start="$3"
  require_private_file "$path" 'Gate 15 active lock info'
  [[ "$(/usr/bin/head -n 1 "$path")" == "$lock_info_header" ]] \
    || die 'Gate 15 active lock info header is invalid.' 75
  /usr/bin/awk -F $'\t' -v root="$root" -v pid="$expected_pid" -v start="$expected_start" \
    -v commit="${HOSTWRIGHT_GATE15_SOURCE_COMMIT:-}" -v source="${HOSTWRIGHT_GATE15_SOURCE_DIGEST:-}" \
    -v config="${HOSTWRIGHT_GATE15_CONFIG_DIGEST:-}" -v toolchain="${HOSTWRIGHT_GATE15_TOOLCHAIN_DIGEST:-}" \
    -v dependency="${HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE_DIGEST:-}" -v pinset="${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST:-}" \
    -v manifest="${HOSTWRIGHT_GATE15_MANIFEST_DIGEST:-}" \
    'NR == 2 && $1 == root && $2 == pid && $3 == start && $5 == commit && $6 == source && $7 == config &&
      $8 == toolchain && $9 == dependency && $10 == pinset && $11 == manifest && NR == 2 {found=1}
     END {exit found ? 0 : 1}' "$path" \
    || die 'Gate 15 active lock info is not bound to the current runner and source.' 75
  [[ "$(/usr/bin/wc -l < "$path" | /usr/bin/tr -d ' ')" == 2 ]] || die 'Gate 15 active lock info contains extra rows.' 75
}

update_run_started_from_request() {
  local request="$1" marker="$root/run-started-v1.json" lock="$root/active-run-v1" gate_lock="$(/usr/bin/dirname "$root")/.phase09-gate15-active-v1"
  local runner_pid runner_start requested_at
  runner_pid="$(/usr/bin/jq -r '.runnerPID' "$request")"
  runner_start="$(/usr/bin/jq -r '.runnerStartIdentity' "$request")"
  requested_at="$(/usr/bin/jq -r '.requestedAtUTC' "$request")"
  [[ "$runner_pid" =~ ^[1-9][0-9]*$ && "$runner_start" =~ ^v1\.[a-f0-9]{64}\.[a-f0-9]{64}\.[0-9]+\.[0-9]+$ ]] \
    || die 'Gate 15 launch request does not identify a valid runner.' 74
  printf '%s\n%s\n' "$lock_info_header" \
    "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$root" "$runner_pid" "$runner_start" "$requested_at" \
      "${HOSTWRIGHT_GATE15_SOURCE_COMMIT}" "${HOSTWRIGHT_GATE15_SOURCE_DIGEST}" "${HOSTWRIGHT_GATE15_CONFIG_DIGEST}" \
      "${HOSTWRIGHT_GATE15_TOOLCHAIN_DIGEST}" "${HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE_DIGEST}" \
      "${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST}" "${HOSTWRIGHT_GATE15_MANIFEST_DIGEST}")" \
    | replace_private "$gate_lock/info-v1.tsv" 'Gate 15 runner lock info' runner-lock-info
  printf '%s\n%s\n' "$lock_info_header" \
    "$(/bin/cat "$gate_lock/info-v1.tsv" | /usr/bin/tail -n 1)" \
    | replace_private "$root/gate-active-run-v1-info.tsv" 'Gate 15 root lock info' root-lock-info
  /usr/bin/jq --arg status runner-started --argjson pid "$runner_pid" --arg start "$runner_start" \
    --arg startedAtUTC "$requested_at" \
    '.status=$status|.runnerPID=$pid|.runnerStartIdentity=$start|.startedAtUTC=$startedAtUTC' "$marker" \
    | replace_private "$marker" 'Gate 15 run-started runner binding' run-started-bound
  validate_run_started_marker runner-started
  validate_lock_info "$gate_lock/info-v1.tsv" "$runner_pid" "$runner_start"
  validate_lock_info "$root/gate-active-run-v1-info.tsv" "$runner_pid" "$runner_start"
}

validate_active_run_binding() {
  local marker="$root/run-started-v1.json" runner_pid runner_start state="$root/runner-state-v1.json"
  validate_run_started_marker runner-started
  runner_pid="$(/usr/bin/jq -r '.runnerPID' "$marker")"
  runner_start="$(/usr/bin/jq -r '.runnerStartIdentity' "$marker")"
  /bin/kill -0 "$runner_pid" >/dev/null 2>&1 || die 'Gate 15 runner is no longer live; the root is frozen.' 75
  validate_lock_info "$root/gate-active-run-v1-info.tsv" "$runner_pid" "$runner_start"
  validate_lock_info "$(/usr/bin/dirname "$root")/.phase09-gate15-active-v1/info-v1.tsv" "$runner_pid" "$runner_start"
  if [[ -e "$state" || -L "$state" ]]; then
    require_private_file "$state" 'Gate 15 runner state'
    /usr/bin/jq -e --argjson pid "$runner_pid" --arg start "$runner_start" --arg rootPath "$root" \
      --arg source "${HOSTWRIGHT_GATE15_SOURCE_DIGEST}" --arg markerDigest "$(sha "$marker")" \
      '(.runnerPID == $pid and .runnerStartIdentity == $start and .root == $rootPath and .sourceDigest == $source and .runStartedDigest == $markerDigest)' \
      "$state" >/dev/null || die 'Gate 15 runner state is not bound to the same live runner, marker, and source.' 75
  fi
}

publish_launch_authorization() {
  local request="$root/launch-request-v1.json" authorization="$root/launch-authorization-v1.cms"
  local before_device before_inode after_device after_inode request_json payload_tmp cms_tmp decoded_tmp run_started_digest
  local root_lock gate_lock root_device root_inode gate_device gate_inode boot_session
  require_private_file "$request" 'Gate 15 launch request'
  assert_absent "$authorization" || die 'Gate 15 launch authorization already exists; preserve the root.' 124
  validate_run_started_marker launch-pending
  request_json="$(/usr/bin/jq -cS . "$request")" || die 'Gate 15 launch request is malformed.' 124
  [[ "$(printf '%s' "$request_json")" == "$(/bin/cat "$request")" ]] || die 'Gate 15 launch request is not canonical JSON.' 124
  before_device="$(/usr/bin/stat -f '%d' "$request")"; before_inode="$(/usr/bin/stat -f '%i' "$request")"
  local request_schema request_root runner_pid runner_start request_boot nonce requested_at
  request_schema="$(/usr/bin/jq -r '.schema' <<< "$request_json")"
  request_root="$(/usr/bin/jq -r '.root' <<< "$request_json")"
  runner_pid="$(/usr/bin/jq -r '.runnerPID' <<< "$request_json")"
  runner_start="$(/usr/bin/jq -r '.runnerStartIdentity' <<< "$request_json")"
  request_boot="$(/usr/bin/jq -r '.bootSessionID' <<< "$request_json")"
  nonce="$(/usr/bin/jq -r '.nonce' <<< "$request_json")"
  requested_at="$(/usr/bin/jq -r '.requestedAtUTC' <<< "$request_json")"
  [[ "$request_schema" == 'hostwright.phase09.gate15.launch-request.v1' && "$request_root" == "$root" \
    && "$runner_pid" =~ ^[1-9][0-9]*$ && "$runner_start" =~ ^v1\.[a-f0-9]{64}\.[a-f0-9]{64}\.[0-9]+\.[0-9]+$ \
    && "$request_boot" =~ ^[A-Fa-f0-9-]{36}$ \
    && "$nonce" =~ ^[a-f0-9]{64}$ && "$requested_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?Z$ ]] \
    || die 'Gate 15 launch request is not bound to the exact runner and UTC endpoint.' 124
  root_lock="$root/active-run-v1"; gate_lock="$(/usr/bin/dirname "$root")/.phase09-gate15-active-v1"
  private_directory "$root_lock" && private_directory "$gate_lock" || die 'Gate 15 launch authorization requires both active locks.' 124
  root_device="$(/usr/bin/stat -f '%d' "$root_lock")"; root_inode="$(/usr/bin/stat -f '%i' "$root_lock")"
  gate_device="$(/usr/bin/stat -f '%d' "$gate_lock")"; gate_inode="$(/usr/bin/stat -f '%i' "$gate_lock")"
  boot_session="$(/usr/sbin/sysctl -n kern.bootsessionuuid)" || die 'Gate 15 boot-session identity is unavailable.' 124
  [[ "$boot_session" =~ ^[A-Fa-f0-9-]{36}$ && "$request_boot" == "$boot_session" ]] || die 'Gate 15 boot-session identity is malformed or changed.' 124
  update_run_started_from_request "$request"
  run_started_digest="$(sha "$root/run-started-v1.json")"
  validate_active_run_binding
  payload_tmp="$(/usr/bin/jq -cS -n --arg schema 'hostwright.phase09.gate15.launch-authorization.v1' --arg root "$root" \
    --arg rootLockPath "$root_lock" --arg gateLockPath "$gate_lock" \
    --argjson rootLockDevice "$root_device" --argjson rootLockInode "$root_inode" \
    --argjson gateLockDevice "$gate_device" --argjson gateLockInode "$gate_inode" \
    --argjson runnerPID "$runner_pid" --arg runnerStartIdentity "$runner_start" --arg bootSessionID "$boot_session" \
    --arg nonce "$nonce" --arg sourceCommit "${HOSTWRIGHT_GATE15_SOURCE_COMMIT:-}" \
    --arg sourceDigest "${HOSTWRIGHT_GATE15_SOURCE_DIGEST:-}" --arg configDigest "${HOSTWRIGHT_GATE15_CONFIG_DIGEST:-}" \
    --arg toolchainDigest "${HOSTWRIGHT_GATE15_TOOLCHAIN_DIGEST:-}" --arg dependencyEvidenceDigest "${HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE_DIGEST:-}" \
    --arg executablePinsetDigest "${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST:-}" --arg manifestDigest "${HOSTWRIGHT_GATE15_MANIFEST_DIGEST:-}" \
    --arg dependencyValidatorPath "$canonical_dependency_validator_path" \
    --argjson dependencyValidatorDevice "$dependency_validator_device" --argjson dependencyValidatorInode "$dependency_validator_inode" \
    --arg dependencyValidatorDigest "$dependency_validator_digest" \
    --arg boundaryValidatorPath "$canonical_boundary_validator_path" \
    --argjson boundaryValidatorDevice "$boundary_validator_device" --argjson boundaryValidatorInode "$boundary_validator_inode" \
    --arg boundaryValidatorDigest "$boundary_validator_digest" \
    --arg executablePinsetPath "$pinset_path" --argjson executablePinsetDevice "$pinset_device" \
    --argjson executablePinsetInode "$pinset_inode" --arg runStartedDigest "$run_started_digest" \
    --arg toolPath "$canonical_tool_path" --argjson toolDevice "$tool_device" --argjson toolInode "$tool_inode" \
    --argjson toolMode "$tool_mode" --arg toolDigest "$tool_digest" --arg toolBuildIdentity "${HOSTWRIGHT_GATE15_TOOL_BUILD_IDENTITY}" \
    --arg invocation "run --root $root" \
    --arg observationProviderPath "$observation_provider_path" --argjson observationProviderDevice "$observation_provider_device" \
    --argjson observationProviderInode "$observation_provider_inode" --arg observationProviderDigest "$observation_provider_digest" \
    --arg trustedObservationProviderPath "$trusted_observation_provider_path" --argjson trustedObservationProviderDevice "$trusted_observation_provider_device" \
    --argjson trustedObservationProviderInode "$trusted_observation_provider_inode" --arg trustedObservationProviderDigest "$trusted_observation_provider_digest" \
    --arg sleepWakeProviderPath "$sleep_wake_provider_path" --argjson sleepWakeProviderDevice "$sleep_wake_provider_device" \
    --argjson sleepWakeProviderInode "$sleep_wake_provider_inode" --arg sleepWakeProviderDigest "$sleep_wake_provider_digest" \
    --arg signingIdentity "$signing_identity" --arg signingFingerprint "$signing_fingerprint" \
    --arg certificateFingerprint "$signing_certificate_fingerprint" --arg teamID "$signing_team_id" \
    --arg createdAtUTC "$requested_at" \
    '{schema:$schema,root:$root,rootLockPath:$rootLockPath,rootLockDevice:$rootLockDevice,rootLockInode:$rootLockInode,
      gateLockPath:$gateLockPath,gateLockDevice:$gateLockDevice,gateLockInode:$gateLockInode,runnerPID:$runnerPID,
      runnerStartIdentity:$runnerStartIdentity,bootSessionID:$bootSessionID,nonce:$nonce,sourceCommit:$sourceCommit,
      sourceDigest:$sourceDigest,configDigest:$configDigest,toolchainDigest:$toolchainDigest,
      dependencyEvidenceDigest:$dependencyEvidenceDigest,executablePinsetDigest:$executablePinsetDigest,
      dependencyValidatorPath:$dependencyValidatorPath,dependencyValidatorDevice:$dependencyValidatorDevice,
      dependencyValidatorInode:$dependencyValidatorInode,dependencyValidatorDigest:$dependencyValidatorDigest,
      boundaryValidatorPath:$boundaryValidatorPath,boundaryValidatorDevice:$boundaryValidatorDevice,
      boundaryValidatorInode:$boundaryValidatorInode,boundaryValidatorDigest:$boundaryValidatorDigest,
      executablePinsetPath:$executablePinsetPath,executablePinsetDevice:$executablePinsetDevice,
      executablePinsetInode:$executablePinsetInode,runStartedDigest:$runStartedDigest,
      toolPath:$toolPath,toolDevice:$toolDevice,toolInode:$toolInode,toolMode:$toolMode,toolDigest:$toolDigest,toolBuildIdentity:$toolBuildIdentity,
      invocation:$invocation,observationProviderPath:$observationProviderPath,observationProviderDevice:$observationProviderDevice,
      observationProviderInode:$observationProviderInode,observationProviderDigest:$observationProviderDigest,
      trustedObservationProviderPath:$trustedObservationProviderPath,trustedObservationProviderDevice:$trustedObservationProviderDevice,
      trustedObservationProviderInode:$trustedObservationProviderInode,trustedObservationProviderDigest:$trustedObservationProviderDigest,
      sleepWakeProviderPath:$sleepWakeProviderPath,sleepWakeProviderDevice:$sleepWakeProviderDevice,
      sleepWakeProviderInode:$sleepWakeProviderInode,sleepWakeProviderDigest:$sleepWakeProviderDigest,
      manifestDigest:$manifestDigest,signingIdentity:$signingIdentity,signingFingerprint:$signingFingerprint,
      certificateFingerprint:$certificateFingerprint,teamID:$teamID,createdAtUTC:$createdAtUTC}' \
    | /usr/bin/tr -d '\n' | write_private_temp_from_stdin launch-payload)" \
    || die 'Gate 15 launch payload could not be written by the exclusive private writer.' 124
  private_file "$payload_tmp" || die 'Gate 15 launch payload failed private identity validation.' 124
  /usr/bin/jq -e --arg source "${HOSTWRIGHT_GATE15_SOURCE_DIGEST:-}" --arg config "${HOSTWRIGHT_GATE15_CONFIG_DIGEST:-}" \
    --arg toolchain "${HOSTWRIGHT_GATE15_TOOLCHAIN_DIGEST:-}" --arg dependency "${HOSTWRIGHT_GATE15_DEPENDENCY_EVIDENCE_DIGEST:-}" \
    --arg pinset "${HOSTWRIGHT_GATE15_EXECUTABLE_PINSET_DIGEST:-}" --arg manifest "${HOSTWRIGHT_GATE15_MANIFEST_DIGEST:-}" \
    --arg runStarted "$run_started_digest" --arg validator "$dependency_validator_digest" --arg boundary "$boundary_validator_digest" \
    '(.sourceCommit | test("^[a-f0-9]{40}$")) and (.sourceDigest == $source) and (.configDigest == $config)
     and (.toolchainDigest == $toolchain) and (.dependencyEvidenceDigest == $dependency)
     and (.executablePinsetDigest == $pinset) and (.manifestDigest == $manifest)
     and (.runStartedDigest == $runStarted) and (.dependencyValidatorDigest == $validator)
     and (.boundaryValidatorDigest == $boundary)' "$payload_tmp" >/dev/null \
    || die 'Gate 15 launch authorization payload is not bound to current evidence.' 124
  cms_tmp="$(/usr/bin/security cms -S -N "$signing_identity" -H SHA256 -u 9 -i "$payload_tmp" -o /dev/stdout 2>/dev/null | write_private_temp_from_stdin launch-cms)" \
    || die 'Gate 15 launch authorization CMS signing failed.' 74
  decoded_tmp="$(/usr/bin/security cms -D -N "$signing_identity" -u 9 -i "$cms_tmp" -o /dev/stdout 2>/dev/null | write_private_temp_from_stdin launch-decoded)" \
    || die 'Gate 15 launch authorization CMS decode failed.' 74
  /usr/bin/cmp -s "$payload_tmp" "$decoded_tmp" || die 'Gate 15 launch authorization CMS did not round-trip.' 74
  after_device="$(/usr/bin/stat -f '%d' "$request")"; after_inode="$(/usr/bin/stat -f '%i' "$request")"
  [[ "$before_device" == "$after_device" && "$before_inode" == "$after_inode" \
    && "$(/usr/bin/stat -f '%d' "$root_lock")" == "$root_device" && "$(/usr/bin/stat -f '%i' "$root_lock")" == "$root_inode" \
    && "$(/usr/bin/stat -f '%d' "$gate_lock")" == "$gate_device" && "$(/usr/bin/stat -f '%i' "$gate_lock")" == "$gate_inode" \
    && "$(sha "$root/run-started-v1.json")" == "$run_started_digest" ]] \
    || die 'Gate 15 launch authorization inputs changed during signing.' 124
  publish_temp_absent "$cms_tmp" "$authorization" 'Gate 15 launch authorization'
  /bin/unlink "$payload_tmp"; /bin/unlink "$decoded_tmp"
}

authorize_launch() {
  local request="$root/launch-request-v1.json" n=0
  while [[ "$n" -lt 120 ]]; do
    if [[ -e "$request" || -L "$request" ]]; then
      publish_launch_authorization
      return 0
    fi
    n=$((n + 1))
    /bin/sleep .25
  done
  die 'the Swift runner did not publish a one-time launch request.' 70
}

run_tool_with_authorization() {
  local tool_status authorizer_status
  authorize_launch &
  live_authorizer_pid=$!
  # The process-group wrapper executes the exact canonical command: "$canonical_tool_path" run --root "$root".
  /usr/bin/python3 -c '
import os, sys
os.setsid()
os.execv(sys.argv[1], [sys.argv[1], "run", "--root", sys.argv[2]])
' "$canonical_tool_path" "$root" &
  live_tool_pid=$!
  set +e
  wait "$live_tool_pid"
  tool_status=$?
  set -e
  live_tool_pid=0
  if /bin/kill -0 "$live_authorizer_pid" >/dev/null 2>&1; then /bin/kill -TERM "$live_authorizer_pid" >/dev/null 2>&1 || true; fi
  set +e
  wait "$live_authorizer_pid" >/dev/null 2>&1
  authorizer_status=$?
  set -e
  live_authorizer_pid=0
  if [[ "$tool_status" == 0 && "$authorizer_status" != 0 ]]; then
    die 'Gate 15 launch authorization helper failed after the runner returned.' 74
  fi
  return "$tool_status"
}

terminate_and_wait_live_children() {
  local pid attempt
  pid="$live_tool_pid"
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    /usr/bin/python3 -c 'import os, signal, sys; os.killpg(int(sys.argv[1]), signal.SIGTERM)' "$pid" >/dev/null 2>&1 || true
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      /bin/kill -0 "$pid" >/dev/null 2>&1 || break
      /bin/sleep .05
    done
    /usr/bin/python3 -c 'import os, signal, sys; os.killpg(int(sys.argv[1]), signal.SIGKILL)' "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
  live_tool_pid=0
  pid="$live_authorizer_pid"
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
    /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
  live_authorizer_pid=0
}

cleanup_on_exit() {
  local status=$?
  trap - INT TERM HUP EXIT
  terminate_and_wait_live_children
  if [[ "$status" != 0 ]]; then cleanup_owned_runtime || status=$?; fi
  exit "$status"
}

on_signal() {
  local signal="$1" status="$2"
  trap - INT TERM HUP EXIT
  terminate_and_wait_live_children
  cleanup_owned_runtime || status=$?
  exit "$status"
}

revalidate() {
  [[ "${1:-}" == revalidate-sample && "${2:-}" == --root && "${3:-}" == "$root" ]] \
    || die 'invalid Gate 15 live-boundary revalidation request.' 64
  validate_inputs
  validate_active_run_binding
  validate_bound_environment
  check_inventory
}

run_live() {
  validate_root
  validate_inputs
  [[ "${HOSTWRIGHT_GATE15_LAUNCH_AUTHORIZATION:-}" == "$root/launch-authorization-v1.cms" ]] \
    || die 'direct Gate 15 live execution requires the canonical one-time launch authorization path.' 74
  [[ "${HOSTWRIGHT_GATE15_LAUNCH_REQUEST:-}" == "$root/launch-request-v1.json" ]] \
    || die 'direct Gate 15 live execution requires the canonical launch request path.' 74
  validate_run_started_marker launch-pending
  validate_bound_environment
  [[ ! -e "$root/failure-v1.tsv" && ! -L "$root/failure-v1.tsv" ]] || die 'Gate 15 root is an immutable failure root; do not rerun it.' 73
  check_clean_boundary
  trap cleanup_on_exit EXIT
  trap 'on_signal INT 130' INT
  trap 'on_signal TERM 143' TERM
  trap 'on_signal HUP 129' HUP
  record_owned_runtime
  ensure_owned_runtime
  write_inventory "$root/runtime-inventory-before-v1.json"
  printf '%s\n' $'schedule\tmarker\tbound_seconds\n2\tconfiguration-churn-and-compaction\t60\n4\tpressure-and-workload-recovery\t120\n8\tplanned-daemon-restart\t120\n16\thelper-process-tree-failure\t120\n32\truntime-recovery\t120' \
    | write_private "$root/fault-schedule-v1.tsv" 'Gate 15 fault schedule' fault-schedule
  export HOSTWRIGHT_GATE15_BOUNDARY_VALIDATOR="$repository_path/scripts/phase09-gate15-live.sh"
  export HOSTWRIGHT_GATE15_ROOT="$root"
  run_tool_with_authorization
  cleanup_owned_runtime
  write_inventory "$root/runtime-inventory-after-v1.json"
}

validate_script_boundary

case "${1:-}" in
  revalidate-sample)
    [[ "$#" == 3 && "$2" == --root ]] || die 'usage: phase09-gate15-live.sh revalidate-sample --root PATH' 64
    export HOSTWRIGHT_GATE15_ROOT="$3"
    validate_root
    revalidate revalidate-sample --root "$3"
    ;;
  run)
    [[ "$#" == 3 && "$2" == --root ]] || die 'usage: phase09-gate15-live.sh run --root PATH' 64
    export HOSTWRIGHT_GATE15_ROOT="$3"
    run_live
    ;;
  preflight)
    [[ "$#" == 3 && "$2" == --root ]] || die 'usage: phase09-gate15-live.sh preflight --root PATH' 64
    export HOSTWRIGHT_GATE15_ROOT="$3"
    validate_root
    validate_inputs
    validate_bound_environment
    check_clean_boundary
    ;;
  *)
    die 'usage: phase09-gate15-live.sh run|revalidate-sample|preflight --root PATH' 64
    ;;
esac
