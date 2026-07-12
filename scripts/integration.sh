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
  rm -f "$manifest" "$plan_json" "$status_json" "$doctor_json" "$team_profile" "$team_plan_json" "$stack_file" "$team_import_json" "$invalid_profile" "$overwrite_stdout" "$overwrite_stderr" "$missing_stdout" "$missing_stderr" "$benchmark_existing_report" "$benchmark_absent_report" "$unexpected_distribution_report" "$extension_fixture" "$extension_declaration" "$extension_failure_declaration" "$extension_json" "$control_request" "$control_response" "$control_rejected_request" "$control_rejected_response" "$readonly_dir/hostwright.yaml"
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

printf '%s\n' '{"apiVersion":1,"requestID":"integration-plan-1","operation":"plan"}' >"$control_request"
"$hostwright_control" --manifest "$manifest" <"$control_request" >"$control_response" 2>"$missing_stderr"
[[ ! -s "$missing_stderr" ]]
[[ "$(wc -l <"$control_response" | tr -d ' ')" -eq 1 ]]
plutil -convert json -o /dev/null "$control_response"
grep -q '"apiVersion":1' "$control_response"
grep -q '"requestID":"integration-plan-1"' "$control_response"
grep -q '"success":true' "$control_response"
grep -q '"kind":"plan"' "$control_response"

printf '%s\n' '{"apiVersion":1,"requestID":"integration-apply-1","operation":"apply"}' >"$control_rejected_request"
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
grep -q 'developer distribution evidence tool' "$missing_stdout"
grep -q 'never signs, notarizes, staples' "$missing_stdout"

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

if find "$workdir" -name '*.sqlite*' -print -quit | grep -q .; then
  echo "local integration unexpectedly created a state database" >&2
  exit 1
fi

echo "local-integration passed: built CLI, one-shot control API, and distribution tool; reviewed-local extension subprocess handshake, team-profile/benchmark/distribution gates, JSON output/errors, real file failures, overwrite refusal, rejected control mutation, and no hidden state writes"
