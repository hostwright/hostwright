#!/usr/bin/env bash
set -euo pipefail

# Gate 2 is deliberately a separate harness.  Gate 1's evidence digest includes
# its script, so extending that script would invalidate its already-passed evidence.
readonly schema='hostwright.phase09.gate02.qualification.manifest.v1'
readonly gate=2
readonly branch='feat/v0.0.2-phase-09'
readonly live_parent='/Volumes/T9/hostwright/qualification'
readonly socket_parent='/Volumes/T9'
readonly signing_fingerprint='A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB'
readonly signing_identifier='hostwright-control'
readonly state_header=$'gate\tcell\tstatus\tsource_digest\tconfig_digest\ttoolchain_digest\tstarted_at\tfinished_at\tstdout_sha256\tstderr_sha256'
readonly ownership_header=$'recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity'

root=''
parent=''
source_commit=''
source_digest_value=''
config_digest_value=''
toolchain_digest_value=''
dirty_state=''
root_lock_created=0
gate_lock_created=0
run_succeeded=0

die() { printf '%s\n' "$1" >&2; exit "${2:-70}"; }
now() { /bin/date -u +%Y-%m-%dT%H:%M:%SZ; }
sha256_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
sha256_stream() { /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'; }

contract() {
  cat <<'EOF'
Phase 09 Gate 2 qualification harness contract v1
Gate 2 — 12.50% — local identity and authentication (#198).
Exactly one Gate 2 qualification may be active. Cells 1..6 are strictly serial and non-overlapping.
Evidence is reusable only when every cell and source/configuration/toolchain digest match.
Failure preserves the evidence root, logs, failure ledger, and both locks; progress freezes.
Live signing uses only the declared Developer ID fingerprint and creates/removes only ledger-recorded resources.
EOF
}

test_mode() { [[ "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" == 1 ]]; }

qualification_parent() {
  if test_mode; then
    : "${HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT:?test parent is required}"
    printf '%s\n' "$HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT"
  else
    [[ -z "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" ]] || die 'test mode must be exactly 1.' 66
    printf '%s\n' "$live_parent"
  fi
}

validate_worktree() {
  local top
  top="$(/bin/realpath "$(git rev-parse --show-toplevel)")"
  [[ "$top" != '/Users/dev/Documents/hostwright' ]] || die "Gate 2 requires branch $branch." 66
  if test_mode; then
    [[ "$top" != '/Users/dev/Documents/hostwright' ]] || die "Gate 2 requires branch $branch." 66
    return
  fi
  [[ "$(git branch --show-current)" == "$branch" ]] || die "Gate 2 requires branch $branch." 66
}

validate_root() {
  : "${HOSTWRIGHT_PHASE09_GATE_ROOT:?HOSTWRIGHT_PHASE09_GATE_ROOT is required}"
  root="$HOSTWRIGHT_PHASE09_GATE_ROOT"
  parent="$(qualification_parent)"
  local canonical_parent user_id
  canonical_parent="$(/bin/realpath "$parent")"
  [[ -d "$parent" && ! -L "$parent" && "$canonical_parent" == "$parent" ]] || die 'qualification parent must be canonical and non-symlinked.' 66
  if test_mode; then
    local test_parent_lower
    test_parent_lower="$(printf '%s' "$canonical_parent" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    [[ "$test_parent_lower" =~ ^(/private)?/var/folders/[^/]+/[^/]+/t/hostwright-phase09-harness-[a-f0-9-]+$ ]] || die 'test parent must be an isolated mktemp root.' 66
  else
    [[ "$canonical_parent" == "$live_parent" ]] || die 'Gate 2 evidence must be directly under the fixed qualification parent.' 66
  fi
  [[ "$root" == /* && -d "$root" && ! -L "$root" && "$(/bin/realpath "$root")" == "$root" ]] || die 'evidence root must be an existing absolute canonical directory.' 66
  [[ "$(/bin/realpath "$(dirname "$root")")" == "$canonical_parent" ]] || die 'evidence root must be directly below the qualification parent.' 66
  [[ "${root##*/}" =~ ^phase09-gate02-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || die 'evidence root must be phase09-gate02- followed by a lowercase UUID.' 66
  user_id="$(id -u)"
  [[ "$(stat -f '%u' "$root")" == "$user_id" && "$(stat -f '%Lp' "$root")" == 700 ]] || die 'evidence root must be current-user-owned and mode 0700.' 66
  parent="$canonical_parent"
}

require_empty_root() { [[ -z "$(/usr/bin/find "$root" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die 'prepare requires an empty evidence root.' 73; }

source_digest() {
  {
    git rev-parse HEAD
    git diff --binary HEAD -- . ':(exclude)tmp'
    while IFS= read -r -d '' path; do
      [[ "$path" == tmp || "$path" == tmp/* || "$path" == .codex || "$path" == .codex/* || "$path" == .claude || "$path" == .claude/* ]] && continue
      printf '%s\0' "$path"; /usr/bin/shasum -a 256 "$path"
    done < <(git ls-files --others --exclude-standard -z | LC_ALL=C /usr/bin/sort -z)
  } | sha256_stream
}

toolchain_report() {
  {
    /usr/bin/sw_vers; xcodebuild -version; swift --version; xcrun --find codesign
    security find-identity -p codesigning -v || printf '%s\n' 'codesigning identity inventory unavailable'
  } 2>&1
}

config_digest() {
  {
    sha256_file "$0"; sha256_file scripts/lint.sh; sha256_file scripts/check-docs.sh
    printf '%s\n' 'swift test --filter HostwrightControlSecurityTests'
    printf '%s\n' 'swift test --filter ControlIdentity(Repository|SecurityAdapter)Tests'
    printf '%s\n' 'swift test --filter HostwrightControlSecurityQualificationToolTests'
    printf '%s\n' 'swift test --filter StateUpgradeTests/testV17SnapshotMigratesToV18AndRestoresExactV17'
    printf '%s\n' 'live signed and ad-hoc Unix socket qualification'
    printf '%s\n' 'scripts/lint.sh; git diff --check; scripts/check-docs.sh'
  } | sha256_stream
}

collect_digests() {
  source_commit="$(git rev-parse HEAD)"; source_digest_value="$(source_digest)"; config_digest_value="$(config_digest)"; toolchain_digest_value="$(toolchain_report | sha256_stream)"
  if test_mode; then
    dirty_state='test-isolated'
  else
    [[ -z "$(git status --porcelain --untracked-files=all -- . ':(exclude)tmp')" ]] || die 'Gate 2 qualification requires an exact clean committed Phase 09 branch.' 73
    dirty_state='clean'
  fi
}

cell_command() {
  case "$1" in
    1) printf '%s\n' 'swift test --filter HostwrightControlSecurityTests' ;;
    2) printf '%s\n' 'swift test --filter ControlIdentity(Repository|SecurityAdapter)Tests' ;;
    3) printf '%s\n' 'swift test --filter HostwrightControlSecurityQualificationToolTests' ;;
    4) printf '%s\n' 'swift test --filter StateUpgradeTests/testV17SnapshotMigratesToV18AndRestoresExactV17' ;;
    5) printf '%s\n' 'live signed and ad-hoc Unix socket qualification' ;;
    6) printf '%s\n' 'scripts/lint.sh; git diff --check; scripts/check-docs.sh' ;;
    *) die 'unknown Gate 2 cell.' 70 ;;
  esac
}

cell_classes() {
  case "$1" in
    1) printf '%s\n' '["U","S","R","L"]' ;; 2) printf '%s\n' '["U","I","M","S","R"]' ;; 3) printf '%s\n' '["U","S"]' ;;
    4) printf '%s\n' '["M","R"]' ;; 5) printf '%s\n' '["I","L","S","R"]' ;; 6) printf '%s\n' '["I"]' ;;
    *) die 'unknown Gate 2 evidence class.' 70 ;;
  esac
}

evidence_by_cell_json() {
  local cell
  for cell in 1 2 3 4 5 6; do
    /usr/bin/jq -n --argjson cell "$cell" --arg command "$(cell_command "$cell")" --argjson evidenceClasses "$(cell_classes "$cell")" '{cell:$cell,command:$command,evidenceClasses:$evidenceClasses}'
  done | /usr/bin/jq -s .
}

write_manifest() {
  local status="$1" completed_at="${2:-}"
  /usr/bin/jq -n --arg schema "$schema" --argjson gate "$gate" --arg sourceCommit "$source_commit" --arg sourceDigest "$source_digest_value" --arg configDigest "$config_digest_value" --arg toolchainDigest "$toolchain_digest_value" --arg dirtyState "$dirty_state" --arg startedAt "$(now)" --arg completedAt "$completed_at" --arg status "$status" --rawfile toolchainReport "$root/toolchain-v1.txt" --argjson evidenceByCell "$(evidence_by_cell_json)" '{schema:$schema,gate:$gate,sourceCommit:$sourceCommit,sourceDigest:$sourceDigest,configDigest:$configDigest,toolchainDigest:$toolchainDigest,dirtyState:$dirtyState,cellOrder:[1,2,3,4,5,6],evidenceByCell:$evidenceByCell,toolchainReport:$toolchainReport,startedAt:$startedAt,completedAt:(if $completedAt == "" then null else $completedAt end),status:$status}' > "$root/manifest-v1.json"
  chmod 600 "$root/manifest-v1.json"
}

prepare() {
  printf '%s\n' "$ownership_header" > "$root/ownership-v1.tsv"; printf '%s\n' "$state_header" > "$root/state-v1.tsv"; toolchain_report > "$root/toolchain-v1.txt"
  chmod 600 "$root/ownership-v1.tsv" "$root/state-v1.tsv" "$root/toolchain-v1.txt"; write_manifest prepared
}

validate_prepared() {
  [[ -f "$root/manifest-v1.json" && -f "$root/ownership-v1.tsv" && -f "$root/state-v1.tsv" && -f "$root/toolchain-v1.txt" ]] || die 'run requires a prepared evidence root.' 73
  [[ "$(head -n 1 "$root/ownership-v1.tsv")" == "$ownership_header" && "$(head -n 1 "$root/state-v1.tsv")" == "$state_header" ]] || die 'prepared evidence headers are invalid.' 73
  [[ "$(/usr/bin/jq -r '.schema' "$root/manifest-v1.json")" == "$schema" && "$(/usr/bin/jq -r '.gate' "$root/manifest-v1.json")" == 2 ]] || die 'prepared manifest is not Gate 2 evidence.' 73
  [[ "$(/usr/bin/jq -r '.sourceDigest' "$root/manifest-v1.json")" == "$source_digest_value" && "$(/usr/bin/jq -r '.configDigest' "$root/manifest-v1.json")" == "$config_digest_value" && "$(/usr/bin/jq -r '.toolchainDigest' "$root/manifest-v1.json")" == "$toolchain_digest_value" ]] || die 'prepared evidence dependencies changed; preserve this root and prepare a new one.' 73
}

append_state() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$gate" "$1" "$2" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" "$3" "$4" "$5" "$6" >> "$root/state-v1.tsv"; chmod 600 "$root/state-v1.tsv"; }
append_failure() {
  [[ -f "$root/failure-v1.tsv" ]] || printf '%s\n' $'recorded_at\tgate\tcell\texit_status\tcommand\tsource_digest\tconfig_digest\ttoolchain_digest\tstdout_sha256\tstderr_sha256' > "$root/failure-v1.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$gate" "$1" "$2" "$3" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" "$4" "$5" >> "$root/failure-v1.tsv"; chmod 600 "$root/failure-v1.tsv"
}

record_temporary_root() {
  local runtime="$1" device inode
  [[ "$runtime" == "$root"/* && "$(dirname "$runtime")" == "$root" && -d "$runtime" && ! -L "$runtime" && "$(stat -f '%u' "$runtime")" == "$(id -u)" && "$(stat -f '%Lp' "$runtime")" == 700 ]] || die 'live runtime must be a current-user-owned 0700 direct child of the evidence root.' 70
  device="$(stat -f '%d' "$runtime")"; inode="$(stat -f '%i' "$runtime")"
  printf '%s\ttemporary-root\tgate02-live-runtime\t%s\t%s\t%s\tpath=runtime;scope=gate02-live\n' "$(now)" "$runtime" "$device" "$inode" >> "$root/ownership-v1.tsv"; chmod 600 "$root/ownership-v1.tsv"
}

record_socket_root() {
  local socket_root="$1" device inode
  [[ "$socket_root" =~ ^/Volumes/T9/\.hwp09g2-[a-f0-9]{12}$ && -d "$socket_root" && ! -L "$socket_root" && "$(/bin/realpath "$socket_root")" == "$socket_root" && "$(stat -f '%u' "$socket_root")" == "$(id -u)" && "$(stat -f '%Lp' "$socket_root")" == 700 ]] || die 'live socket root must be a canonical current-user-owned 0700 short path.' 70
  device="$(stat -f '%d' "$socket_root")"; inode="$(stat -f '%i' "$socket_root")"
  printf '%s\ttemporary-root\tgate02-live-socket-root\t%s\t%s\t%s\tpath=socket-root;scope=gate02-live\n' "$(now)" "$socket_root" "$device" "$inode" >> "$root/ownership-v1.tsv"
  chmod 600 "$root/ownership-v1.tsv"
}

record_runtime_file() {
  local identifier="$1" path="$2" device inode
  [[ "$identifier" =~ ^(signed-client|adhoc-client|state.sqlite|state.sqlite-wal|state.sqlite-shm|state-access-lock|state-access-writer)$ && "$path" == "$root/live-runtime-v1/"* && "$(dirname "$path")" == "$root/live-runtime-v1" && -f "$path" && ! -L "$path" && "$(stat -f '%u' "$path")" == "$(id -u)" ]] || die 'live artifact is not an owned direct runtime file.' 70
  device="$(stat -f '%d' "$path")"; inode="$(stat -f '%i' "$path")"
  printf '%s\ttemporary-file\t%s\t%s\t%s\t%s\tpath=%s;scope=gate02-live\n' "$(now)" "$identifier" "$path" "$device" "$inode" "$identifier" >> "$root/ownership-v1.tsv"
  chmod 600 "$root/ownership-v1.tsv"
}

validate_owned_runtime_file() {
  local identifier="$1" runtime="$2" entry path device inode
  entry="$(/usr/bin/awk -F $'\t' -v identifier="$identifier" '$2 == "temporary-file" && $3 == identifier {print $4 "\t" $5 "\t" $6}' "$root/ownership-v1.tsv")"
  [[ -n "$entry" && "$entry" != *$'\n'* ]] || die 'owned live artifact ledger entry is missing.' 70
  path="${entry%%$'\t'*}"; device="${entry#*$'\t'}"; device="${device%%$'\t'*}"; inode="${entry##*$'\t'}"
  [[ "$(dirname "$path")" == "$runtime" ]] || die 'owned live artifact escaped the recorded runtime root.' 70
  case "$identifier" in
    signed-client|adhoc-client|state.sqlite|state.sqlite-wal|state.sqlite-shm) [[ "$path" == "$runtime/$identifier" ]] ;;
    state-access-lock) [[ "${path##*/}" =~ ^\.hostwright-[a-f0-9]{16}-access-v1\.lock$ ]] ;;
    state-access-writer) [[ "${path##*/}" =~ ^\.hostwright-[a-f0-9]{16}-access-v1\.lock\.writer$ ]] ;;
    *) false ;;
  esac || die 'owned live artifact path does not match the frozen allowlist.' 70
  [[ -f "$path" && ! -L "$path" && "$(/bin/realpath "$path")" == "$path" && "$(stat -f '%u' "$path")" == "$(id -u)" && "$(stat -f '%d' "$path")" == "$device" && "$(stat -f '%i' "$path")" == "$inode" ]] || die 'owned live artifact identity changed; cleanup is refused.' 70
  printf '%s\n' "$path"
}

record_live_artifact_inventory() {
  local runtime="$1" path name count=0 access_lock='' access_writer=''
  while IFS= read -r -d '' path; do
    name="${path##*/}"
    case "$name" in
      signed-client|adhoc-client|state.sqlite|state.sqlite-wal|state.sqlite-shm)
        record_runtime_file "$name" "$path"; count=$((count + 1)) ;;
      *)
        if [[ "$name" =~ ^\.hostwright-[a-f0-9]{16}-access-v1\.lock$ ]]; then
          [[ -z "$access_lock" ]] || die 'live runtime contains duplicate access lock artifacts.' 70
          access_lock="$path"; record_runtime_file state-access-lock "$path"; count=$((count + 1))
        elif [[ "$name" =~ ^\.hostwright-[a-f0-9]{16}-access-v1\.lock\.writer$ ]]; then
          [[ -z "$access_writer" ]] || die 'live runtime contains duplicate access writer artifacts.' 70
          access_writer="$path"; record_runtime_file state-access-writer "$path"; count=$((count + 1))
        else
          die 'live runtime contains an unledgered child; cleanup is refused.' 70
        fi
        ;;
    esac
  done < <(/usr/bin/find "$runtime" -mindepth 1 -maxdepth 1 -print0)
  [[ "$count" == 7 && -n "$access_lock" && "$access_writer" == "$access_lock.writer" ]] || die 'live runtime must contain exactly the frozen seven-artifact allowlist.' 70
}

cleanup_live_runtime() {
  local runtime="$1" device inode entry item path
  entry="$(/usr/bin/awk -F $'\t' '$2 == "temporary-root" && $3 == "gate02-live-runtime" {print $4 "\t" $5 "\t" $6}' "$root/ownership-v1.tsv")"
  [[ "$entry" == "$runtime"$'\t'* ]] || die 'owned live runtime ledger entry is missing.' 70
  device="${entry#*$'\t'}"; device="${device%%$'\t'*}"; inode="${entry##*$'\t'}"
  [[ -d "$runtime" && ! -L "$runtime" && "$(/bin/realpath "$runtime")" == "$runtime" && "$(stat -f '%d' "$runtime")" == "$device" && "$(stat -f '%i' "$runtime")" == "$inode" ]] || die 'owned live runtime identity changed; cleanup is refused.' 70
  for item in signed-client adhoc-client state.sqlite state.sqlite-wal state.sqlite-shm state-access-lock state-access-writer; do
    path="$(validate_owned_runtime_file "$item" "$runtime")"
    /bin/unlink "$path"
  done
  /bin/rmdir "$runtime"
}

cleanup_socket_root() {
  local socket_root="$1" entry device inode
  entry="$(/usr/bin/awk -F $'\t' '$2 == "temporary-root" && $3 == "gate02-live-socket-root" {print $4 "\t" $5 "\t" $6}' "$root/ownership-v1.tsv")"
  [[ "$entry" == "$socket_root"$'\t'* ]] || die 'owned live socket root ledger entry is missing.' 70
  device="${entry#*$'\t'}"; device="${device%%$'\t'*}"; inode="${entry##*$'\t'}"
  [[ -d "$socket_root" && ! -L "$socket_root" && "$(/bin/realpath "$socket_root")" == "$socket_root" && "$(stat -f '%u' "$socket_root")" == "$(id -u)" && "$(stat -f '%d' "$socket_root")" == "$device" && "$(stat -f '%i' "$socket_root")" == "$inode" ]] || die 'owned live socket root identity changed; cleanup is refused.' 70
  [[ -z "$(/usr/bin/find "$socket_root" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die 'live socket root is not empty after the tool exited; cleanup is refused.' 70
  /bin/rmdir "$socket_root"
}

run_live_qualification() {
  swift build --product hostwright-control-security-qualification
  local bin tool runtime socket_root socket_suffix signed adhoc state result canonical
  bin="$(swift build --show-bin-path)"; tool="$bin/hostwright-control-security-qualification"
  [[ -x "$tool" ]] || die 'Gate 2 qualification product was not built.' 70
  runtime="$root/live-runtime-v1"; mkdir "$runtime"; chmod 700 "$runtime"; record_temporary_root "$runtime"
  [[ -d "$socket_parent" && ! -L "$socket_parent" && "$(/bin/realpath "$socket_parent")" == "$socket_parent" ]] || die 'Gate 2 socket parent is unsafe.' 70
  socket_suffix="$(printf '%s' "$root" | sha256_stream | /usr/bin/cut -c1-12)"
  socket_root="$socket_parent/.hwp09g2-$socket_suffix"
  mkdir "$socket_root"; chmod 700 "$socket_root"; record_socket_root "$socket_root"
  signed="$runtime/signed-client"; adhoc="$runtime/adhoc-client"; state="$runtime/state.sqlite"
  /bin/cp "$tool" "$signed"; /bin/cp "$tool" "$adhoc"
  codesign --force --sign "$signing_fingerprint" --identifier "$signing_identifier" "$signed"
  codesign --force --sign - --identifier "$signing_identifier" "$adhoc"
  local tool_status=0
  if result="$("$tool" server --signed-client "$signed" --adhoc-client "$adhoc" --state-db "$state" --socket-root "$socket_root")"; then
    tool_status=0
  else
    tool_status=$?
  fi
  record_live_artifact_inventory "$runtime"
  cleanup_socket_root "$socket_root"
  if [[ "$tool_status" != 0 ]]; then
    cleanup_live_runtime "$runtime"
    printf '%s\n' 'live qualification executable failed.' >&2
    return "$tool_status"
  fi
  if [[ -z "$result" ]]; then
    cleanup_live_runtime "$runtime"
    printf '%s\n' 'live qualification executable returned an empty result.' >&2
    return 70
  fi
  [[ "${#result}" -le 1048576 ]] || die 'live result exceeds the frozen response bound.' 70
  canonical="$(printf '%s' "$result" | /usr/bin/jq -cS .)"
  [[ "$canonical" == "$result" ]] || die 'live result is not canonical JSON.' 70
  printf '%s' "$result" | /usr/bin/jq -e 'keys == ["adHoc","qualification","signed"] and .qualification == "phase09-gate2-live-v1" and (.signed.mode == "signed") and (.adHoc.mode == "adHoc") and ([.signed,.adHoc][] | (.subjectID | test("^[A-Za-z0-9._:-]{1,128}$")) and (.sessionID | test("^[0-9A-Fa-f-]{36}$")) and (.nativeCDHashLength == 20 or .nativeCDHashLength == 32) and .revocationStatus == "inactive")' >/dev/null
  printf '%s\n' "$result"
  cleanup_live_runtime "$runtime"
}

run_hygiene() { scripts/lint.sh; git diff --check; scripts/check-docs.sh; }
run_cell() {
  case "$1" in
    1) swift test --filter HostwrightControlSecurityTests ;;
    2) swift test --filter 'ControlIdentity(Repository|SecurityAdapter)Tests' ;;
    3) swift test --filter HostwrightControlSecurityQualificationToolTests ;;
    4) swift test --filter StateUpgradeTests/testV17SnapshotMigratesToV18AndRestoresExactV17 ;;
    5) run_live_qualification ;;
    6) run_hygiene ;;
    *) die 'unknown Gate 2 cell.' 70 ;;
  esac
}

all_reusable() {
  local cell stdout_sha stderr_sha expected_stdout expected_stderr
  for cell in 1 2 3 4 5 6; do
    /usr/bin/awk -F $'\t' -v source="$source_digest_value" -v config="$config_digest_value" -v toolchain="$toolchain_digest_value" -v cell="$cell" '$1 == 2 && $2 == cell && $3 == "pass" && $4 == source && $5 == config && $6 == toolchain {found=1} END {exit(found ? 0 : 1)}' "$root/state-v1.tsv" || return 1
    [[ -f "$root/cell-$(printf '%02d' "$cell").stdout.log" && -f "$root/cell-$(printf '%02d' "$cell").stderr.log" ]] || return 1
    stdout_sha="$(sha256_file "$root/cell-$(printf '%02d' "$cell").stdout.log")"; stderr_sha="$(sha256_file "$root/cell-$(printf '%02d' "$cell").stderr.log")"
    expected_stdout="$(/usr/bin/awk -F $'\t' -v cell="$cell" '$1 == 2 && $2 == cell && $3 == "pass" {value=$9} END {print value}' "$root/state-v1.tsv")"; expected_stderr="$(/usr/bin/awk -F $'\t' -v cell="$cell" '$1 == 2 && $2 == cell && $3 == "pass" {value=$10} END {print value}' "$root/state-v1.tsv")"
    [[ "$stdout_sha" == "$expected_stdout" && "$stderr_sha" == "$expected_stderr" ]] || return 1
  done
}

release_locks_on_success() {
  if [[ "$run_succeeded" == 1 && "$root_lock_created" == 1 && "$gate_lock_created" == 1 ]]; then
    /bin/rmdir "$root/active-run-v1"; /bin/rmdir "$parent/.phase09-gate02-active-v1"; root_lock_created=0; gate_lock_created=0
  fi
}

write_evidence_digest() {
  (cd "$root" && for file in manifest-v1.json state-v1.tsv ownership-v1.tsv toolchain-v1.txt gate-active-run-v1-info.tsv cell-*.stdout.log cell-*.stderr.log; do [[ -f "$file" ]] && /usr/bin/shasum -a 256 "$file"; done | LC_ALL=C /usr/bin/sort) > "$root/evidence-v1.sha256"; chmod 600 "$root/evidence-v1.sha256"
}

run() {
  validate_prepared
  if all_reusable; then
    [[ "$(/usr/bin/jq -r '.status' "$root/manifest-v1.json")" == passed && -f "$root/evidence-v1.sha256" ]] || die 'reusable records are incomplete; preserve this root.' 73
    printf '%s\n' 'Gate 2 evidence is valid and reused; no cells were rerun.'; return
  fi
  local gate_lock="$parent/.phase09-gate02-active-v1" cell command started finished status stdout stderr stdout_sha stderr_sha
  [[ ! -e "$root/active-run-v1" ]] || die 'An active qualification lock already exists; do not rerun.' 75
  [[ ! -e "$gate_lock" ]] || die 'A gate-wide active qualification lock already exists; do not rerun.' 75
  mkdir "$gate_lock"; chmod 700 "$gate_lock"; printf '%s\n' $'root\tpid\tstarted_at\tsource_digest\tconfig_digest\ttoolchain_digest' > "$gate_lock/info-v1.tsv"; printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$root" "$$" "$(now)" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" >> "$gate_lock/info-v1.tsv"; chmod 600 "$gate_lock/info-v1.tsv"; gate_lock_created=1
  mkdir "$root/active-run-v1"; chmod 700 "$root/active-run-v1"; root_lock_created=1; trap release_locks_on_success EXIT
  for cell in 1 2 3 4 5 6; do
    command="$(cell_command "$cell")"; stdout="$root/cell-$(printf '%02d' "$cell").stdout.log"; stderr="$root/cell-$(printf '%02d' "$cell").stderr.log"
    [[ ! -e "$stdout" && ! -e "$stderr" ]] || die 'Cell logs already exist; preserve this root and do not rerun evidence.' 73
    started="$(now)"; set +e; (set -e; run_cell "$cell") > "$stdout" 2> "$stderr"; status=$?; set -e; chmod 600 "$stdout" "$stderr"; stdout_sha="$(sha256_file "$stdout")"; stderr_sha="$(sha256_file "$stderr")"; finished="$(now)"
    if [[ "$status" != 0 ]]; then append_state "$cell" failed "$started" "$finished" "$stdout_sha" "$stderr_sha"; append_failure "$cell" "$status" "$command" "$stdout_sha" "$stderr_sha"; write_manifest failed "$finished"; die "Gate 2 cell $cell failed; progress is frozen and active locks are preserved." "$status"; fi
    append_state "$cell" pass "$started" "$finished" "$stdout_sha" "$stderr_sha"
  done
  write_manifest passed "$(now)"; /bin/mv "$gate_lock/info-v1.tsv" "$root/gate-active-run-v1-info.tsv"; chmod 600 "$root/gate-active-run-v1-info.tsv"; write_evidence_digest; run_succeeded=1; release_locks_on_success; printf '%s\n' 'Gate 2 qualification passed.'
}

main() {
  [[ "$#" -ge 1 ]] || die 'usage: phase09-gate02-qualification.sh <contract|prepare|run>.' 64
  case "$1" in
    contract) [[ "$#" == 1 ]] || die 'contract accepts no arguments.' 64; contract ;;
    prepare) [[ "$#" == 2 && "$2" == 2 ]] || die 'Gate 2 harness accepts only prepare 2.' 64; validate_worktree; validate_root; require_empty_root; collect_digests; prepare; printf '%s\n' 'Gate 2 evidence root prepared.' ;;
    run) [[ "$#" == 2 && "$2" == 2 ]] || die 'Gate 2 harness accepts only run 2.' 64; validate_worktree; validate_root; collect_digests; run ;;
    *) die 'unknown Gate 2 qualification command.' 64 ;;
  esac
}

main "$@"
