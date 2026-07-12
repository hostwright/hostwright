#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

swift build --product hostwright
bin_dir="$(swift build --show-bin-path)"
hostwright="$bin_dir/hostwright"
if [[ ! -x "$hostwright" ]]; then
  echo "built hostwright executable not found at $hostwright" >&2
  exit 1
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/hostwright-integration.XXXXXX")"
manifest="$workdir/hostwright.yaml"
plan_json="$workdir/plan.json"
status_json="$workdir/status.json"
doctor_json="$workdir/doctor.json"
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

cleanup() {
  exit_code=$?
  trap - EXIT
  set +e
  chmod 700 "$readonly_dir" 2>/dev/null
  rm -f "$manifest" "$plan_json" "$status_json" "$doctor_json" "$team_profile" "$team_plan_json" "$stack_file" "$team_import_json" "$invalid_profile" "$overwrite_stdout" "$overwrite_stderr" "$missing_stdout" "$missing_stderr" "$benchmark_existing_report" "$benchmark_absent_report" "$readonly_dir/hostwright.yaml"
  rmdir "$readonly_dir" 2>/dev/null
  rmdir "$workdir"
  exit "$exit_code"
}
trap cleanup EXIT

version="$("$hostwright" --version)"
[[ "$version" == "0.1.0-alpha.1" ]]

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
"$hostwright" status "$manifest" --output json >"$status_json"
"$hostwright" doctor --output json >"$doctor_json"

for json_file in "$plan_json" "$status_json" "$doctor_json"; do
  plutil -convert json -o /dev/null "$json_file"
done
grep -q '"planHash"' "$plan_json"
grep -q '"observed":false' "$status_json"
grep -q '"checks"' "$doctor_json"

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

if find "$workdir" -name '*.sqlite*' -print -quit | grep -q .; then
  echo "local integration unexpectedly created a state database" >&2
  exit 1
fi

echo "local-integration passed: built CLI, team-profile and benchmark argument gates, JSON output/errors, real file failures, overwrite refusal, and no hidden state writes"
