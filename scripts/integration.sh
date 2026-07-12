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
overwrite_stdout="$workdir/overwrite.stdout"
overwrite_stderr="$workdir/overwrite.stderr"

cleanup() {
  exit_code=$?
  trap - EXIT
  set +e
  rm -f "$manifest" "$plan_json" "$status_json" "$doctor_json" "$overwrite_stdout" "$overwrite_stderr"
  rmdir "$workdir"
  exit "$exit_code"
}
trap cleanup EXIT

version="$("$hostwright" --version)"
[[ "$version" == "hostwright 0.1.0-alpha.1" ]]

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

if find "$workdir" -name '*.sqlite*' -print -quit | grep -q .; then
  echo "local integration unexpectedly created a state database" >&2
  exit 1
fi

echo "local-integration passed: built CLI, JSON output, overwrite refusal, and no hidden state writes"
