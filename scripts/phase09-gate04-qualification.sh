#!/usr/bin/env bash
set -euo pipefail

readonly schema='hostwright.phase09.gate04.qualification.manifest.v1'
readonly gate=4
readonly branch='feat/v0.0.2-phase-09'
readonly live_parent='/Volumes/T9/hostwright/qualification'
readonly signing_fingerprint='A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB'
readonly signing_identity='Developer ID Application: Dev Trivedi (993YC3JY4Q)'
readonly signing_identifier='dev.hostwright.audit-qualification'
readonly state_header=$'gate\tcell\tstatus\tsource_digest\tconfig_digest\ttoolchain_digest\tstarted_at\tfinished_at\tstdout_sha256\tstderr_sha256'
readonly ownership_header=$'recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity'

root=''
parent=''
source_commit=''
source_digest_value=''
config_digest_value=''
toolchain_digest_value=''
root_lock_created=0
gate_lock_created=0
run_succeeded=0

die() { printf '%s\n' "$1" >&2; exit "${2:-70}"; }
now() { /bin/date -u +%Y-%m-%dT%H:%M:%SZ; }
sha256_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
sha256_stream() { /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'; }

contract() {
  cat <<'EOF'
Phase 09 Gate 4 qualification harness contract v1
Gate 4 — 25.00% — immutable tamper-evident audit (#201).
Exactly one Gate 4 qualification may be active. Cells 1..6 run strictly serially.
The six cells provide focused unit, integration, live-runtime, migration/compatibility,
security, and resilience evidence. Passing cells are reused only when the exact
source, configuration, toolchain, logs, and recorded checksums remain unchanged.
Failure preserves the immutable evidence root, failure ledger, logs, and active locks.
The live cell signs one isolated qualification executable with the declared Developer ID,
records every temporary file/root and Keychain service before exact owned-only cleanup,
and verifies the real v19 audit format inside the current additive state schema plus export on local macOS.
EOF
}

test_mode() { [[ "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" == 1 ]]; }

qualification_parent() {
  if test_mode; then
    : "${HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT:?test parent is required}"
    printf '%s\n' "$HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT"
  else
    [[ -z "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" ]] \
      || die 'test mode must be exactly 1.' 66
    printf '%s\n' "$live_parent"
  fi
}

validate_worktree() {
  [[ "$(git branch --show-current)" == "$branch" ]] \
    || die "Gate 4 requires branch $branch." 66
  local top
  top="$(/bin/realpath "$(git rev-parse --show-toplevel)")"
  [[ "$top" == '/Users/dev/Documents/hostwright-phase09' ]] \
    || die 'Gate 4 requires the isolated Phase 09 worktree.' 66
  [[ "$top" != '/Users/dev/Documents/hostwright' ]] \
    || die 'Gate 4 refuses the protected Phase 08 worktree.' 66
}

validate_root() {
  : "${HOSTWRIGHT_PHASE09_GATE_ROOT:?HOSTWRIGHT_PHASE09_GATE_ROOT is required}"
  root="$HOSTWRIGHT_PHASE09_GATE_ROOT"
  parent="$(qualification_parent)"
  local canonical_parent
  canonical_parent="$(/bin/realpath "$parent")"
  [[ -d "$parent" && ! -L "$parent" && "$canonical_parent" == "$parent" ]] \
    || die 'qualification parent must be canonical and non-symlinked.' 66
  if test_mode; then
    [[ "$canonical_parent" == /private/var/folders/*/T/hostwright-phase09-harness-* \
        || "$canonical_parent" == /var/folders/*/T/hostwright-phase09-harness-* ]] \
      || die 'test parent must be an isolated mktemp root.' 66
  else
    [[ "$canonical_parent" == "$live_parent" ]] \
      || die 'Gate 4 evidence must use the fixed qualification parent.' 66
  fi
  [[ "$root" == /* && -d "$root" && ! -L "$root" \
      && "$(/bin/realpath "$root")" == "$root" ]] \
    || die 'evidence root must be an existing canonical directory.' 66
  [[ "$(/bin/realpath "$(dirname "$root")")" == "$canonical_parent" ]] \
    || die 'evidence root must be directly below the qualification parent.' 66
  [[ "${root##*/}" =~ ^phase09-gate04-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] \
    || die 'evidence root name is not a Gate 4 lowercase UUID.' 66
  [[ "$(stat -f '%u' "$root")" == "$(id -u)" && "$(stat -f '%Lp' "$root")" == 700 ]] \
    || die 'evidence root must be current-user-owned and mode 0700.' 66
  parent="$canonical_parent"
}

require_empty_root() {
  [[ -z "$(/usr/bin/find "$root" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || die 'prepare requires an empty evidence root.' 73
}

source_digest() {
  {
    git rev-parse HEAD
    git diff --binary HEAD -- . ':(exclude)tmp'
    while IFS= read -r -d '' path; do
      [[ "$path" == tmp || "$path" == tmp/* || "$path" == .codex \
          || "$path" == .codex/* || "$path" == .claude || "$path" == .claude/* ]] \
        && continue
      printf '%s\0' "$path"
      /usr/bin/shasum -a 256 "$path"
    done < <(git ls-files --others --exclude-standard -z | LC_ALL=C /usr/bin/sort -z)
  } | sha256_stream
}

toolchain_report() {
  {
    /usr/bin/sw_vers
    xcodebuild -version
    swift --version
    xcrun --find codesign
    security find-identity -p codesigning -v
  } 2>&1
}

cell_command() {
  case "$1" in
    1) printf '%s\n' "swift test --filter 'TamperEvidentAuditTrailTests/(testAppendVerifyAndExportHappyPath|testP256RotationContinuityAndSignedPrefixRetention)'" ;;
    2) printf '%s\n' "swift test --filter 'PersistentControlAuditIntegrationTests|HostwrightDaemonControlServiceTests'" ;;
    3) printf '%s\n' 'signed hostwright-audit-qualification local Keychain/state verify/export cycle' ;;
    4) printf '%s\n' "swift test --filter 'AuditSchemaV19MigrationTests'" ;;
    5) printf '%s\n' "swift test --filter 'TamperEvidentAuditTrailTests/(testModificationDeletionReorderAndTruncationAreDetected|testActiveKeySubstitutionIsDetectedBeforeAnotherAppend|testBackwardClockIsRejectedWithoutCorruptingTheTrail)|PersistentControlAuditIntegrationTests/testAuditFailureFailsClosedForMutationWhileReadOnlyOperationRemainsCallable'" ;;
    6) printf '%s\n' "swift test --filter 'TamperEvidentAuditTrailTests/(testSigningFailureAndExternalHeadStoreCrashRecovery|testPendingRotationRecoversAcrossActivationFailure)|StateMaintenanceTests/(testRecoveryHandlesEveryDurableRestoreCheckpointWithoutInventingState|testRecoveryHandlesEveryTornRestoreMutationWindow)'; swift build --product hostwrightd; swift build --product hostwright-control; scripts/lint.sh; git diff --check; scripts/check-docs.sh" ;;
    *) die 'unknown Gate 4 cell.' 70 ;;
  esac
}

cell_classes() {
  case "$1" in
    1) printf '%s\n' '["U"]' ;;
    2) printf '%s\n' '["I"]' ;;
    3) printf '%s\n' '["L"]' ;;
    4) printf '%s\n' '["M"]' ;;
    5) printf '%s\n' '["S"]' ;;
    6) printf '%s\n' '["R","I"]' ;;
    *) die 'unknown Gate 4 evidence class.' 70 ;;
  esac
}

config_digest() {
  {
    sha256_file "$0"
    sha256_file contracts/v0.0.2/versions.json
    sha256_file scripts/lint.sh
    sha256_file scripts/check-docs.sh
    local cell
    for cell in 1 2 3 4 5 6; do
      cell_command "$cell"
      cell_classes "$cell"
    done
  } | sha256_stream
}

collect_digests() {
  source_commit="$(git rev-parse HEAD)"
  source_digest_value="$(source_digest)"
  config_digest_value="$(config_digest)"
  toolchain_digest_value="$(toolchain_report | sha256_stream)"
  if ! test_mode; then
    [[ -z "$(git status --porcelain --untracked-files=all -- . ':(exclude)tmp')" ]] \
      || die 'Gate 4 qualification requires an exact clean committed branch.' 73
  fi
}

evidence_by_cell_json() {
  local cell
  for cell in 1 2 3 4 5 6; do
    /usr/bin/jq -n \
      --argjson cell "$cell" \
      --arg command "$(cell_command "$cell")" \
      --argjson evidenceClasses "$(cell_classes "$cell")" \
      '{cell:$cell,command:$command,evidenceClasses:$evidenceClasses}'
  done | /usr/bin/jq -s .
}

prepare() {
  printf '%s\n' "$ownership_header" > "$root/ownership-v1.tsv"
  printf '%s\n' "$state_header" > "$root/state-v1.tsv"
  toolchain_report > "$root/toolchain-v1.txt"
  /usr/bin/jq -n \
    --arg schema "$schema" \
    --argjson gate "$gate" \
    --arg sourceCommit "$source_commit" \
    --arg sourceDigest "$source_digest_value" \
    --arg configDigest "$config_digest_value" \
    --arg toolchainDigest "$toolchain_digest_value" \
    --arg startedAt "$(now)" \
    --argjson evidenceByCell "$(evidence_by_cell_json)" \
    '{schema:$schema,gate:$gate,sourceCommit:$sourceCommit,sourceDigest:$sourceDigest,configDigest:$configDigest,toolchainDigest:$toolchainDigest,cellOrder:[1,2,3,4,5,6],evidenceByCell:$evidenceByCell,startedAt:$startedAt,completedAt:null,status:"prepared"}' \
    > "$root/manifest-v1.json"
  chmod 600 "$root"/*
}

validate_prepared() {
  local file
  for file in manifest-v1.json ownership-v1.tsv state-v1.tsv toolchain-v1.txt; do
    [[ -f "$root/$file" && ! -L "$root/$file" ]] \
      || die 'run requires a complete prepared evidence root.' 73
  done
  [[ "$(head -n 1 "$root/ownership-v1.tsv")" == "$ownership_header" \
      && "$(head -n 1 "$root/state-v1.tsv")" == "$state_header" ]] \
    || die 'prepared evidence headers are invalid.' 73
  [[ "$(/usr/bin/jq -r '.schema' "$root/manifest-v1.json")" == "$schema" \
      && "$(/usr/bin/jq -r '.gate' "$root/manifest-v1.json")" == 4 \
      && "$(/usr/bin/jq -r '.sourceDigest' "$root/manifest-v1.json")" == "$source_digest_value" \
      && "$(/usr/bin/jq -r '.configDigest' "$root/manifest-v1.json")" == "$config_digest_value" \
      && "$(/usr/bin/jq -r '.toolchainDigest' "$root/manifest-v1.json")" == "$toolchain_digest_value" ]] \
    || die 'prepared evidence dependencies changed; preserve this root.' 73
}

record_live_root() {
  local runtime="$1" device inode
  [[ "$runtime" == "$root/live-runtime-v1" && -d "$runtime" && ! -L "$runtime" \
      && "$(/bin/realpath "$runtime")" == "$runtime" \
      && "$(stat -f '%u' "$runtime")" == "$(id -u)" \
      && "$(stat -f '%Lp' "$runtime")" == 700 ]] \
    || die 'Gate 4 live runtime root is unsafe.' 70
  device="$(stat -f '%d' "$runtime")"
  inode="$(stat -f '%i' "$runtime")"
  printf '%s\ttemporary-root\tgate04-live-runtime\t%s\t%s\t%s\tpath=live-runtime-v1;scope=gate04-live\n' \
    "$(now)" "$runtime" "$device" "$inode" >> "$root/ownership-v1.tsv"
  chmod 600 "$root/ownership-v1.tsv"
}

record_keychain_service() {
  local service="$1"
  [[ "$service" =~ ^dev\.hostwright\.audit\.qualification\.[a-f0-9]{16}$ ]] \
    || die 'Gate 4 live Keychain service is outside the frozen namespace.' 70
  printf '%s\tkeychain-service\tgate04-audit-keychain\t-\t-\t-\tservice=%s;scope=gate04-live\n' \
    "$(now)" "$service" >> "$root/ownership-v1.tsv"
  chmod 600 "$root/ownership-v1.tsv"
}

record_live_file() {
  local runtime="$1" path="$2" name device inode
  name="${path##*/}"
  [[ "$(dirname "$path")" == "$runtime" && -f "$path" && ! -L "$path" \
      && "$(/bin/realpath "$path")" == "$path" \
      && "$(stat -f '%u' "$path")" == "$(id -u)" ]] \
    || die 'Gate 4 live artifact is not an owned direct regular file.' 70
  case "$name" in
    signed-audit-tool|state.sqlite|state.sqlite-wal|state.sqlite-shm) ;;
    *)
      [[ "$name" =~ ^\.hostwright-[a-f0-9]{16}-access-v1\.lock(\.writer)?$ ]] \
        || die 'Gate 4 live runtime contains an unowned file.' 70
      ;;
  esac
  device="$(stat -f '%d' "$path")"
  inode="$(stat -f '%i' "$path")"
  printf '%s\ttemporary-file\t%s\t%s\t%s\t%s\tname=%s;scope=gate04-live\n' \
    "$(now)" "$name" "$path" "$device" "$inode" "$name" >> "$root/ownership-v1.tsv"
  chmod 600 "$root/ownership-v1.tsv"
}

record_live_inventory() {
  local runtime="$1" path count=0 recorded
  while IFS= read -r -d '' path; do
    recorded="$(/usr/bin/awk -F $'\t' -v path="$path" '$2 == "temporary-file" && $4 == path {count++} END {print count + 0}' "$root/ownership-v1.tsv")"
    [[ "$recorded" == 1 ]] || {
      [[ "$recorded" == 0 ]] || die 'Gate 4 live artifact has duplicate ledger records.' 70
      record_live_file "$runtime" "$path"
    }
    count=$((count + 1))
  done < <(/usr/bin/find "$runtime" -mindepth 1 -maxdepth 1 -type f -print0)
  [[ "$count" -ge 4 ]] || die 'Gate 4 live runtime inventory is incomplete.' 70
  [[ -f "$runtime/signed-audit-tool" && -f "$runtime/state.sqlite" ]] \
    || die 'Gate 4 live runtime lacks its signed tool or state database.' 70
  [[ -z "$(/usr/bin/find "$runtime" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]] \
    || die 'Gate 4 live runtime contains a non-file child.' 70
}

cleanup_live_runtime() {
  local runtime="$1" root_entry root_device root_inode path device inode
  root_entry="$(/usr/bin/awk -F $'\t' '$2 == "temporary-root" && $3 == "gate04-live-runtime" {print $4 "\t" $5 "\t" $6}' "$root/ownership-v1.tsv")"
  [[ -n "$root_entry" && "$root_entry" != *$'\n'* ]] \
    || die 'Gate 4 live root ledger entry is missing.' 70
  root_device="${root_entry#*$'\t'}"
  root_device="${root_device%%$'\t'*}"
  root_inode="${root_entry##*$'\t'}"
  [[ "$root_entry" == "$runtime"$'\t'* && -d "$runtime" && ! -L "$runtime" \
      && "$(/bin/realpath "$runtime")" == "$runtime" \
      && "$(stat -f '%d' "$runtime")" == "$root_device" \
      && "$(stat -f '%i' "$runtime")" == "$root_inode" ]] \
    || die 'Gate 4 live root identity changed; cleanup is refused.' 70
  while IFS=$'\t' read -r path device inode; do
    [[ "$(dirname "$path")" == "$runtime" && -f "$path" && ! -L "$path" \
        && "$(/bin/realpath "$path")" == "$path" \
        && "$(stat -f '%d' "$path")" == "$device" \
        && "$(stat -f '%i' "$path")" == "$inode" ]] \
      || die 'Gate 4 live artifact identity changed; cleanup is refused.' 70
    /bin/unlink "$path"
  done < <(/usr/bin/awk -F $'\t' '$2 == "temporary-file" {print $4 "\t" $5 "\t" $6}' "$root/ownership-v1.tsv")
  [[ -z "$(/usr/bin/find "$runtime" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || die 'Gate 4 live root is not empty after owned-file cleanup.' 70
  /bin/rmdir "$runtime"
}

run_live_qualification() {
  swift build --product hostwright-audit-qualification
  local bin tool runtime signed state service result canonical team expected_state_schema tool_status=0
  bin="$(swift build --show-bin-path)"
  tool="$bin/hostwright-audit-qualification"
  [[ -x "$tool" ]] || die 'Gate 4 audit qualification product was not built.' 70
  runtime="$root/live-runtime-v1"
  mkdir "$runtime"
  chmod 700 "$runtime"
  record_live_root "$runtime"
  signed="$runtime/signed-audit-tool"
  state="$runtime/state.sqlite"
  service="dev.hostwright.audit.qualification.$(printf '%s' "$root" | sha256_stream | /usr/bin/cut -c1-16)"
  record_keychain_service "$service"
  /bin/cp "$tool" "$signed"
  codesign --force --sign "$signing_fingerprint" --identifier "$signing_identifier" "$signed"
  codesign --verify --strict "$signed"
  record_live_file "$runtime" "$signed"
  team="$(codesign -d --verbose=4 "$signed" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2}')"
  [[ "$team" == 993YC3JY4Q ]] || die 'Gate 4 signed live tool has the wrong team.' 70
  set +e
  result="$("$signed" --state-db "$state" --keychain-service "$service")"
  tool_status=$?
  set -e
  record_live_inventory "$runtime"
  if security find-generic-password -s "$service" >/dev/null 2>&1; then
    die 'Gate 4 live Keychain service remained after exact tool cleanup.' 70
  fi
  [[ "$tool_status" == 0 ]] || return "$tool_status"
  [[ -n "$result" && "${#result}" -le 1048576 ]] \
    || die 'Gate 4 live result is empty or exceeds the response bound.' 70
  canonical="$(printf '%s' "$result" | /usr/bin/jq -cS .)"
  [[ "$canonical" == "$result" ]] || die 'Gate 4 live result is not canonical JSON.' 70
  expected_state_schema="$(/usr/bin/jq -er '.stateSchema' contracts/v0.0.2/versions.json)"
  [[ "$expected_state_schema" =~ ^[0-9]+$ && "$expected_state_schema" -ge 19 ]] \
    || die 'Gate 4 current state schema contract is invalid.' 70
  printf '%s' "$result" | /usr/bin/jq -e --argjson expectedStateSchema "$expected_state_schema" \
    '.qualification == "phase09-gate4-live-v1" and .health == "healthy" and .stateSchema == $expectedStateSchema and .recordCount >= 3 and .segmentCount >= 3 and .exportBytes > 0 and (.exportSHA256 | test("^sha256:[a-f0-9]{64}$")) and (.activeKeyID | length > 0)' \
    >/dev/null
  printf '%s\n' "$result"
  cleanup_live_runtime "$runtime"
}

run_cell() {
  case "$1" in
    1) swift test --filter 'TamperEvidentAuditTrailTests/(testAppendVerifyAndExportHappyPath|testP256RotationContinuityAndSignedPrefixRetention)' ;;
    2) swift test --filter 'PersistentControlAuditIntegrationTests|HostwrightDaemonControlServiceTests' ;;
    3) run_live_qualification ;;
    4) swift test --filter 'AuditSchemaV19MigrationTests' ;;
    5) swift test --filter 'TamperEvidentAuditTrailTests/(testModificationDeletionReorderAndTruncationAreDetected|testActiveKeySubstitutionIsDetectedBeforeAnotherAppend|testBackwardClockIsRejectedWithoutCorruptingTheTrail)|PersistentControlAuditIntegrationTests/testAuditFailureFailsClosedForMutationWhileReadOnlyOperationRemainsCallable' ;;
    6)
      swift test --filter 'TamperEvidentAuditTrailTests/(testSigningFailureAndExternalHeadStoreCrashRecovery|testPendingRotationRecoversAcrossActivationFailure)|StateMaintenanceTests/(testRecoveryHandlesEveryDurableRestoreCheckpointWithoutInventingState|testRecoveryHandlesEveryTornRestoreMutationWindow)'
      swift build --product hostwrightd
      swift build --product hostwright-control
      scripts/lint.sh
      git diff --check
      scripts/check-docs.sh
      ;;
    *) die 'unknown Gate 4 cell.' 70 ;;
  esac
}

append_state() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$gate" "$1" "$2" "$source_digest_value" "$config_digest_value" \
    "$toolchain_digest_value" "$3" "$4" "$5" "$6" >> "$root/state-v1.tsv"
  chmod 600 "$root/state-v1.tsv"
}

append_failure() {
  [[ -f "$root/failure-v1.tsv" ]] \
    || printf '%s\n' $'recorded_at\tgate\tcell\texit_status\tcommand\tstdout_sha256\tstderr_sha256' \
      > "$root/failure-v1.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(now)" "$gate" "$1" "$2" "$3" "$4" "$5" >> "$root/failure-v1.tsv"
  chmod 600 "$root/failure-v1.tsv"
}

set_manifest_status() {
  local status="$1" completed_at="$2" temporary="$root/.manifest-v1.tmp"
  /usr/bin/jq \
    --arg status "$status" \
    --arg completedAt "$completed_at" \
    '.status=$status | .completedAt=(if $completedAt == "" then null else $completedAt end)' \
    "$root/manifest-v1.json" > "$temporary"
  chmod 600 "$temporary"
  /bin/mv "$temporary" "$root/manifest-v1.json"
}

all_reusable() {
  local cell stdout stderr stdout_sha stderr_sha recorded_stdout recorded_stderr
  for cell in 1 2 3 4 5 6; do
    /usr/bin/awk -F $'\t' \
      -v cell="$cell" -v source="$source_digest_value" \
      -v config="$config_digest_value" -v toolchain="$toolchain_digest_value" \
      '$1 == 4 && $2 == cell && $3 == "pass" && $4 == source && $5 == config && $6 == toolchain {found=1} END {exit(found ? 0 : 1)}' \
      "$root/state-v1.tsv" || return 1
    stdout="$root/cell-$(printf '%02d' "$cell").stdout.log"
    stderr="$root/cell-$(printf '%02d' "$cell").stderr.log"
    [[ -f "$stdout" && -f "$stderr" ]] || return 1
    stdout_sha="$(sha256_file "$stdout")"
    stderr_sha="$(sha256_file "$stderr")"
    recorded_stdout="$(/usr/bin/awk -F $'\t' -v cell="$cell" '$1 == 4 && $2 == cell && $3 == "pass" {value=$9} END {print value}' "$root/state-v1.tsv")"
    recorded_stderr="$(/usr/bin/awk -F $'\t' -v cell="$cell" '$1 == 4 && $2 == cell && $3 == "pass" {value=$10} END {print value}' "$root/state-v1.tsv")"
    [[ "$stdout_sha" == "$recorded_stdout" && "$stderr_sha" == "$recorded_stderr" ]] \
      || return 1
  done
}

verify_evidence_digest() {
  local decoded status=0 line_count
  [[ -f "$root/evidence-v1.sha256" && ! -L "$root/evidence-v1.sha256" \
      && -f "$root/evidence-v1.cms" && ! -L "$root/evidence-v1.cms" ]] \
    || return 1
  line_count="$(/usr/bin/wc -l < "$root/evidence-v1.sha256" | /usr/bin/tr -d ' ')"
  [[ "$line_count" == 17 ]] || return 1
  /usr/bin/awk '
    NF != 2 { exit 1 }
    $1 !~ /^[a-f0-9]{64}$/ { exit 1 }
    $2 !~ /^(manifest-v1\.json|state-v1\.tsv|ownership-v1\.tsv|toolchain-v1\.txt|gate-active-run-v1-info\.tsv|cell-[0-9][0-9]\.(stdout|stderr)\.log)$/ { exit 1 }
    seen[$2]++ > 0 { exit 1 }
    END { exit(NR == 17 ? 0 : 1) }
  ' "$root/evidence-v1.sha256" || return 1
  decoded="$(/usr/bin/mktemp /tmp/hostwright-phase09-gate04-evidence.XXXXXX)" || return 1
  if ! security cms -D -u 9 -i "$root/evidence-v1.cms" -o "$decoded" >/dev/null 2>&1; then
    status=1
  elif ! /usr/bin/cmp -s "$root/evidence-v1.sha256" "$decoded"; then
    status=1
  elif ! (cd "$root" && /usr/bin/shasum -a 256 -c evidence-v1.sha256 >/dev/null); then
    status=1
  fi
  /bin/unlink "$decoded"
  [[ "$status" == 0 ]]
}

release_locks_on_success() {
  if [[ "$run_succeeded" == 1 && "$root_lock_created" == 1 \
      && "$gate_lock_created" == 1 ]]; then
    /bin/rmdir "$root/active-run-v1"
    /bin/rmdir "$parent/.phase09-gate04-active-v1"
    root_lock_created=0
    gate_lock_created=0
  fi
}

write_evidence_digest() {
  (
    cd "$root"
    for file in manifest-v1.json state-v1.tsv ownership-v1.tsv toolchain-v1.txt \
      gate-active-run-v1-info.tsv cell-*.stdout.log cell-*.stderr.log; do
      [[ -f "$file" ]] && /usr/bin/shasum -a 256 "$file"
    done | LC_ALL=C /usr/bin/sort
  ) > "$root/evidence-v1.sha256"
  chmod 600 "$root/evidence-v1.sha256"
  security cms -S -N "$signing_identity" -H SHA256 -u 9 \
    -i "$root/evidence-v1.sha256" -o "$root/evidence-v1.cms"
  chmod 600 "$root/evidence-v1.cms"
}

run() {
  validate_prepared
  if [[ -e "$root/evidence-v1.sha256" || -e "$root/evidence-v1.cms" ]]; then
    if [[ "$(/usr/bin/jq -r '.status' "$root/manifest-v1.json")" != passed ]] \
        || ! all_reusable || ! verify_evidence_digest; then
      die 'completed evidence is incomplete or changed; preserve this root and do not rerun.' 73
    fi
    printf '%s\n' 'Gate 4 evidence is valid and reused; no cells were rerun.'
    return
  fi
  local gate_lock="$parent/.phase09-gate04-active-v1"
  local cell command started finished status stdout stderr stdout_sha stderr_sha
  [[ ! -e "$root/active-run-v1" && ! -e "$gate_lock" ]] \
    || die 'An active Gate 4 qualification already exists; do not duplicate it.' 75
  mkdir "$gate_lock"
  chmod 700 "$gate_lock"
  printf '%s\n' $'root\tpid\tstarted_at\tsource_digest\tconfig_digest\ttoolchain_digest' \
    > "$gate_lock/info-v1.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$root" "$$" "$(now)" \
    "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" \
    >> "$gate_lock/info-v1.tsv"
  chmod 600 "$gate_lock/info-v1.tsv"
  gate_lock_created=1
  mkdir "$root/active-run-v1"
  chmod 700 "$root/active-run-v1"
  root_lock_created=1
  trap release_locks_on_success EXIT
  for cell in 1 2 3 4 5 6; do
    command="$(cell_command "$cell")"
    stdout="$root/cell-$(printf '%02d' "$cell").stdout.log"
    stderr="$root/cell-$(printf '%02d' "$cell").stderr.log"
    [[ ! -e "$stdout" && ! -e "$stderr" ]] \
      || die 'Cell logs already exist; preserve this root and do not rerun.' 73
    started="$(now)"
    set +e
    (set -e; run_cell "$cell") > "$stdout" 2> "$stderr"
    status=$?
    set -e
    chmod 600 "$stdout" "$stderr"
    stdout_sha="$(sha256_file "$stdout")"
    stderr_sha="$(sha256_file "$stderr")"
    finished="$(now)"
    if [[ "$status" != 0 ]]; then
      append_state "$cell" failed "$started" "$finished" "$stdout_sha" "$stderr_sha"
      append_failure "$cell" "$status" "$command" "$stdout_sha" "$stderr_sha"
      set_manifest_status failed "$finished"
      die "Gate 4 cell $cell failed; progress is frozen and locks are preserved." "$status"
    fi
    append_state "$cell" pass "$started" "$finished" "$stdout_sha" "$stderr_sha"
  done
  set_manifest_status passed "$(now)"
  /bin/cp "$gate_lock/info-v1.tsv" "$root/gate-active-run-v1-info.tsv"
  chmod 600 "$root/gate-active-run-v1-info.tsv"
  write_evidence_digest
  /bin/unlink "$gate_lock/info-v1.tsv"
  run_succeeded=1
  release_locks_on_success
  printf '%s\n' 'Gate 4 qualification passed.'
}

main() {
  [[ "$#" -ge 1 ]] \
    || die 'usage: phase09-gate04-qualification.sh <contract|prepare|run>.' 64
  case "$1" in
    contract)
      [[ "$#" == 1 ]] || die 'contract accepts no arguments.' 64
      contract
      ;;
    prepare)
      [[ "$#" == 2 && "$2" == 4 ]] || die 'Gate 4 harness accepts only prepare 4.' 64
      validate_worktree
      validate_root
      require_empty_root
      collect_digests
      prepare
      printf '%s\n' 'Gate 4 evidence root prepared.'
      ;;
    run)
      [[ "$#" == 2 && "$2" == 4 ]] || die 'Gate 4 harness accepts only run 4.' 64
      validate_worktree
      validate_root
      collect_digests
      run
      ;;
    *) die 'unknown Gate 4 qualification command.' 64 ;;
  esac
}

main "$@"
