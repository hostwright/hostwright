#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

swift build --product hostwright
swift build --product hostwright-control
swift build --product hostwright-dist
bin_dir="$(swift build --show-bin-path)"
hostwright="$bin_dir/hostwright"
hostwright_control="$bin_dir/hostwright-control"
hostwright_dist="$bin_dir/hostwright-dist"
if [[ ! -x "$hostwright" ]]; then
  echo "built hostwright executable not found at $hostwright" >&2
  exit 1
fi
if [[ ! -x "$hostwright_dist" ]]; then
  echo "built hostwright-dist executable not found at $hostwright_dist" >&2
  exit 1
fi
if [[ ! -x "$hostwright_control" ]]; then
  echo "built hostwright-control executable not found at $hostwright_control" >&2
  exit 1
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/hostwright-integration.XXXXXX")"
workdir="$(cd "$workdir" && pwd -P)"
manifest="$workdir/hostwright.yaml"
plan_json="$workdir/plan.json"
status_json="$workdir/status.json"
doctor_json="$workdir/doctor.json"
doctor_state_json="$workdir/doctor-state.json"
default_paths_json="$workdir/default-paths.json"
paths_before_json="$workdir/paths-before.json"
paths_after_json="$workdir/paths-after.json"
application_support="$workdir/Application Support/Hostwright"
cache_directory="$workdir/Caches/Hostwright"
log_directory="$workdir/Logs/Hostwright"
state_directory="$workdir/state"
state_database="$state_directory/state.sqlite"
state_digest="$(printf '%s' "$state_database" | shasum -a 256 | awk '{print substr($1, 1, 16)}')"
state_access_lock="$state_directory/.hostwright-$state_digest-access-v1.lock"
state_writer_lock="$state_access_lock.writer"
state_maintenance_journal="$state_directory/.hostwright-$state_digest-maintenance-v1.json"
state_backups="$state_directory/.hostwright-$state_digest-backups"
state_integrity_json="$workdir/state-integrity.json"
state_backup_json="$workdir/state-backup.json"
state_catalog_json="$workdir/state-catalog.json"
state_restore_plan_json="$workdir/state-restore-plan.json"
state_restore_result_json="$workdir/state-restore-result.json"
state_recovery_json="$workdir/state-recovery.json"
team_profile="$workdir/team-profile.json"
team_plan_json="$workdir/team-plan.json"
stack_file="$workdir/compose.yaml"
team_import_json="$workdir/team-import.json"
invalid_profile="$workdir/invalid-team-profile.json"
overwrite_stdout="$workdir/overwrite.stdout"
overwrite_stderr="$workdir/overwrite.stderr"
missing_stdout="$workdir/missing.stdout"
missing_stderr="$workdir/missing.stderr"
readonly_dir="$workdir/read-only"
benchmark_existing_report="$workdir/benchmark-existing.json"
benchmark_absent_report="$workdir/benchmark-absent.json"
unexpected_distribution_report="$workdir/unexpected-distribution-report.json"
extension_fixture="$workdir/extension-fixture"
extension_declaration="$workdir/extension.json"
extension_failure_declaration="$workdir/extension-failure.json"
extension_json="$workdir/extension-result.json"
control_request="$workdir/control-request.json"
control_response="$workdir/control-response.json"
control_rejected_request="$workdir/control-rejected-request.json"
control_rejected_response="$workdir/control-rejected-response.json"

cleanup() {
  exit_code=$?
  trap - EXIT
  set +e
  chmod 700 "$readonly_dir" 2>/dev/null
  rm -f "$manifest" "$plan_json" "$status_json" "$doctor_json" "$doctor_state_json" "$default_paths_json" "$paths_before_json" "$paths_after_json" "$state_integrity_json" "$state_backup_json" "$state_catalog_json" "$state_restore_plan_json" "$state_restore_result_json" "$state_recovery_json" "$team_profile" "$team_plan_json" "$stack_file" "$team_import_json" "$invalid_profile" "$overwrite_stdout" "$overwrite_stderr" "$missing_stdout" "$missing_stderr" "$benchmark_existing_report" "$benchmark_absent_report" "$unexpected_distribution_report" "$extension_fixture" "$extension_declaration" "$extension_failure_declaration" "$extension_json" "$control_request" "$control_response" "$control_rejected_request" "$control_rejected_response" "$readonly_dir/hostwright.yaml" "$state_database" "$state_database-wal" "$state_database-shm" "$state_database-journal" "$state_access_lock" "$state_writer_lock" "$state_maintenance_journal"
  if [[ -d "$state_backups" ]]; then
    shopt -s nullglob
    for backup_directory in "$state_backups"/backup-*; do
      rm -f "$backup_directory/manifest.json" "$backup_directory/state.sqlite"
      rmdir "$backup_directory" 2>/dev/null
    done
    shopt -u nullglob
    rmdir "$state_backups" 2>/dev/null
  fi
  rmdir "$readonly_dir" 2>/dev/null
  rmdir "$state_directory" 2>/dev/null
  rmdir "$workdir"
  exit "$exit_code"
}
trap cleanup EXIT

version="$("$hostwright" --version)"
golden_version="$(plutil -extract productVersion raw contracts/v0.0.2/versions.json)"
[[ "$version" == "$golden_version" ]]
[[ "$version" =~ ^0\.0\.2-dev\.[56]$ ]]

export HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$application_support"
export HOSTWRIGHT_CACHE_DIR="$cache_directory"
export HOSTWRIGHT_LOG_DIR="$log_directory"

env -u HOSTWRIGHT_STATE_DB "$hostwright" paths --json >"$default_paths_json"
plutil -convert json -o /dev/null "$default_paths_json"
grep -q '"statePathOrigin":"application-support-default"' "$default_paths_json"
grep -Fq "Application Support\/Hostwright\/state\/state.sqlite" "$default_paths_json"
[[ ! -e "$application_support" ]]

mkdir "$state_directory"
chmod 700 "$state_directory"
export HOSTWRIGHT_STATE_DB="$state_database"
"$hostwright" paths --json >"$paths_before_json"
plutil -convert json -o /dev/null "$paths_before_json"
grep -q '"statePathOrigin":"environment"' "$paths_before_json"
grep -q '"readiness":"needs-creation"' "$paths_before_json"
[[ ! -e "$state_database" ]]

(
  cd "$workdir"
  "$hostwright" init >/dev/null
)
[[ -f "$manifest" ]]

before_checksum="$(shasum -a 256 "$manifest" | awk '{print $1}')"
set +e
(
  cd "$workdir"
  "$hostwright" init >"$overwrite_stdout" 2>"$overwrite_stderr"
)
overwrite_exit=$?
set -e
[[ "$overwrite_exit" -eq 64 ]]
after_checksum="$(shasum -a 256 "$manifest" | awk '{print $1}')"
[[ "$before_checksum" == "$after_checksum" ]]

"$hostwright" validate "$manifest" >/dev/null
"$hostwright" plan "$manifest" --output json >"$plan_json"
set +e
(
  cd "$workdir"
  "$hostwright" doctor --state-db "$state_database" --json >"$doctor_json"
)
doctor_exit=$?
set -e
[[ "$doctor_exit" -eq 0 || "$doctor_exit" -eq 69 ]]

for json_file in "$plan_json" "$doctor_json"; do
  plutil -convert json -o /dev/null "$json_file"
done
grep -q '"planHash"' "$plan_json"
grep -q '"checks"' "$doctor_json"
[[ "$(plutil -extract schemaVersion raw "$doctor_json")" == "2" ]]
[[ "$(plutil -extract checks.7.identifier raw "$doctor_json")" == "stateIntegrity" ]]
[[ "$(plutil -extract checks.7.status raw "$doctor_json")" == "degraded" ]]
[[ ! -e "$state_database" ]]
if [[ "$doctor_exit" -eq 69 ]]; then
  [[ "$(plutil -extract hasExternalConstraints raw "$doctor_json")" == "true" ]]
fi

if command -v container >/dev/null 2>&1; then
  "$hostwright" status "$manifest" --output json >"$status_json"
  plutil -convert json -o /dev/null "$status_json"
  grep -q '"observed":true' "$status_json"
  [[ "$(plutil -extract stateDatabasePath raw "$status_json")" == "$state_database" ]]
else
  set +e
  "$hostwright" status "$manifest" --output json >"$status_json" 2>"$missing_stderr"
  status_exit=$?
  set -e
  [[ "$status_exit" -eq 69 ]]
  [[ ! -s "$status_json" ]]
  plutil -convert json -o /dev/null "$missing_stderr"
  grep -q '"code":"HW-RUNTIME-001"' "$missing_stderr"
  grep -q '"exitCode":69' "$missing_stderr"
fi

"$hostwright" paths --json >"$paths_after_json"
plutil -convert json -o /dev/null "$paths_after_json"
grep -q '"readiness":"ready"' "$paths_after_json"
[[ -f "$state_database" ]]
[[ "$(stat -f '%Lp' "$state_directory")" == "700" ]]
[[ "$(stat -f '%Lp' "$state_database")" == "600" ]]

state_files_before_doctor="$(find "$state_directory" -type f | LC_ALL=C sort)"
state_hashes_before_doctor="$(find "$state_directory" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort)"
set +e
(
  cd "$workdir"
  "$hostwright" doctor --state-db "$state_database" --json >"$doctor_state_json"
)
doctor_state_exit=$?
set -e
[[ "$doctor_state_exit" -eq 0 || "$doctor_state_exit" -eq 69 ]]
plutil -convert json -o /dev/null "$doctor_state_json"
[[ "$(plutil -extract checks.7.identifier raw "$doctor_state_json")" == "stateIntegrity" ]]
[[ "$(plutil -extract checks.7.status raw "$doctor_state_json")" == "ready" ]]
[[ "$(find "$state_directory" -type f | LC_ALL=C sort)" == "$state_files_before_doctor" ]]
[[ "$(find "$state_directory" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort)" == "$state_hashes_before_doctor" ]]

"$hostwright" state integrity --state-db "$state_database" --json >"$state_integrity_json"
"$hostwright" state backup --state-db "$state_database" --json >"$state_backup_json"
"$hostwright" state backups --state-db "$state_database" --json >"$state_catalog_json"
for json_file in "$state_integrity_json" "$state_backup_json" "$state_catalog_json"; do
  plutil -convert json -o /dev/null "$json_file"
done
grep -q '"kind":"stateIntegrityReport"' "$state_integrity_json"
grep -q '"health":"healthy"' "$state_integrity_json"
grep -q '"kind":"stateBackupRecord"' "$state_backup_json"
grep -q '"restorable":true' "$state_backup_json"
state_backup_id="$(plutil -extract backupID raw "$state_backup_json")"
[[ "$state_backup_id" == backup-* ]]
grep -Fq "\"backupID\":\"$state_backup_id\"" "$state_catalog_json"

"$hostwright" state restore --backup "$state_backup_id" --dry-run --state-db "$state_database" --json >"$state_restore_plan_json"
plutil -convert json -o /dev/null "$state_restore_plan_json"
state_restore_token="$(plutil -extract confirmationToken raw "$state_restore_plan_json")"
[[ "$state_restore_token" =~ ^[a-f0-9]{64}$ ]]
"$hostwright" state restore --backup "$state_backup_id" --confirm-restore "$state_restore_token" --state-db "$state_database" --json >"$state_restore_result_json"
plutil -convert json -o /dev/null "$state_restore_result_json"
grep -q '"health":"healthy"' "$state_restore_result_json"
grep -Fq "\"backupID\":\"$state_backup_id\"" "$state_restore_result_json"
"$hostwright" state recover --state-db "$state_database" --json >"$state_recovery_json"
plutil -convert json -o /dev/null "$state_recovery_json"
grep -q '"recovered":false' "$state_recovery_json"
[[ "$(stat -f '%Lp' "$state_backups")" == "700" ]]
[[ "$(stat -f '%Lp' "$state_backups/$state_backup_id/state.sqlite")" == "600" ]]

printf '%s\n' '{"apiVersion":2,"requestID":"integration-plan-1","operation":"plan"}' >"$control_request"
"$hostwright_control" --manifest "$manifest" <"$control_request" >"$control_response" 2>"$missing_stderr"
[[ ! -s "$missing_stderr" ]]
[[ "$(wc -l <"$control_response" | tr -d ' ')" -eq 1 ]]
plutil -convert json -o /dev/null "$control_response"
grep -q '"apiVersion":2' "$control_response"
grep -q '"requestID":"integration-plan-1"' "$control_response"
grep -q '"success":true' "$control_response"
grep -q '"kind":"plan"' "$control_response"

printf '%s\n' '{"apiVersion":2,"requestID":"integration-apply-1","operation":"apply"}' >"$control_rejected_request"
set +e
"$hostwright_control" --manifest "$manifest" <"$control_rejected_request" >"$control_rejected_response" 2>"$missing_stderr"
control_rejected_exit=$?
set -e
[[ "$control_rejected_exit" -eq 65 ]]
[[ ! -s "$missing_stderr" ]]
[[ "$(wc -l <"$control_rejected_response" | tr -d ' ')" -eq 1 ]]
plutil -convert json -o /dev/null "$control_rejected_response"
grep -q '"code":"HW-API-001"' "$control_rejected_response"
grep -q '"success":false' "$control_rejected_response"

printf '%s\n' \
  '{' \
  '  "kind": "HostwrightTeamProfile",' \
  '  "apiVersion": 1,' \
  '  "identifier": "dev.hostwright.integration",' \
  '  "displayName": "Built CLI Integration",' \
  '  "optIn": true,' \
  '  "requiredGates": ["runtimeAdapter", "explicitStatePath", "localPolicy", "redaction", "auditTrail", "planConfirmation", "cleanupConfirmation", "ownershipChecks", "localOnlyNoCloud", "noTelemetryUpload"],' \
  '  "requirements": ["requireManifestReview"]' \
  '}' >"$team_profile"

printf '%s\n' \
  'name: integration' \
  'services:' \
  '  api:' \
  '    image: local/integration:latest' \
  '    command: ["serve"]' >"$stack_file"

"$hostwright" validate "$manifest" --team-profile "$team_profile" >/dev/null
"$hostwright" plan "$manifest" --team-profile "$team_profile" --output json >"$team_plan_json"
"$hostwright" import-stack "$stack_file" --team-profile "$team_profile" --output json >"$team_import_json"
for json_file in "$team_plan_json" "$team_import_json"; do
  plutil -convert json -o /dev/null "$json_file"
  grep -q '"teamPolicy"' "$json_file"
  grep -q '"profileHash"' "$json_file"
  grep -q '"manifestHash"' "$json_file"
done

printf '%s\n' '{"kind":"HostwrightTeamProfile","unexpected":"token=must-not-leak"}' >"$invalid_profile"
set +e
"$hostwright" plan "$manifest" --team-profile "$invalid_profile" --output json >"$missing_stdout" 2>"$missing_stderr"
invalid_profile_exit=$?
set -e
[[ "$invalid_profile_exit" -eq 65 ]]
[[ ! -s "$missing_stdout" ]]
plutil -convert json -o /dev/null "$missing_stderr"
grep -q '"code":"HW-TEAM-001"' "$missing_stderr"
if grep -q 'must-not-leak' "$missing_stderr"; then
  echo "team profile error leaked rejected field content" >&2
  exit 1
fi

set +e
"$hostwright" apply "$manifest" --state-db "$workdir/unexpected.sqlite" --confirm-plan unused --team-profile "$team_profile" >"$missing_stdout" 2>"$missing_stderr"
missing_approval_exit=$?
set -e
[[ "$missing_approval_exit" -eq 64 ]]
grep -q -- '--approval-record' "$missing_stderr"
[[ ! -e "$workdir/unexpected.sqlite" ]]

set +e
"$hostwright" benchmark \
  --image docker.io/library/python:alpine \
  --samples 3 \
  --report "$benchmark_absent_report" \
  --source-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --source-dirty false \
  --expected-container-version 1.0.0 \
  >"$missing_stdout" 2>"$missing_stderr"
benchmark_confirmation_exit=$?
set -e
[[ "$benchmark_confirmation_exit" -eq 64 ]]
grep -q -- '--confirm-live' "$missing_stderr"
[[ ! -e "$benchmark_absent_report" ]]

printf 'sentinel benchmark report\n' >"$benchmark_existing_report"
benchmark_before_checksum="$(shasum -a 256 "$benchmark_existing_report" | awk '{print $1}')"
set +e
"$hostwright" benchmark \
  --image docker.io/library/python:alpine \
  --samples 3 \
  --report "$benchmark_existing_report" \
  --source-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --source-dirty false \
  --expected-container-version 1.0.0 \
  --confirm-live \
  >"$missing_stdout" 2>"$missing_stderr"
benchmark_overwrite_exit=$?
set -e
[[ "$benchmark_overwrite_exit" -eq 64 ]]
grep -q 'HW-CLI-002' "$missing_stderr"
benchmark_after_checksum="$(shasum -a 256 "$benchmark_existing_report" | awk '{print $1}')"
[[ "$benchmark_before_checksum" == "$benchmark_after_checksum" ]]

"$hostwright_dist" --help >"$missing_stdout" 2>"$missing_stderr"
grep -q 'trusted and developer distribution tool' "$missing_stdout"
grep -q 'hostwright-dist release' "$missing_stdout"
grep -q 'hostwright-dist verify-release' "$missing_stdout"
grep -q 'hostwright-dist homebrew-formula' "$missing_stdout"
grep -q 'never accepts passwords, private keys, or tokens in argv' "$missing_stdout"

for trusted_release_command in release verify-release homebrew-formula; do
  set +e
  "$hostwright_dist" "$trusted_release_command" --format json >"$missing_stdout" 2>"$missing_stderr"
  trusted_release_error_exit=$?
  set -e
  [[ "$trusted_release_error_exit" -eq 64 ]]
  [[ ! -s "$missing_stdout" ]]
  plutil -convert json -o /dev/null "$missing_stderr"
  [[ "$(plutil -extract kind raw "$missing_stderr")" == "distributionToolError" ]]
  [[ "$(plutil -extract exitCode raw "$missing_stderr")" == "64" ]]
done

set +e
"$hostwright_dist" homebrew-formula --output json >"$missing_stdout" 2>"$missing_stderr"
formula_path_error_exit=$?
set -e
[[ "$formula_path_error_exit" -eq 64 ]]
grep -q '^HW-DIST-001:' "$missing_stderr"

/usr/bin/swiftc "$root/Tests/HostwrightExtensionsTests/Fixtures/ExtensionFixture.swift" -o "$extension_fixture"
chmod 700 "$extension_fixture"
extension_sha256="$(shasum -a 256 "$extension_fixture" | awk '{print $1}')"
printf '%s\n' \
  '{' \
  '  "kind": "diagnosticsIntegration",' \
  '  "apiVersion": 1,' \
  '  "protocolVersion": 1,' \
  '  "identifier": "dev.hostwright.built-cli",' \
  '  "trust": "reviewedLocal",' \
  '  "capability": "diagnosticsRead",' \
  '  "purpose": "Exercise the built CLI reviewed-local extension handshake.",' \
  '  "boundaries": ["stateStore", "explicitStatePath", "redaction", "auditTrail", "localOnlyNoUpload", "noRuntimeMutation"],' \
  "  \"executableSHA256\": \"$extension_sha256\"" \
  '}' >"$extension_declaration"
chmod 600 "$extension_declaration"

HOSTWRIGHT_EXTENSION_TEST_SECRET='token=parent-must-not-reach-extension' \
  "$hostwright" extension check --declaration "$extension_declaration" --executable "$extension_fixture" --output json >"$extension_json"
plutil -convert json -o /dev/null "$extension_json"
grep -q '"kind":"extensionHandshake"' "$extension_json"
grep -q '"status":"ready"' "$extension_json"
grep -q '"cleanup":"succeeded"' "$extension_json"
HOSTWRIGHT_EXTENSION_TEST_SECRET='token=parent-must-not-reach-extension' \
  "$hostwright" extension check --declaration "$extension_declaration" --executable "$extension_fixture" >"$missing_stdout"
grep -q 'Reviewed-local extension handshake ready' "$missing_stdout"
grep -q 'Staging cleanup: succeeded' "$missing_stdout"

sed 's/dev.hostwright.built-cli/dev.hostwright.built-cli.failure/' "$extension_declaration" >"$extension_failure_declaration"
chmod 600 "$extension_failure_declaration"
set +e
"$hostwright" extension check --declaration "$extension_failure_declaration" --executable "$extension_fixture" --output json >"$missing_stdout" 2>"$missing_stderr"
extension_failure_exit=$?
set -e
[[ "$extension_failure_exit" -eq 72 ]]
[[ ! -s "$missing_stdout" ]]
plutil -convert json -o /dev/null "$missing_stderr"
grep -q '"code":"HW-EXT-003"' "$missing_stderr"
if grep -q 'fixture-secret-must-not-leak' "$missing_stderr"; then
  echo "extension process error leaked raw stderr" >&2
  exit 1
fi

set +e
"$hostwright_dist" lifecycle \
  --baseline-dir "$workdir/missing-baseline" \
  --candidate-dir "$workdir/missing-candidate" \
  --prefix /usr/local/hostwright-dist-unsafe \
  --report "$unexpected_distribution_report" \
  >"$missing_stdout" 2>"$missing_stderr"
distribution_prefix_exit=$?
set -e
[[ "$distribution_prefix_exit" -eq 64 ]]
grep -q 'temporary directory' "$missing_stderr"
[[ ! -e "$unexpected_distribution_report" ]]

set +e
"$hostwright" plan "$workdir/missing.yaml" --output json >"$missing_stdout" 2>"$missing_stderr"
missing_exit=$?
set -e
[[ "$missing_exit" -eq 65 ]]
[[ ! -s "$missing_stdout" ]]
plutil -convert json -o /dev/null "$missing_stderr"
grep -q '"code":"HW-MANIFEST-004"' "$missing_stderr"

set +e
"$hostwright" import-stack "$workdir/missing-compose.yaml" --output json >"$missing_stdout" 2>"$missing_stderr"
missing_exit=$?
set -e
[[ "$missing_exit" -eq 64 ]]
[[ ! -s "$missing_stdout" ]]
plutil -convert json -o /dev/null "$missing_stderr"
grep -q '"code":"HW-CLI-005"' "$missing_stderr"

mkdir "$readonly_dir"
chmod 500 "$readonly_dir"
set +e
(
  cd "$readonly_dir"
  "$hostwright" init >"$missing_stdout" 2>"$missing_stderr"
)
readonly_exit=$?
set -e
chmod 700 "$readonly_dir"
[[ "$readonly_exit" -eq 64 ]]
[[ ! -s "$missing_stdout" ]]
grep -q 'HW-CLI-005' "$missing_stderr"

while IFS= read -r sqlite_path; do
  if [[ "$sqlite_path" == "$state_database" ]]; then
    continue
  fi
  case "$sqlite_path" in
    "$state_database-wal"|"$state_database-shm")
      [[ "$(stat -f '%Lp' "$sqlite_path")" == "600" ]]
      ;;
    "$state_backups"/backup-*/state.sqlite)
      ;;
    *)
      echo "local integration created an unexpected state database or sidecar: $sqlite_path" >&2
      exit 1
      ;;
  esac
done < <(find "$workdir" -name '*.sqlite*' -print)
[[ ! -e "$state_database-journal" ]]

echo "local-integration passed: built CLI, isolated path resolution, private state creation, verified online backup/restore/recovery, one-shot control API, and distribution tool; reviewed-local extension subprocess handshake, team-profile/benchmark/distribution gates, JSON output/errors, real file failures, overwrite refusal, rejected control mutation, and no unexpected state writes"
