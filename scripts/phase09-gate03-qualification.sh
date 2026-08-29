#!/usr/bin/env bash
set -euo pipefail

readonly schema='hostwright.phase09.gate03.qualification.manifest.v1'
readonly gate=3
readonly branch='feat/v0.0.2-phase-09'
readonly live_parent='/Volumes/T9/hostwright/qualification'
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
Phase 09 Gate 3 qualification harness contract v1
Gate 3 — 18.75% — persistent authenticated Control API (#195; #198 integration).
Exactly one Gate 3 qualification may be active. Cells 1..6 run strictly serially.
The six cells provide focused unit, integration, live-runtime, migration/compatibility,
security, and resilience evidence. Passing cells are reused only when the exact
source, configuration, toolchain, logs, and recorded checksums remain unchanged.
Failure preserves the immutable evidence root, failure ledger, logs, and active locks.
Tests may remove only their own validated .build-scoped temporary roots and sockets.
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
  local top
  top="$(/bin/realpath "$(git rev-parse --show-toplevel)")"
  if test_mode; then
    [[ "$top" != '/Users/dev/Documents/hostwright' ]] \
      || die "Gate 3 requires branch $branch." 66
    return
  fi
  [[ "$(git branch --show-current)" == "$branch" ]] \
    || die "Gate 3 requires branch $branch." 66
  [[ "$top" == '/Users/dev/Documents/hostwright-phase09' ]] \
    || die 'Gate 3 requires the isolated Phase 09 worktree.' 66
  [[ "$top" != '/Users/dev/Documents/hostwright' ]] \
    || die 'Gate 3 refuses the protected Phase 08 worktree.' 66
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
      || die 'Gate 3 evidence must use the fixed qualification parent.' 66
  fi
  [[ "$root" == /* && -d "$root" && ! -L "$root" \
      && "$(/bin/realpath "$root")" == "$root" ]] \
    || die 'evidence root must be an existing canonical directory.' 66
  [[ "$(/bin/realpath "$(dirname "$root")")" == "$canonical_parent" ]] \
    || die 'evidence root must be directly below the qualification parent.' 66
  [[ "${root##*/}" =~ ^phase09-gate03-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] \
    || die 'evidence root name is not a Gate 3 lowercase UUID.' 66
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
  } 2>&1
}

cell_command() {
  case "$1" in
    1) printf '%s\n' "swift test --filter 'ControlFrameCodecTests|ControlRequestRepositoryTests'" ;;
    2) printf '%s\n' "swift test --filter 'HostwrightDaemonControlServiceTests|ControlIdentityBootstrapTests'" ;;
    3) printf '%s\n' 'swift test --filter PersistentControlClientTests/testLiveConcurrentClientsAndDurableReplayAcrossListenerRestart' ;;
    4) printf '%s\n' "swift test --filter 'StateUpgradeTests/(testV17MigrationCreatesVerifiedRollbackPackageAndReachesLatestSchema|testAbsentDatabaseInitializesLatestWithoutRollbackSnapshot)|ControlRequestTests'" ;;
    5) printf '%s\n' "swift test --filter 'PersistentControlServerTests|PersistentControlClientTests/test(ChallengeSocketBindingMismatchIsRejected|CurrentCodeAdHocIdentityCompletesRealHandshakeAndUnaryResponse|ListenerPublishesOnlyPrivateNonSymlinkSocket|ResponseRequestIDMismatchIsRejected|UnpinnedAdHocServerIsRejectedBeforeChallenge)|ControlIdentitySecurityAdapterTests'" ;;
    6) printf '%s\n' "swift build --product hostwrightd; swift build --product hostwright-control; swift test --filter 'DaemonLoopRunnerTests|DaemonMainTests'; scripts/lint.sh; git diff --check; scripts/check-docs.sh" ;;
    *) die 'unknown Gate 3 cell.' 70 ;;
  esac
}

cell_classes() {
  case "$1" in
    1) printf '%s\n' '["U"]' ;;
    2) printf '%s\n' '["I","R"]' ;;
    3) printf '%s\n' '["L","I","R"]' ;;
    4) printf '%s\n' '["M"]' ;;
    5) printf '%s\n' '["S","R"]' ;;
    6) printf '%s\n' '["I","R"]' ;;
    *) die 'unknown Gate 3 evidence class.' 70 ;;
  esac
}

config_digest() {
  {
    sha256_file "$0"
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
      || die 'Gate 3 qualification requires an exact clean committed branch.' 73
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
      && "$(/usr/bin/jq -r '.gate' "$root/manifest-v1.json")" == 3 \
      && "$(/usr/bin/jq -r '.sourceDigest' "$root/manifest-v1.json")" == "$source_digest_value" \
      && "$(/usr/bin/jq -r '.configDigest' "$root/manifest-v1.json")" == "$config_digest_value" \
      && "$(/usr/bin/jq -r '.toolchainDigest' "$root/manifest-v1.json")" == "$toolchain_digest_value" ]] \
    || die 'prepared evidence dependencies changed; preserve this root.' 73
}

run_cell() {
  case "$1" in
    1) swift test --filter 'ControlFrameCodecTests|ControlRequestRepositoryTests' ;;
    2) swift test --filter 'HostwrightDaemonControlServiceTests|ControlIdentityBootstrapTests' ;;
    3) swift test --filter PersistentControlClientTests/testLiveConcurrentClientsAndDurableReplayAcrossListenerRestart ;;
    4) swift test --filter 'StateUpgradeTests/(testV17MigrationCreatesVerifiedRollbackPackageAndReachesLatestSchema|testAbsentDatabaseInitializesLatestWithoutRollbackSnapshot)|ControlRequestTests' ;;
    5) swift test --filter 'PersistentControlServerTests|PersistentControlClientTests/test(ChallengeSocketBindingMismatchIsRejected|CurrentCodeAdHocIdentityCompletesRealHandshakeAndUnaryResponse|ListenerPublishesOnlyPrivateNonSymlinkSocket|ResponseRequestIDMismatchIsRejected|UnpinnedAdHocServerIsRejectedBeforeChallenge)|ControlIdentitySecurityAdapterTests' ;;
    6)
      swift build --product hostwrightd
      swift build --product hostwright-control
      swift test --filter 'DaemonLoopRunnerTests|DaemonMainTests'
      scripts/lint.sh
      git diff --check
      scripts/check-docs.sh
      ;;
    *) die 'unknown Gate 3 cell.' 70 ;;
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
      '$1 == 3 && $2 == cell && $3 == "pass" && $4 == source && $5 == config && $6 == toolchain {found=1} END {exit(found ? 0 : 1)}' \
      "$root/state-v1.tsv" || return 1
    stdout="$root/cell-$(printf '%02d' "$cell").stdout.log"
    stderr="$root/cell-$(printf '%02d' "$cell").stderr.log"
    [[ -f "$stdout" && -f "$stderr" ]] || return 1
    stdout_sha="$(sha256_file "$stdout")"
    stderr_sha="$(sha256_file "$stderr")"
    recorded_stdout="$(/usr/bin/awk -F $'\t' -v cell="$cell" '$1 == 3 && $2 == cell && $3 == "pass" {value=$9} END {print value}' "$root/state-v1.tsv")"
    recorded_stderr="$(/usr/bin/awk -F $'\t' -v cell="$cell" '$1 == 3 && $2 == cell && $3 == "pass" {value=$10} END {print value}' "$root/state-v1.tsv")"
    [[ "$stdout_sha" == "$recorded_stdout" && "$stderr_sha" == "$recorded_stderr" ]] \
      || return 1
  done
}

release_locks_on_success() {
  if [[ "$run_succeeded" == 1 && "$root_lock_created" == 1 \
      && "$gate_lock_created" == 1 ]]; then
    /bin/rmdir "$root/active-run-v1"
    /bin/rmdir "$parent/.phase09-gate03-active-v1"
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
}

run() {
  validate_prepared
  if all_reusable; then
    [[ "$(/usr/bin/jq -r '.status' "$root/manifest-v1.json")" == passed \
        && -f "$root/evidence-v1.sha256" ]] \
      || die 'reusable evidence records are incomplete.' 73
    printf '%s\n' 'Gate 3 evidence is valid and reused; no cells were rerun.'
    return
  fi
  local gate_lock="$parent/.phase09-gate03-active-v1"
  local cell command started finished status stdout stderr stdout_sha stderr_sha
  [[ ! -e "$root/active-run-v1" && ! -e "$gate_lock" ]] \
    || die 'An active Gate 3 qualification already exists; do not duplicate it.' 75
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
      die "Gate 3 cell $cell failed; progress is frozen and locks are preserved." "$status"
    fi
    append_state "$cell" pass "$started" "$finished" "$stdout_sha" "$stderr_sha"
  done
  set_manifest_status passed "$(now)"
  /bin/mv "$gate_lock/info-v1.tsv" "$root/gate-active-run-v1-info.tsv"
  chmod 600 "$root/gate-active-run-v1-info.tsv"
  write_evidence_digest
  run_succeeded=1
  release_locks_on_success
  printf '%s\n' 'Gate 3 qualification passed.'
}

main() {
  [[ "$#" -ge 1 ]] \
    || die 'usage: phase09-gate03-qualification.sh <contract|prepare|run>.' 64
  case "$1" in
    contract)
      [[ "$#" == 1 ]] || die 'contract accepts no arguments.' 64
      contract
      ;;
    prepare)
      [[ "$#" == 2 && "$2" == 3 ]] || die 'Gate 3 harness accepts only prepare 3.' 64
      validate_worktree
      validate_root
      require_empty_root
      collect_digests
      prepare
      printf '%s\n' 'Gate 3 evidence root prepared.'
      ;;
    run)
      [[ "$#" == 2 && "$2" == 3 ]] || die 'Gate 3 harness accepts only run 3.' 64
      validate_worktree
      validate_root
      collect_digests
      run
      ;;
    *) die 'unknown Gate 3 qualification command.' 64 ;;
  esac
}

main "$@"
