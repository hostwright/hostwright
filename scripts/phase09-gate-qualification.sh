#!/usr/bin/env bash
set -euo pipefail

readonly harness_schema='hostwright.phase09.qualification.manifest.v1'
readonly harness_version='Phase 09 qualification harness contract v1'
readonly live_qualification_parent='/Volumes/T9/hostwright/qualification'
readonly router_repository_path='/Users/dev/Documents/hostwright-phase09'
readonly router_protected_repository_path='/Users/dev/Documents/hostwright'
readonly ownership_header=$'recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity'
readonly state_header=$'gate\tcell\tstatus\tsource_digest\tconfig_digest\ttoolchain_digest\tstarted_at\tfinished_at\tstdout_sha256\tstderr_sha256'

root=''
gate=''
source_commit=''
source_digest_value=''
config_digest_value=''
toolchain_digest_value=''
dirty_state=''
qualification_parent_root=''
root_lock_created=0
gate_lock_created=0
qualification_started_at=''
run_succeeded=0
router_script_invocation="${BASH_SOURCE[0]}"
router_script_path=''
router_repo_root=''

die() {
  printf '%s\n' "$1" >&2
  exit "${2:-70}"
}

testing() { [[ "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" == '1' ]]; }

timestamp() {
  /bin/date -u +%Y-%m-%dT%H:%M:%SZ
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

sha256_stream() {
  /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
}

contract() {
  cat <<'EOF'
Phase 09 qualification harness contract v1
One active qualification is permitted per gate across every immutable evidence root; cells are serial and failure freezes the gate.
Evidence is reused only when gate, cell, source, configuration, and toolchain digests all match.
No public action, runtime launch, resource cleanup, or protected-soak access is performed.
Evidence classes are U/I/L/M/S/R: unit, integration, live runtime, migration, security, resilience.
Gate 1 — 6.25% — U/I/L/M/S/R — contract and harness freeze
Gate 2 — 12.50% — U/I/L/M/S/R — local identity and authentication
Gate 3 — 18.75% — U/I/L/M/S/R — persistent Control API
Gate 4 — 25.00% — U/I/L/M/S/R — tamper-evident audit
Gate 5 — 31.25% — U/I/L/M/S/R — RBAC
Gate 6 — 37.50% — U/I/L/M/S/R — admission policy
Gate 7 — 43.75% — U/I/L/M/S/R — workload profiles
Gate 8 — 50.00% — U/I/L/M/S/R — streams and recovery
Gate 9 — 56.25% — U/I/L/M/S/R — CLI/API parity
Gate 10 — 62.50% — U/I/L/M/S/R — WASI provider SDK
Gate 11 — 68.75% — U/I/L/M/S/R — signed XPC boundary
Gate 12 — 75.00% — U/I/L/M/S/R — plugin lifecycle
Gate 13 — 81.25% — U/I/L/M/S/R — ancestry and compatibility
Gate 14 — 87.50% — U/I/L/M/S/R — security and resilience
Gate 15 — 93.75% — U/I/L/M/S/R — final macOS live qualification
Gate 16 — 100.00% — U/I/L/M/S/R — aggregate merge and closure
EOF
}

validate_router_boundary() {
  local invocation canonical directory expected_repository
  if [[ "$router_script_invocation" == /* ]]; then
    invocation="$router_script_invocation"
  else
    invocation="$PWD/$router_script_invocation"
  fi
  [[ -f "$invocation" && ! -L "$invocation" ]] \
    || die 'Phase 09 qualification router invocation must not cross a symlink boundary.' 66
  canonical="$(/bin/realpath "$invocation")" \
    || die 'Phase 09 qualification router cannot resolve its own path.' 66
  directory="$(dirname "$canonical")"
  [[ ! -L "$directory" && "$(/bin/realpath "$directory")" == "$directory" ]] \
    || die 'Phase 09 qualification router directory must be canonical and non-symlinked.' 66
  if testing; then
    expected_repository="$(/bin/realpath "$directory/..")" \
      || die 'Phase 09 qualification router test repository cannot be resolved.' 66
  else
    expected_repository="$router_repository_path"
  fi
  [[ "$canonical" == "$expected_repository/scripts/phase09-gate-qualification.sh" ]] \
    || die 'Phase 09 qualification router is outside the canonical Phase 09 repository.' 66
  router_script_path="$canonical"
  router_repo_root="$(/bin/realpath "$directory/..")" \
    || die 'Phase 09 qualification router repository cannot be resolved.' 66
  [[ "$router_repo_root" == "$expected_repository" \
    && "$router_repo_root" != "$router_protected_repository_path" ]] \
    || die 'Phase 09 qualification router refuses a protected or unexpected repository path.' 66
}

validate_worktree() {
  local branch top
  validate_router_boundary
  branch="$(git -C "$router_repo_root" branch --show-current)"
  top="$(/bin/realpath "$(git -C "$router_repo_root" rev-parse --show-toplevel)")"
  if testing; then
    [[ "$top" == "$router_repo_root" && "$top" != "$router_protected_repository_path" ]] \
      || die 'Phase 09 qualification test requires its invoking repository.' 66
    cd "$router_repo_root"
    return
  fi
  [[ "$branch" == 'feat/v0.0.2-phase-09' ]] \
    || die 'Phase 09 qualification requires branch feat/v0.0.2-phase-09.' 66
  [[ "$top" == "$router_repo_root" && "$top" != "$router_protected_repository_path" ]] \
    || die 'Phase 09 qualification requires the canonical isolated Phase 09 worktree.' 66
  cd "$router_repo_root"
}

validate_gate() {
  gate="$1"
  [[ "$gate" =~ ^([1-9]|1[0-6])$ ]] \
    || die 'gate must be an integer from 1 through 16.' 66
}

qualification_parent() {
  if [[ "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" == '1' ]]; then
    : "${HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT:?test parent is required in harness test mode}"
    printf '%s\n' "$HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT"
    return
  fi
  [[ -z "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" ]] \
    || die 'HOSTWRIGHT_PHASE09_HARNESS_TESTING must be exactly 1 when set.' 66
  printf '%s\n' "$live_qualification_parent"
}

require_configured_gate() {
  [[ "$gate" == 1 ]] || die "Gate $gate has no configured qualification cells; fail closed." 69
}

is_dedicated_gate() {
  [[ "$1" =~ ^(1[3-6])$ ]]
}

dedicated_gate_script() {
  case "$1" in
    13) printf '%s\n' "$router_repo_root/scripts/phase09-gate13-qualification.sh" ;;
    14) printf '%s\n' "$router_repo_root/scripts/phase09-gate14-qualification.sh" ;;
    15) printf '%s\n' "$router_repo_root/scripts/phase09-gate15-qualification.sh" ;;
    16) printf '%s\n' "$router_repo_root/scripts/phase09-gate16-qualification.sh" ;;
    *) die "Gate $1 has no dedicated qualification dispatcher." 69 ;;
  esac
}

dispatch_dedicated_gate() {
  local command="$1" selected_gate="$2" script
  script="$(dedicated_gate_script "$selected_gate")"
  [[ -f "$script" && ! -L "$script" && "$(/bin/realpath "$script")" == "$script" ]] \
    || die "Gate $selected_gate dedicated qualification harness is unavailable; fail closed." 69
  cd "$router_repo_root"
  case "$command" in
    contract|diagnose)
      exec /bin/bash "$script" "$command"
      ;;
    prepare|run|status)
      exec /bin/bash "$script" "$command" "$selected_gate"
      ;;
    finalize)
      exec /bin/bash "$script" "$command" "$selected_gate" "${3:-}"
      ;;
    *)
      die "Dedicated Gate $selected_gate does not support command $command." 64
      ;;
  esac
}

validate_evidence_root() {
  : "${HOSTWRIGHT_PHASE09_GATE_ROOT:?HOSTWRIGHT_PHASE09_GATE_ROOT is required}"
  local parent expected_name user_id root_parent canonical_parent
  parent="$(qualification_parent)"
  root="$HOSTWRIGHT_PHASE09_GATE_ROOT"
  [[ "$root" == /* && "$root" != *$'\n'* && -d "$root" && ! -L "$root" ]] \
    || die 'HOSTWRIGHT_PHASE09_GATE_ROOT must name an existing absolute non-symlink directory.' 66
  root_parent="$(dirname "$root")"
  canonical_parent="$(/bin/realpath "$parent")"
  if [[ "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" == '1' ]]; then
    [[ "$canonical_parent" =~ ^/private/var/folders/[^/]+/[^/]+/T/hostwright-phase09-harness-[a-f0-9-]+$ ]] \
      || die 'test-only qualification parent must be an isolated mktemp root.' 66
  fi
  [[ -d "$parent" && ! -L "$parent" && "$canonical_parent" == "$parent" \
      && "$(/bin/realpath "$root_parent")" == "$canonical_parent" ]] \
    || die 'The evidence root must be directly under the canonical qualification parent.' 66
  qualification_parent_root="$canonical_parent"
  expected_name="$(printf 'phase09-gate%02d' "$gate")"
  [[ "${root##*/}" =~ ^${expected_name}-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] \
    || die 'The evidence root name must match the selected gate and a lowercase UUID.' 66
  user_id="$(id -u)"
  [[ "$(/bin/realpath "$root")" == "$root" \
      && "$(stat -f '%u' "$root")" == "$user_id" \
      && "$(stat -f '%Lp' "$root")" == 700 ]] \
    || die 'The evidence root must be canonical, current-user-owned, and mode 0700.' 66
}

require_empty_root() {
  [[ -z "$(/usr/bin/find "$root" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || die 'prepare requires a pre-created empty evidence root.' 73
}

source_digest() {
  {
    git rev-parse HEAD
    git diff --binary HEAD -- . ':(exclude)tmp'
    while IFS= read -r -d '' path; do
      [[ "$path" == tmp || "$path" == tmp/* || "$path" == .codex || "$path" == .codex/* \
        || "$path" == .claude || "$path" == .claude/* ]] && continue
      printf '%s\0' "$path"
      /usr/bin/shasum -a 256 "$path"
    done < <(git ls-files --others --exclude-standard -z | LC_ALL=C /usr/bin/sort -z)
  } | sha256_stream
}

config_digest() {
  {
    sha256_file "$0"
    sha256_file scripts/lint.sh
    sha256_file scripts/check-docs.sh
    printf '%s\n' 'swift test --filter HostwrightControlPlaneTests'
    printf '%s\n' 'swift build --target HostwrightControlPlane'
    printf '%s\n' 'scripts/lint.sh'
    printf '%s\n' 'git diff --check'
    printf '%s\n' 'scripts/check-docs.sh'
    printf '%s\n' 'run_prerequisite_probe'
  } | sha256_stream
}

toolchain_digest() {
  toolchain_report | sha256_stream
}

toolchain_report() {
  if [[ "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" == '1' ]]; then
    printf '%s\n' 'ProductName: Phase 09 qualification harness test mode'
    printf '%s\n' 'ProductVersion: deterministic-no-runtime-probes'
    return
  fi
  {
    /usr/bin/sw_vers
    xcodebuild -version
    swift --version
    /bin/bash --version | /usr/bin/head -n 1
    /usr/bin/jq --version
    probe_command 'Swift SDK inventory' swift sdk list
    probe_command 'Apple container version' container --version
    probe_command 'notarytool' xcrun notarytool --version
    probe_command 'stapler' xcrun stapler --version
    probe_command 'swift-format' xcrun swift-format --version
    printf '%s\n' 'CMS signer identity is validated from the verified CMS certificate; no identity-list query is evidence.'
    if [[ -n "${HOSTWRIGHT_NOTARY_PROFILE:-}" ]]; then
      printf '%s\n' 'HOSTWRIGHT_NOTARY_PROFILE=available'
    else
      printf '%s\n' 'HOSTWRIGHT_NOTARY_PROFILE=unavailable'
    fi
  } 2>&1
}

collect_digests() {
  source_commit="$(git rev-parse HEAD)"
  source_digest_value="$(source_digest)"
  config_digest_value="$(config_digest)"
  toolchain_digest_value="$(toolchain_digest)"
  if [[ -n "$(git status --porcelain --untracked-files=all -- . ':(exclude)tmp')" ]]; then
    dirty_state='dirty'
  else
    dirty_state='clean'
  fi
}

command_for_cell() {
  case "$1" in
    1) printf '%s\n' 'swift test --filter HostwrightControlPlaneTests' ;;
    2) printf '%s\n' 'swift build --target HostwrightControlPlane' ;;
    3) printf '%s\n' 'scripts/lint.sh' ;;
    4) printf '%s\n' 'git diff --check' ;;
    5) printf '%s\n' 'scripts/check-docs.sh' ;;
    6) printf '%s\n' 'run_prerequisite_probe' ;;
    *) die 'unknown Gate 1 qualification cell.' 70 ;;
  esac
}

evidence_classes_for_cell() {
  case "$1" in
    1) printf '%s\n' '["U","I","M","S","R"]' ;;
    2|3|4) printf '%s\n' '["I"]' ;;
    5) printf '%s\n' '["S"]' ;;
    6) printf '%s\n' '["L"]' ;;
    *) die 'unknown Gate 1 evidence cell.' 70 ;;
  esac
}

evidence_by_cell_json() {
  local cell
  for cell in 1 2 3 4 5 6; do
    /usr/bin/jq -n --argjson cell "$cell" --arg command "$(command_for_cell "$cell")" \
      --argjson evidenceClasses "$(evidence_classes_for_cell "$cell")" \
      '{cell: $cell, command: $command, evidenceClasses: $evidenceClasses}'
  done | /usr/bin/jq -s .
}

write_manifest() {
  local status="$1" completed_at="${2:-}"
  /usr/bin/jq -n \
    --arg schema "$harness_schema" \
    --argjson gate "$gate" \
    --arg sourceCommit "$source_commit" \
    --arg sourceDigest "$source_digest_value" \
    --arg configDigest "$config_digest_value" \
    --arg toolchainDigest "$toolchain_digest_value" \
    --arg dirtyState "$dirty_state" \
    --arg startedAt "$(timestamp)" \
    --arg completedAt "$completed_at" \
    --arg status "$status" \
    --rawfile toolchainReport "$root/toolchain-v1.txt" \
    --argjson commands "$(
      for cell in 1 2 3 4 5 6; do command_for_cell "$cell"; done | /usr/bin/jq -R . | /usr/bin/jq -s .
    )" \
    --argjson evidenceByCell "$(evidence_by_cell_json)" \
    '{schema: $schema, gate: $gate, sourceCommit: $sourceCommit, sourceDigest: $sourceDigest,
      configDigest: $configDigest, toolchainDigest: $toolchainDigest, dirtyState: $dirtyState,
      commands: $commands, cellOrder: [1, 2, 3, 4, 5, 6], evidenceByCell: $evidenceByCell,
      toolchainReport: $toolchainReport,
      startedAt: $startedAt, completedAt: (if $completedAt == "" then null else $completedAt end), status: $status}' \
    > "$root/manifest-v1.json"
  chmod 600 "$root/manifest-v1.json"
}

write_initial_evidence() {
  printf '%s\n' "$ownership_header" > "$root/ownership-v1.tsv"
  printf '%s\n' "$state_header" > "$root/state-v1.tsv"
  toolchain_report > "$root/toolchain-v1.txt"
  chmod 600 "$root/ownership-v1.tsv" "$root/state-v1.tsv" "$root/toolchain-v1.txt"
  write_manifest prepared
}

validate_evidence_structure() {
  [[ -f "$root/manifest-v1.json" && -f "$root/ownership-v1.tsv" && -f "$root/state-v1.tsv" \
      && -f "$root/toolchain-v1.txt" ]] \
    || die 'run requires a prepared evidence root.' 73
  [[ "$(head -n 1 "$root/ownership-v1.tsv")" == "$ownership_header" \
      && "$(head -n 1 "$root/state-v1.tsv")" == "$state_header" ]] \
    || die 'The prepared evidence headers are invalid.' 73
  [[ "$(/usr/bin/jq -r '.schema' "$root/manifest-v1.json")" == "$harness_schema" \
      && "$(/usr/bin/jq -r '.gate' "$root/manifest-v1.json")" == "$gate" ]] \
    || die 'The prepared manifest is for another harness or gate.' 73
}

validate_prepared_evidence() {
  validate_evidence_structure
  [[ "$(/usr/bin/jq -r '.sourceDigest' "$root/manifest-v1.json")" == "$source_digest_value" \
      && "$(/usr/bin/jq -r '.configDigest' "$root/manifest-v1.json")" == "$config_digest_value" \
      && "$(/usr/bin/jq -r '.toolchainDigest' "$root/manifest-v1.json")" == "$toolchain_digest_value" ]] \
    || die 'The prepared evidence dependencies changed; preserve this root and prepare a new one.' 73
}

all_cells_are_reusable() {
  local cell command stdout_sha stderr_sha state_stdout_sha state_stderr_sha
  for cell in 1 2 3 4 5 6; do
    command="$(command_for_cell "$cell")"
    /usr/bin/awk -F $'\t' -v gate="$gate" -v cell="$cell" \
      -v source="$source_digest_value" -v config="$config_digest_value" -v toolchain="$toolchain_digest_value" \
      '$1 == gate && $2 == cell && $3 == "pass" && $4 == source && $5 == config && $6 == toolchain { found = 1 }
       END { exit(found ? 0 : 1) }' "$root/state-v1.tsv" || return 1
    [[ -f "$root/$(printf 'cell-%02d.stdout.log' "$cell")" \
        && -f "$root/$(printf 'cell-%02d.stderr.log' "$cell")" ]] || return 1
    stdout_sha="$(sha256_file "$root/$(printf 'cell-%02d.stdout.log' "$cell")")"
    stderr_sha="$(sha256_file "$root/$(printf 'cell-%02d.stderr.log' "$cell")")"
    state_stdout_sha="$(/usr/bin/awk -F $'\t' -v gate="$gate" -v cell="$cell" \
      -v source="$source_digest_value" -v config="$config_digest_value" -v toolchain="$toolchain_digest_value" \
      '$1 == gate && $2 == cell && $3 == "pass" && $4 == source && $5 == config && $6 == toolchain { value = $9 }
       END { print value }' "$root/state-v1.tsv")"
    state_stderr_sha="$(/usr/bin/awk -F $'\t' -v gate="$gate" -v cell="$cell" \
      -v source="$source_digest_value" -v config="$config_digest_value" -v toolchain="$toolchain_digest_value" \
      '$1 == gate && $2 == cell && $3 == "pass" && $4 == source && $5 == config && $6 == toolchain { value = $10 }
       END { print value }' "$root/state-v1.tsv")"
    [[ "$stdout_sha" == "$state_stdout_sha" && "$stderr_sha" == "$state_stderr_sha" ]] || return 1
    [[ -n "$command" ]] || return 1
  done
}

append_state() {
  local cell="$1" status="$2" started_at="$3" finished_at="$4" stdout_sha="$5" stderr_sha="$6"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$gate" "$cell" "$status" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" \
    "$started_at" "$finished_at" "$stdout_sha" "$stderr_sha" >> "$root/state-v1.tsv"
  chmod 600 "$root/state-v1.tsv"
}

append_failure() {
  local cell="$1" status="$2" command="$3" stdout_sha="$4" stderr_sha="$5"
  local failure="$root/failure-v1.tsv"
  if [[ ! -f "$failure" ]]; then
    printf '%s\n' $'recorded_at\tgate\tcell\texit_status\tcommand\tsource_digest\tconfig_digest\ttoolchain_digest\tstdout_sha256\tstderr_sha256' > "$failure"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(timestamp)" "$gate" "$cell" "$status" "$command" "$source_digest_value" \
    "$config_digest_value" "$toolchain_digest_value" "$stdout_sha" "$stderr_sha" >> "$failure"
  chmod 600 "$failure"
}

run_gate1_cell() {
  local cell="$1"
  case "$cell" in
    1) swift test --filter HostwrightControlPlaneTests ;;
    2) swift build --target HostwrightControlPlane ;;
    3) scripts/lint.sh ;;
    4) git diff --check ;;
    5) scripts/check-docs.sh ;;
    6) run_prerequisite_probe ;;
    *) die 'unknown Gate 1 qualification cell.' 70 ;;
  esac
}

probe_command() {
  local label="$1"
  shift
  printf '\n[%s]\n' "$label"
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'unavailable: %s\n' "$1"
    return
  fi
  set +e
  "$@"
  local status=$?
  set -e
  printf 'exit_status=%s\n' "$status"
}

run_prerequisite_probe() {
  if [[ "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" == '1' ]]; then
    toolchain_report
    return
  fi
  printf '%s\n' 'Phase 09 Gate 1 prerequisite probe: read-only; unavailable tooling is recorded, not inferred.'
  probe_command 'macOS' /usr/bin/sw_vers
  probe_command 'architecture' /usr/bin/uname -m
  probe_command 'Xcode' xcodebuild -version
  probe_command 'Swift' swift --version
  probe_command 'Swift SDK inventory' swift sdk list
  probe_command 'Apple container version' container --version
  probe_command 'Apple container system status' container system status
  probe_command 'notarytool' xcrun notarytool --version
  probe_command 'stapler' xcrun stapler --version
  probe_command 'swift-format' xcrun swift-format --version
  if [[ -n "${HOSTWRIGHT_NOTARY_PROFILE:-}" ]]; then
    printf '%s\n' 'HOSTWRIGHT_NOTARY_PROFILE=available'
  else
    printf '%s\n' 'HOSTWRIGHT_NOTARY_PROFILE=unavailable'
  fi
}

release_lock_on_success() {
  if [[ "$run_succeeded" == 1 && "$root_lock_created" == 1 && "$gate_lock_created" == 1 ]]; then
    rmdir "$root/active-run-v1" || die 'The successful active qualification lock cannot be removed.' 70
    rmdir "$qualification_parent_root/$(printf '.phase09-gate%02d-active-v1' "$gate")" \
      || die 'The successful gate-wide qualification lock cannot be removed.' 70
    root_lock_created=0
    gate_lock_created=0
  fi
}

preserve_gate_lock_info() {
  mv "$qualification_parent_root/$(printf '.phase09-gate%02d-active-v1' "$gate")/info-v1.tsv" \
    "$root/gate-active-run-v1-info.tsv" \
    || die 'The successful gate lock information cannot be preserved.' 70
  chmod 600 "$root/gate-active-run-v1-info.tsv"
}

write_evidence_digest() {
  (
    cd "$root"
    for file in manifest-v1.json state-v1.tsv ownership-v1.tsv toolchain-v1.txt gate-active-run-v1-info.tsv cell-*.stdout.log cell-*.stderr.log; do
      [[ -f "$file" ]] && /usr/bin/shasum -a 256 "$file"
    done | LC_ALL=C /usr/bin/sort
  ) > "$root/evidence-v1.sha256"
  chmod 600 "$root/evidence-v1.sha256"
}

run_gate() {
  require_configured_gate
  validate_prepared_evidence
  if all_cells_are_reusable; then
    [[ "$(/usr/bin/jq -r '.status' "$root/manifest-v1.json")" == passed \
        && -f "$root/evidence-v1.sha256" ]] \
      || die 'Reusable records are incomplete; preserve this root and prepare a new one.' 73
    printf '%s\n' 'Gate 1 evidence is valid and reused; no cells were rerun.'
    return
  fi
  local gate_lock
  gate_lock="$qualification_parent_root/$(printf '.phase09-gate%02d-active-v1' "$gate")"
  [[ ! -e "$root/active-run-v1" ]] || die 'An active qualification lock already exists; inspect it and do not rerun.' 75
  [[ ! -e "$gate_lock" ]] || die 'A gate-wide active qualification lock already exists; inspect it and do not rerun.' 75
  mkdir "$gate_lock" || die 'Unable to create the gate-wide active qualification lock.' 75
  chmod 700 "$gate_lock"
  qualification_started_at="$(timestamp)"
  printf '%s\n' $'root\tpid\tstarted_at\tsource_digest\tconfig_digest\ttoolchain_digest' > "$gate_lock/info-v1.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$root" "$$" "$qualification_started_at" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" \
    >> "$gate_lock/info-v1.tsv"
  chmod 600 "$gate_lock/info-v1.tsv"
  gate_lock_created=1
  mkdir "$root/active-run-v1" || die 'Unable to create the active qualification lock; the gate-wide lock is preserved.' 75
  chmod 700 "$root/active-run-v1"
  root_lock_created=1
  trap release_lock_on_success EXIT

  local cell command started_at finished_at status stdout_log stderr_log stdout_sha stderr_sha
  for cell in 1 2 3 4 5 6; do
    command="$(command_for_cell "$cell")"
    stdout_log="$root/$(printf 'cell-%02d.stdout.log' "$cell")"
    stderr_log="$root/$(printf 'cell-%02d.stderr.log' "$cell")"
    [[ ! -e "$stdout_log" && ! -e "$stderr_log" ]] \
      || die 'Cell logs already exist; preserve this root and do not rerun evidence.' 73
    started_at="$(timestamp)"
    set +e
    run_gate1_cell "$cell" > "$stdout_log" 2> "$stderr_log"
    status=$?
    set -e
    chmod 600 "$stdout_log" "$stderr_log"
    stdout_sha="$(sha256_file "$stdout_log")"
    stderr_sha="$(sha256_file "$stderr_log")"
    finished_at="$(timestamp)"
    if [[ "$status" != 0 ]]; then
      append_state "$cell" failed "$started_at" "$finished_at" "$stdout_sha" "$stderr_sha"
      append_failure "$cell" "$status" "$command" "$stdout_sha" "$stderr_sha"
      write_manifest failed "$finished_at"
      die "Gate 1 cell $cell failed; progress is frozen and the active lock is preserved." "$status"
    fi
    append_state "$cell" pass "$started_at" "$finished_at" "$stdout_sha" "$stderr_sha"
  done
  write_manifest passed "$(timestamp)"
  preserve_gate_lock_info
  write_evidence_digest
  run_succeeded=1
  release_lock_on_success
  printf '%s\n' 'Gate 1 qualification passed.'
}

validate_identity_field() {
  local identity="$1" item key key_lower seen=';'
  [[ "$identity" =~ ^[A-Za-z0-9._:=@/+,-]+(\;[A-Za-z0-9._:=@/+,-]+)*$ ]] \
    || die 'ownership identity must be a non-secret key=value list.' 66
  IFS=';' read -r -a items <<< "$identity"
  for item in "${items[@]}"; do
    key="${item%%=*}"
    [[ "$item" == *=* && -n "$key" && -n "${item#*=}" && "$seen" != *";$key;"* ]] \
      || die 'ownership identity contains an invalid or duplicate field.' 66
    key_lower="$(printf '%s' "$key" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    [[ "$key_lower" != *secret* && "$key_lower" != *password* && "$key_lower" != *token* \
        && "$key_lower" != *credential* && "$key_lower" != *private* && "$key_lower" != *keymaterial* ]] \
      || die 'ownership identity key names must not contain secret material.' 66
    seen="${seen}${key};"
  done
}

record_owned() {
  local type="$1" identifier="$2" path="$3" identity="$4" device='-' inode='-'
  validate_prepared_evidence
  [[ "$(/usr/bin/jq -r '.status' "$root/manifest-v1.json")" == prepared ]] \
    || die 'ownership records may be appended only while evidence is prepared.' 73
  case "$type" in
    pid) [[ "$identifier" =~ ^[1-9][0-9]*$ && "$path" == '-' ]] || die 'invalid ownership identifier for pid.' 66 ;;
    launchd) [[ "$identifier" =~ ^dev\.hostwright\.[A-Za-z0-9._-]+$ && "$path" == '-' ]] || die 'invalid ownership identifier for launchd.' 66 ;;
    socket|xpc|provider|temporary-root)
      [[ "$identifier" =~ ^[A-Za-z0-9._-]{1,160}$ && "$path" == /* && -e "$path" && ! -L "$path" \
          && "$(/bin/realpath "$path")" == "$path" && "$(stat -f '%u' "$path")" == "$(id -u)" ]] \
        || die "invalid ownership identifier or path for $type." 66
      device="$(stat -f '%d' "$path")"
      inode="$(stat -f '%i' "$path")"
      if [[ "$type" == temporary-root ]]; then
        [[ "$(dirname "$path")" == "$root" ]] || die 'temporary-root ownership must be directly inside the evidence root.' 66
      fi
      ;;
    container) [[ "$identifier" =~ ^[A-Za-z0-9._-]{1,160}$ && "$path" == '-' ]] \
      || die 'invalid ownership identifier or path for container.' 66 ;;
    keychain) [[ "$identifier" =~ ^hostwright\.phase09\.[A-Za-z0-9._-]+$ && "$path" == '-' ]] || die 'invalid ownership identifier for keychain.' 66 ;;
    *) die 'ownership type must be pid, launchd, socket, xpc, provider, container, keychain, or temporary-root.' 66 ;;
  esac
  validate_identity_field "$identity"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(timestamp)" "$type" "$identifier" "$path" "$device" "$inode" "$identity" >> "$root/ownership-v1.tsv"
  chmod 600 "$root/ownership-v1.tsv"
  printf '%s\n' 'Ownership record appended; no resource action was performed.'
}

cleanup_plan() {
  validate_evidence_structure
  printf '%s\n' 'Phase 09 cleanup plan only; no cleanup is executed.'
  /usr/bin/awk -F $'\t' 'NR == 1 { next } { printf "%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6 }' \
    "$root/ownership-v1.tsv"
}

main() {
  [[ "$#" -ge 1 ]] || die 'usage: phase09-gate-qualification.sh <contract|diagnose|prepare|run|status|finalize|record-owned|cleanup-plan> ...' 64
  validate_worktree
  case "$1" in
    contract)
      if [[ "$#" == 1 ]]; then
        contract
      elif [[ "$#" == 2 ]]; then
        validate_gate "$2"
        is_dedicated_gate "$gate" \
          || die 'contract accepts no arguments for non-dedicated gates.' 64
        dispatch_dedicated_gate contract "$gate"
      else
        die 'contract accepts no arguments, or one dedicated gate.' 64
      fi
      ;;
    diagnose)
      [[ "$#" == 2 ]] || die 'usage: diagnose <gate>.' 64
      validate_gate "$2"
      is_dedicated_gate "$gate" \
        || die "Gate $gate has no diagnostic dispatcher; fail closed." 69
      dispatch_dedicated_gate diagnose "$gate"
      ;;
    prepare)
      [[ "$#" == 2 ]] || die 'usage: prepare <gate>.' 64
      validate_gate "$2"
      is_dedicated_gate "$gate" && dispatch_dedicated_gate prepare "$gate"
      validate_worktree
      require_configured_gate
      validate_evidence_root
      require_empty_root
      collect_digests
      write_initial_evidence
      printf '%s\n' "Gate $gate evidence root prepared."
      ;;
    run)
      [[ "$#" == 2 ]] || die 'usage: run <gate>.' 64
      validate_gate "$2"
      is_dedicated_gate "$gate" && dispatch_dedicated_gate run "$gate"
      validate_worktree
      validate_evidence_root
      collect_digests
      run_gate
      ;;
    status)
      [[ "$#" == 2 ]] || die 'usage: status <gate>.' 64
      validate_gate "$2"
      is_dedicated_gate "$gate" \
        || die "Gate $gate has no status dispatcher; fail closed." 69
      dispatch_dedicated_gate status "$gate"
      ;;
    finalize)
      [[ "$#" == 2 || "$#" == 3 ]] || die 'usage: finalize <gate> <fixed-schema receipts JSON>.' 64
      validate_gate "$2"
      is_dedicated_gate "$gate" \
        || die "Gate $gate has no finalization dispatcher; fail closed." 69
      [[ "$#" == 3 || "$gate" == 16 ]] \
        || die 'usage: finalize <gate> <fixed-schema receipts JSON>.' 64
      dispatch_dedicated_gate finalize "$gate" "${3:-}"
      ;;
    record-owned)
      [[ "$#" == 6 ]] || die 'usage: record-owned <gate> <type> <identifier> <path-or-> <identity>.' 64
      validate_worktree
      validate_gate "$2"
      validate_evidence_root
      collect_digests
      record_owned "$3" "$4" "$5" "$6"
      ;;
    cleanup-plan)
      [[ "$#" == 2 ]] || die 'usage: cleanup-plan <gate>.' 64
      validate_worktree
      validate_gate "$2"
      validate_evidence_root
      cleanup_plan
      ;;
    *) die 'unknown qualification harness command.' 64 ;;
  esac
}

main "$@"
