#!/bin/bash

set -euo pipefail
umask 077

readonly SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
readonly MAX_REPORT_BYTES=$((8 * 1024 * 1024))
readonly MAX_STREAM_BYTES=$((1024 * 1024))
readonly EXIT_USAGE=64
readonly EXIT_BLOCKED=69
readonly EXIT_FAILED=70

usage() {
  cat <<'EOF'
Usage:
  scripts/phase03-qualification.sh conformance \
    --lane apple-cli-1.0.0|apple-cli-1.1.0|containerization-0.35.0 \
    --conformance-bin <hostwright-runtime-conformance> \
    --local-image <existing-local-reference> --output <new-evidence.json>

  scripts/phase03-qualification.sh migration \
    --source-lane apple-cli-1.0.0|apple-cli-1.1.0|containerization-0.35.0 \
    --target-lane apple-cli-1.0.0|apple-cli-1.1.0|containerization-0.35.0 \
    --conformance-bin <hostwright-runtime-conformance> \
    --local-image <existing-local-reference> --output <new-evidence.json>

  scripts/phase03-qualification.sh recovery \
    --lane apple-cli-1.0.0|apple-cli-1.1.0|containerization-0.35.0 \
    --scenario cli-service-restart|helper-restart|hostwright-termination|mixed-component-versions|checkpoint-crash|stale-helper|future-protocol-refusal|downgrade-refusal \
    --conformance-bin <hostwright-runtime-conformance> \
    [--prior-helper-bin <signed-H1-hostwright-containerization-helper>] \
    --local-image <existing-local-reference> --output <new-evidence.json>

This maintainer-only harness never downloads or pulls an image. Every lane requires
an already-local workload image, exact provider versions, passing cleanup evidence,
and unchanged unmanaged-runtime inventory.
EOF
}

usage_error() {
  printf 'USAGE: %s\n' "$1" >&2
  usage >&2
  exit "$EXIT_USAGE"
}

blocked() {
  printf 'BLOCKED: %s\n' "$1" >&2
  exit "$EXIT_BLOCKED"
}

failed() {
  printf 'FAILED: %s\n' "$1" >&2
  exit "$EXIT_FAILED"
}

require_option_value() {
  local option="$1"
  local value="${2-}"
  [[ -n "$value" && "$value" != --* ]] || usage_error "$option requires one value."
}

lane_provider() {
  case "$1" in
    apple-cli-1.0.0|apple-cli-1.1.0) printf '%s\n' 'apple-container-cli' ;;
    containerization-0.35.0) printf '%s\n' 'apple-containerization' ;;
    *) usage_error "unsupported Phase 03 lane '$1'." ;;
  esac
}

lane_version() {
  case "$1" in
    apple-cli-1.0.0) printf '%s\n' '1.0.0' ;;
    apple-cli-1.1.0) printf '%s\n' '1.1.0' ;;
    containerization-0.35.0) printf '%s\n' '0.35.0' ;;
    *) usage_error "unsupported Phase 03 lane '$1'." ;;
  esac
}

validate_scalar() {
  local name="$1"
  local value="$2"
  local maximum="$3"
  [[ -n "$value" ]] || usage_error "$name must not be empty."
  [[ ${#value} -le "$maximum" ]] || usage_error "$name exceeds $maximum bytes."
  [[ "$value" != -* ]] || usage_error "$name must not begin with '-'."
  case "$value" in
    *$'\n'*|*$'\r'*|*$'\t'*) usage_error "$name contains control characters." ;;
  esac
}

validate_recovery_scenario() {
  local lane="$1"
  local scenario="$2"
  local provider
  provider="$(lane_provider "$lane")"
  case "$scenario" in
    cli-service-restart)
      [[ "$provider" == apple-container-cli ]] \
        || usage_error "cli-service-restart requires an Apple CLI lane."
      ;;
    helper-restart|stale-helper)
      [[ "$provider" == apple-containerization ]] \
        || usage_error "$scenario requires the Containerization lane."
      ;;
    hostwright-termination|mixed-component-versions|checkpoint-crash|future-protocol-refusal|downgrade-refusal)
      ;;
    *) usage_error "unsupported Phase 03 recovery scenario '$scenario'." ;;
  esac
}

OPERATION="${1-}"
[[ -n "$OPERATION" ]] || usage_error "a qualification operation is required."
case "$OPERATION" in
  -h|--help)
    usage
    exit 0
    ;;
  conformance|migration|recovery) shift ;;
  *) usage_error "unsupported qualification operation '$OPERATION'." ;;
esac

LANE=""
SOURCE_LANE=""
TARGET_LANE=""
SCENARIO=""
CONFORMANCE_BIN=""
PRIOR_HELPER_BIN=""
LOCAL_IMAGE=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lane)
      require_option_value "$1" "${2-}"
      [[ -z "$LANE" ]] || usage_error "--lane may be supplied only once."
      LANE="$2"
      shift 2
      ;;
    --source-lane)
      require_option_value "$1" "${2-}"
      [[ -z "$SOURCE_LANE" ]] || usage_error "--source-lane may be supplied only once."
      SOURCE_LANE="$2"
      shift 2
      ;;
    --target-lane)
      require_option_value "$1" "${2-}"
      [[ -z "$TARGET_LANE" ]] || usage_error "--target-lane may be supplied only once."
      TARGET_LANE="$2"
      shift 2
      ;;
    --scenario)
      require_option_value "$1" "${2-}"
      [[ -z "$SCENARIO" ]] || usage_error "--scenario may be supplied only once."
      SCENARIO="$2"
      shift 2
      ;;
    --conformance-bin)
      require_option_value "$1" "${2-}"
      [[ -z "$CONFORMANCE_BIN" ]] || usage_error "--conformance-bin may be supplied only once."
      CONFORMANCE_BIN="$2"
      shift 2
      ;;
    --prior-helper-bin)
      require_option_value "$1" "${2-}"
      [[ -z "$PRIOR_HELPER_BIN" ]] || usage_error "--prior-helper-bin may be supplied only once."
      PRIOR_HELPER_BIN="$2"
      shift 2
      ;;
    --local-image)
      require_option_value "$1" "${2-}"
      [[ -z "$LOCAL_IMAGE" ]] || usage_error "--local-image may be supplied only once."
      LOCAL_IMAGE="$2"
      shift 2
      ;;
    --output)
      require_option_value "$1" "${2-}"
      [[ -z "$OUTPUT" ]] || usage_error "--output may be supplied only once."
      OUTPUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) usage_error "unsupported option '$1'." ;;
  esac
done

case "$OPERATION" in
  conformance)
    [[ -n "$LANE" && -z "$SOURCE_LANE" && -z "$TARGET_LANE" && -z "$SCENARIO" \
      && -z "$PRIOR_HELPER_BIN" ]] \
      || usage_error "conformance requires only one --lane."
    lane_provider "$LANE" >/dev/null
    ;;
  migration)
    [[ -z "$LANE" && -n "$SOURCE_LANE" && -n "$TARGET_LANE" && -z "$SCENARIO" \
      && -z "$PRIOR_HELPER_BIN" ]] \
      || usage_error "migration requires --source-lane and --target-lane."
    SOURCE_PROVIDER="$(lane_provider "$SOURCE_LANE")"
    TARGET_PROVIDER="$(lane_provider "$TARGET_LANE")"
    [[ "$SOURCE_PROVIDER" != "$TARGET_PROVIDER" ]] \
      || usage_error "migration requires one Apple CLI lane and the Containerization lane."
    ;;
  recovery)
    [[ -n "$LANE" && -z "$SOURCE_LANE" && -z "$TARGET_LANE" && -n "$SCENARIO" ]] \
      || usage_error "recovery requires --lane and --scenario."
    lane_provider "$LANE" >/dev/null
    validate_recovery_scenario "$LANE" "$SCENARIO"
    if [[ "$SCENARIO" == stale-helper ]]; then
      [[ -n "$PRIOR_HELPER_BIN" ]] \
        || usage_error "stale-helper requires --prior-helper-bin."
    else
      [[ -z "$PRIOR_HELPER_BIN" ]] \
        || usage_error "--prior-helper-bin is accepted only for stale-helper."
    fi
    ;;
esac

[[ -n "$CONFORMANCE_BIN" ]] || usage_error "--conformance-bin is required."
[[ -n "$LOCAL_IMAGE" ]] || usage_error "--local-image is required."
[[ -n "$OUTPUT" ]] || usage_error "--output is required."
validate_scalar "--local-image" "$LOCAL_IMAGE" 512

[[ "$(basename "$CONFORMANCE_BIN")" == hostwright-runtime-conformance ]] \
  || blocked "the internal executable must be named hostwright-runtime-conformance."
[[ -x "$CONFORMANCE_BIN" && -f "$CONFORMANCE_BIN" ]] \
  || blocked "hostwright-runtime-conformance is unavailable at the supplied path."

PYTHON_BIN="$(command -v python3 || true)"
[[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] || blocked "python3 is unavailable."

if [[ -n "$PRIOR_HELPER_BIN" ]]; then
  PRIOR_HELPER_BIN="$($PYTHON_BIN - "$PRIOR_HELPER_BIN" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
if len(path.encode("utf-8")) > 1024 or any(ord(character) < 32 or ord(character) == 127 for character in path):
    raise SystemExit(1)
if not os.path.isabs(path) or os.path.normpath(path) != path:
    raise SystemExit(1)
if os.path.basename(path) != "hostwright-containerization-helper":
    raise SystemExit(1)
if os.path.realpath(path) != path:
    raise SystemExit(1)
try:
    metadata = os.lstat(path)
except OSError:
    raise SystemExit(1)
unsafe = stat.S_IWGRP | stat.S_IWOTH | stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX
if not stat.S_ISREG(metadata.st_mode):
    raise SystemExit(1)
if metadata.st_nlink != 1 or metadata.st_uid not in {0, os.geteuid()}:
    raise SystemExit(1)
if metadata.st_mode & unsafe or not metadata.st_mode & stat.S_IXUSR:
    raise SystemExit(1)
if not os.access(path, os.X_OK):
    raise SystemExit(1)
print(path)
PY
)" || blocked "the prior helper path is not a private normalized nonsymlink executable."
fi

OUTPUT="$($PYTHON_BIN - "$OUTPUT" <<'PY'
import os
import sys

path = sys.argv[1]
if not os.path.isabs(path):
    raise SystemExit("output must be an absolute path")
path = os.path.normpath(path)
if not path.endswith(".json"):
    raise SystemExit("output must use a .json suffix")
parent = os.path.dirname(path)
if not os.path.isdir(parent) or os.path.islink(parent):
    raise SystemExit("output parent must be an existing non-symlink directory")
if os.path.realpath(parent) != parent:
    raise SystemExit("output parent must be normalized and contain no symlink")
if os.path.lexists(path):
    raise SystemExit("output already exists")
print(path)
PY
)" || usage_error "--output must be a new normalized absolute .json path in a non-symlink directory."

RUNNER_VERSION="$($CONFORMANCE_BIN --version 2>/dev/null)" \
  || blocked "hostwright-runtime-conformance --version failed."
[[ ${#RUNNER_VERSION} -le 512 && "$RUNNER_VERSION" == 'hostwright-runtime-conformance '* ]] \
  || blocked "hostwright-runtime-conformance emitted an invalid version record."
case "$RUNNER_VERSION" in
  *$'\n'*|*$'\r'*|*$'\t'*) blocked "hostwright-runtime-conformance version must be one line." ;;
esac

CONTAINER_BIN=""
CONTAINER_VERSION_OUTPUT=""
ASSET_VERIFICATION_OUTPUT=""

preflight_apple_cli() {
  local expected="$1"
  CONTAINER_BIN="$(command -v container || true)"
  [[ -n "$CONTAINER_BIN" && -x "$CONTAINER_BIN" ]] || blocked "Apple container CLI is unavailable."
  CONTAINER_VERSION_OUTPUT="$($CONTAINER_BIN --version 2>/dev/null)" \
    || blocked "Apple container CLI version probing failed."
  [[ ${#CONTAINER_VERSION_OUTPUT} -le 4096 ]] || blocked "Apple container CLI version output is oversized."
  "$PYTHON_BIN" - "$CONTAINER_VERSION_OUTPUT" "$expected" <<'PY' \
    || blocked "Apple container CLI does not match the selected lane version $expected."
import re
import sys

text, expected = sys.argv[1:]
versions = re.findall(r"(?<![0-9.])[0-9]+\.[0-9]+\.[0-9]+(?![0-9.])", text)
if expected not in versions:
    raise SystemExit(1)
PY

  local image_list
  image_list="$(mktemp "$WORK_ROOT/apple-images.XXXXXXXX.json")"
  "$CONTAINER_BIN" image list --format json >"$image_list" 2>"$WORK_ROOT/apple-image-list.stderr" \
    || blocked "Apple container CLI could not enumerate local images."
  [[ "$(stat -f '%z' "$image_list")" -le "$MAX_REPORT_BYTES" ]] \
    || blocked "Apple container local-image inventory is oversized."
  "$PYTHON_BIN" - "$image_list" "$LOCAL_IMAGE" <<'PY' \
    || blocked "required workload image '$LOCAL_IMAGE' is not present locally; the harness will not pull it."
import json
import sys

document = json.load(open(sys.argv[1], encoding="utf-8"))
wanted = sys.argv[2]

def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)

if wanted not in set(strings(document)):
    raise SystemExit(1)
PY
}

preflight_containerization() {
  local asset_root="${HOSTWRIGHT_CONTAINERIZATION_ASSET_ROOT:-}"
  [[ -n "$asset_root" ]] || blocked "HOSTWRIGHT_CONTAINERIZATION_ASSET_ROOT is required."
  local verifier="$SCRIPT_ROOT/scripts/release/prepare-containerization-assets.sh"
  [[ -x "$verifier" ]] || blocked "the locked Containerization asset verifier is unavailable."
  ASSET_VERIFICATION_OUTPUT="$($verifier --verify "$asset_root" 2>/dev/null)" \
    || blocked "Containerization 0.35.0 assets are missing or invalid."
  [[ ${#ASSET_VERIFICATION_OUTPUT} -le 4096 ]] \
    || blocked "Containerization asset verification output is oversized."
}

TMP_PARENT="$($PYTHON_BIN - <<'PY'
import os
print(os.path.realpath(os.environ.get("TMPDIR", "/tmp")))
PY
)"
[[ -d "$TMP_PARENT" && ! -L "$TMP_PARENT" ]] || blocked "temporary parent is unavailable or unsafe."
WORK_ROOT="$(mktemp -d "$TMP_PARENT/hostwright-phase03.XXXXXXXX")"
chmod 700 "$WORK_ROOT"
WORK_MARKER="$WORK_ROOT/.hostwright-phase03-owned"
MARKER_VALUE="$$-$RANDOM-$RANDOM"
printf '%s\n' "$MARKER_VALUE" >"$WORK_MARKER"
chmod 600 "$WORK_MARKER"
FINAL_TEMP=""
WORK_CLEANED=0
FINAL_PUBLISHED=0

cleanup_work_root() {
  [[ "$WORK_CLEANED" -eq 0 ]] || return 0
  local name owner marker
  name="$(basename "$WORK_ROOT")"
  [[ "$name" =~ ^hostwright-phase03\.[A-Za-z0-9]+$ ]] \
    || failed "refusing cleanup of an unrecognized qualification root."
  [[ "$(dirname "$WORK_ROOT")" == "$TMP_PARENT" && -d "$WORK_ROOT" && ! -L "$WORK_ROOT" ]] \
    || failed "refusing cleanup outside the validated temporary parent."
  owner="$(stat -f '%u' "$WORK_ROOT")"
  [[ "$owner" == "$(id -u)" ]] || failed "refusing cleanup of a root owned by another user."
  [[ -f "$WORK_MARKER" && ! -L "$WORK_MARKER" ]] \
    || failed "qualification cleanup ownership marker is missing."
  marker="$(cat "$WORK_MARKER")"
  [[ "$marker" == "$MARKER_VALUE" ]] || failed "qualification cleanup ownership marker differs."
  /usr/bin/find -P "$WORK_ROOT" -depth -delete
  [[ ! -e "$WORK_ROOT" && ! -L "$WORK_ROOT" ]] \
    || failed "qualification temporary root cleanup was incomplete."
  WORK_CLEANED=1
}

cleanup_on_exit() {
  local status=$?
  if [[ "$WORK_CLEANED" -eq 0 && -n "${WORK_ROOT:-}" && -d "${WORK_ROOT:-}" ]]; then
    cleanup_work_root || status=$EXIT_FAILED
  fi
  if [[ "$FINAL_PUBLISHED" -eq 0 && -n "${FINAL_TEMP:-}" && -f "${FINAL_TEMP:-}" && ! -L "${FINAL_TEMP:-}" ]]; then
    /bin/rm -f "$FINAL_TEMP"
  fi
  exit "$status"
}
trap cleanup_on_exit EXIT

FINAL_TEMP="$(mktemp "$(dirname "$OUTPUT")/.hostwright-phase03-evidence.XXXXXXXX")"
chmod 600 "$FINAL_TEMP"

case "$OPERATION" in
  conformance|recovery)
    PROVIDER="$(lane_provider "$LANE")"
    EXPECTED_VERSION="$(lane_version "$LANE")"
    if [[ "$PROVIDER" == apple-container-cli ]]; then
      preflight_apple_cli "$EXPECTED_VERSION"
    else
      preflight_containerization
    fi
    ;;
  migration)
    SOURCE_VERSION="$(lane_version "$SOURCE_LANE")"
    TARGET_VERSION="$(lane_version "$TARGET_LANE")"
    if [[ "$SOURCE_PROVIDER" == apple-container-cli ]]; then
      preflight_apple_cli "$SOURCE_VERSION"
      preflight_containerization
    else
      preflight_containerization
      preflight_apple_cli "$TARGET_VERSION"
    fi
    ;;
esac

RUNNER_OUTPUT="$WORK_ROOT/runner-evidence.json"
RUNNER_STDOUT="$WORK_ROOT/runner.stdout"
RUNNER_STDERR="$WORK_ROOT/runner.stderr"
case "$OPERATION" in
  conformance)
    RUNNER_ARGUMENTS=(
      conformance
      --provider "$PROVIDER"
      --expected-version "$EXPECTED_VERSION"
      --local-image "$LOCAL_IMAGE"
      --output "$RUNNER_OUTPUT"
    )
    ;;
  migration)
    RUNNER_ARGUMENTS=(
      migration
      --source-provider "$SOURCE_PROVIDER"
      --target-provider "$TARGET_PROVIDER"
      --expected-source-version "$SOURCE_VERSION"
      --expected-target-version "$TARGET_VERSION"
      --local-image "$LOCAL_IMAGE"
      --output "$RUNNER_OUTPUT"
    )
    ;;
  recovery)
    RUNNER_ARGUMENTS=(
      recovery
      --provider "$PROVIDER"
      --expected-version "$EXPECTED_VERSION"
      --scenario "$SCENARIO"
      --local-image "$LOCAL_IMAGE"
      --output "$RUNNER_OUTPUT"
    )
    if [[ "$SCENARIO" == stale-helper ]]; then
      RUNNER_ARGUMENTS+=(--prior-helper "$PRIOR_HELPER_BIN")
    fi
    ;;
esac

set +e
"$CONFORMANCE_BIN" "${RUNNER_ARGUMENTS[@]}" >"$RUNNER_STDOUT" 2>"$RUNNER_STDERR"
RUNNER_STATUS=$?
set -e
[[ "$RUNNER_STATUS" -eq 0 ]] \
  || failed "hostwright-runtime-conformance exited with status $RUNNER_STATUS; no evidence was published."
[[ -f "$RUNNER_OUTPUT" && ! -L "$RUNNER_OUTPUT" ]] \
  || failed "hostwright-runtime-conformance did not create a regular evidence report."
[[ "$(stat -f '%l' "$RUNNER_OUTPUT")" -eq 1 ]] \
  || failed "hostwright-runtime-conformance evidence report has an unsafe link count."
[[ "$(stat -f '%z' "$RUNNER_OUTPUT")" -le "$MAX_REPORT_BYTES" ]] \
  || failed "hostwright-runtime-conformance evidence report exceeds 8 MiB."
[[ "$(stat -f '%z' "$RUNNER_STDOUT")" -le "$MAX_STREAM_BYTES" \
    && "$(stat -f '%z' "$RUNNER_STDERR")" -le "$MAX_STREAM_BYTES" ]] \
  || failed "hostwright-runtime-conformance diagnostic output exceeds 1 MiB."

OS_VERSION="$(sw_vers -productVersion)"
OS_BUILD="$(sw_vers -buildVersion)"
ARCHITECTURE="$(uname -m)"
HARDWARE_MODEL="$(/usr/sbin/sysctl -n hw.model)"
CPU_COUNT="$(/usr/sbin/sysctl -n hw.logicalcpu)"
MEMORY_BYTES="$(/usr/sbin/sysctl -n hw.memsize)"

"$PYTHON_BIN" - \
  "$RUNNER_OUTPUT" "$FINAL_TEMP" "$OPERATION" "$LANE" "$SOURCE_LANE" "$TARGET_LANE" \
  "$SCENARIO" "$LOCAL_IMAGE" "$RUNNER_VERSION" "$RUNNER_STATUS" "$OS_VERSION" "$OS_BUILD" \
  "$ARCHITECTURE" "$HARDWARE_MODEL" "$CPU_COUNT" "$MEMORY_BYTES" "$CONTAINER_VERSION_OUTPUT" \
  "$ASSET_VERIFICATION_OUTPUT" "${RUNNER_ARGUMENTS[@]}" <<'PY' \
  || failed "hostwright-runtime-conformance evidence validation failed; no evidence was published."
import json
import math
import os
import re
import sys

(
    runner_path,
    final_path,
    operation,
    lane,
    source_lane,
    target_lane,
    scenario,
    local_image,
    runner_version,
    runner_status,
    os_version,
    os_build,
    architecture,
    hardware_model,
    cpu_count,
    memory_bytes,
    container_version,
    asset_verification,
    *runner_arguments,
) = sys.argv[1:]

with open(runner_path, "rb") as handle:
    raw = handle.read(8 * 1024 * 1024 + 1)
if len(raw) > 8 * 1024 * 1024:
    raise SystemExit("runner evidence exceeds 8 MiB")
def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result

try:
    report = json.loads(
        raw,
        object_pairs_hook=strict_object,
        parse_constant=lambda value: (_ for _ in ()).throw(ValueError(f"invalid number: {value}")),
    )
except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
    raise SystemExit(f"runner evidence is not one complete UTF-8 JSON document: {error}")

hex64 = re.compile(r"^[0-9a-f]{64}$")
digest = re.compile(r"^sha256:[0-9a-f]{64}$")
provider_for_lane = {
    "apple-cli-1.0.0": ("apple-container-cli", "1.0.0"),
    "apple-cli-1.1.0": ("apple-container-cli", "1.1.0"),
    "containerization-0.35.0": ("apple-containerization", "0.35.0"),
}
kind_for_operation = {
    "conformance": "runtimeProviderConformanceEvidence",
    "migration": "runtimeProviderMigrationEvidence",
    "recovery": "runtimeProviderRecoveryEvidence",
}

def require(condition, message):
    if not condition:
        raise SystemExit(message)

require(type(report) is dict, "runner evidence must be an object")
expected_top = {
    "schemaVersion", "kind", "status", "subjects", "fixtureImage", "inventory",
    "unmanagedInventoryUnchanged", "summary", "commands", "cleanup", "details",
}
if operation == "recovery":
    expected_top.add("scenario")
require(set(report) == expected_top, "runner evidence contains missing or unexpected top-level fields")
require(report["schemaVersion"] == 1, "runner evidence schema version differs")
require(report["kind"] == kind_for_operation[operation], "runner evidence kind differs")
require(report["status"] == "passed", "runner evidence did not pass")

expected_lanes = [lane] if operation != "migration" else [source_lane, target_lane]
expected_subjects = [
    {"providerID": provider_for_lane[item][0], "providerVersion": provider_for_lane[item][1]}
    for item in expected_lanes
]
require(report["subjects"] == expected_subjects, "runner evidence subjects differ from requested lanes")

fixture = report["fixtureImage"]
require(type(fixture) is dict and set(fixture) == {"reference", "digest"}, "fixture image record differs")
require(fixture["reference"] == local_image, "runner evidence local-image reference differs")
require(type(fixture["digest"]) is str and digest.fullmatch(fixture["digest"]), "fixture image digest is invalid")

inventory = report["inventory"]
inventory_keys = {"beforeSHA256", "afterSHA256", "unmanagedBeforeSHA256", "unmanagedAfterSHA256"}
require(type(inventory) is dict and set(inventory) == inventory_keys, "inventory evidence fields differ")
for key in inventory_keys:
    require(type(inventory[key]) is str and hex64.fullmatch(inventory[key]), f"invalid inventory hash: {key}")
require(report["unmanagedInventoryUnchanged"] is True, "unmanaged inventory was not preserved")
require(
    inventory["unmanagedBeforeSHA256"] == inventory["unmanagedAfterSHA256"],
    "unmanaged inventory hashes differ",
)

summary = report["summary"]
require(type(summary) is dict and set(summary) == {"passed", "failed"}, "summary fields differ")
require(type(summary["passed"]) is int and 0 < summary["passed"] <= 10000, "pass count is invalid")
require(summary["failed"] == 0, "runner evidence records failures")

sensitive = re.compile(
    r"(?i)(password|secret|credential|authorization|cookie|private.?key|api.?key|bearer|access.?token|refresh.?token|session.?token|confirmation.?token)"
)
details = report["details"]
require(type(details) is dict and details, "operation-specific details must be a nonempty object")
detail_nodes = 0

def validate_details(value, depth=0):
    global detail_nodes
    detail_nodes += 1
    require(detail_nodes <= 100_000 and depth <= 32, "operation-specific details exceed structural limits")
    if isinstance(value, dict):
        require(len(value) <= 10_000, "operation-specific details object is oversized")
        for key, item in value.items():
            require(type(key) is str and 0 < len(key.encode("utf-8")) <= 256, "operation-specific detail key is invalid")
            require(not sensitive.search(key), "operation-specific details contain a sensitive key")
            validate_details(item, depth + 1)
    elif isinstance(value, list):
        require(len(value) <= 10_000, "operation-specific details array is oversized")
        for item in value:
            validate_details(item, depth + 1)
    elif isinstance(value, str):
        require(len(value.encode("utf-8")) <= 64 * 1024, "operation-specific detail string is oversized")
    elif isinstance(value, float):
        require(math.isfinite(value), "operation-specific detail number is invalid")
    else:
        require(value is None or type(value) in {bool, int}, "operation-specific detail value is invalid")

validate_details(details)

commands = report["commands"]
require(type(commands) is list and 0 < len(commands) <= 256, "command evidence count is invalid")
for command in commands:
    require(type(command) is dict and set(command) == {"arguments", "exitStatus"}, "command evidence fields differ")
    arguments = command["arguments"]
    require(type(arguments) is list and 0 < len(arguments) <= 128, "command argument count is invalid")
    require(
        type(command["exitStatus"]) is int and -1 <= command["exitStatus"] <= 255,
        "command evidence status is invalid",
    )
    for index, argument in enumerate(arguments):
        require(type(argument) is str and 0 < len(argument.encode("utf-8")) <= 4096, "command argument is invalid")
        require(not any(ord(character) < 32 for character in argument), "command argument contains controls")
        require(not sensitive.search(argument), "command argument contains sensitive material")
        if index == 0:
            require(os.path.basename(argument) == argument, "command evidence must record executable basenames")

cleanup = report["cleanup"]
require(type(cleanup) is dict and set(cleanup) == {"complete", "identifiers"}, "cleanup fields differ")
require(cleanup["complete"] is True, "runner cleanup is incomplete")
require(type(cleanup["identifiers"]) is list and len(cleanup["identifiers"]) <= 1024, "cleanup identifiers differ")
for identifier in cleanup["identifiers"]:
    require(type(identifier) is str and 0 < len(identifier.encode("utf-8")) <= 512, "cleanup identifier is invalid")
    require(not any(ord(character) < 32 for character in identifier), "cleanup identifier contains controls")

if operation == "recovery":
    require(report["scenario"] == scenario, "runner recovery scenario differs")
    if scenario == "stale-helper":
        require(set(details) == {"recovery"}, "stale-helper details envelope differs")
        recovery = details["recovery"]
        require(type(recovery) is dict, "stale-helper recovery evidence must be an object")
        require(recovery.get("schemaVersion") == 1, "stale-helper recovery schema differs")
        require(recovery.get("scenario") == scenario, "stale-helper recovery scenario differs")
        expected_provider, expected_version = provider_for_lane[lane]
        require(recovery.get("providerID") == expected_provider, "stale-helper provider differs")
        require(recovery.get("providerVersion") == expected_version, "stale-helper provider version differs")
        require(recovery.get("fixtureImageReference") == local_image, "stale-helper image differs")
        require(
            recovery.get("fixtureImageDescriptorDigest") == fixture["digest"],
            "stale-helper image digest differs",
        )
        prior_helper = recovery.get("priorHelperSHA256")
        current_helper = recovery.get("currentHelperSHA256")
        require(type(prior_helper) is str and hex64.fullmatch(prior_helper), "stale-helper H1 digest is invalid")
        require(type(current_helper) is str and hex64.fullmatch(current_helper), "stale-helper H2 digest is invalid")
        require(prior_helper != current_helper, "stale-helper helper digests must differ")
        require(recovery.get("signedHelperTransitionVerified") is True, "stale-helper signed transition was not verified")
        require(
            recovery.get("contractInput") == "signed-h1-to-h2-helper-transition",
            "stale-helper transition contract differs",
        )
        require(recovery.get("providerGeneration") == 1, "stale-helper provider generation differs")
        require(recovery.get("providerMetadataRevisionBefore") == 1, "stale-helper H1 metadata revision differs")
        require(recovery.get("providerMetadataRevisionAfter") == 2, "stale-helper H2 metadata revision differs")
        require(
            recovery.get("recoveryDisposition") == "reobserve-then-resume-from-checkpoint",
            "stale-helper H2 recovery disposition differs",
        )
        require(recovery.get("recoveryFindingReasons") == [], "stale-helper H2 recovery findings differ")
        change_kinds = recovery.get("recoveryChangeKinds")
        require(type(change_kinds) is list, "stale-helper recovery changes differ")
        require(
            {"capability-digest", "component-fingerprint"}.issubset(set(change_kinds)),
            "stale-helper helper fingerprint change is missing",
        )
        require(recovery.get("capabilitySnapshotInvalidated") is True, "stale-helper capability was not invalidated")
        capability_before = recovery.get("capabilityBeforeSHA256")
        capability_after = recovery.get("capabilityAfterSHA256")
        require(
            type(capability_before) is str and hex64.fullmatch(capability_before),
            "stale-helper H1 capability digest is invalid",
        )
        require(
            type(capability_after) is str and hex64.fullmatch(capability_after),
            "stale-helper H2 capability digest is invalid",
        )
        require(
            capability_before != capability_after,
            "stale-helper capability snapshots did not change",
        )
        require(
            recovery.get("inventoryBeforeSHA256") == inventory["beforeSHA256"]
            and recovery.get("inventoryAfterSHA256") == inventory["afterSHA256"]
            and recovery.get("unmanagedInventoryBeforeSHA256") == inventory["unmanagedBeforeSHA256"]
            and recovery.get("unmanagedInventoryAfterSHA256") == inventory["unmanagedAfterSHA256"],
            "stale-helper nested inventory evidence differs",
        )
        require(recovery.get("unmanagedInventoryUnchanged") is True, "stale-helper unmanaged inventory changed")
        require(
            recovery.get("rollbackDisposition") == "refuse-and-preserve-checkpoint",
            "stale-helper rollback was not refused",
        )
        require(
            recovery.get("rollbackFindingReasons") == ["metadata-revision-too-new"],
            "stale-helper rollback refusal reason differs",
        )
        require(recovery.get("failedAssertions") == 0, "stale-helper evidence records failures")
        require(recovery.get("passedAssertions") == summary["passed"], "stale-helper pass count differs")
        require(recovery.get("cleanupComplete") is True, "stale-helper cleanup is incomplete")
        require(recovery.get("cleanupIdentifiers") == cleanup["identifiers"], "stale-helper cleanup identifiers differ")
        require(
            recovery.get("durableCheckpointBefore") is None
            and recovery.get("durableCheckpointAfter") is None
            and recovery.get("terminatedExecutable") is None
            and recovery.get("processTreeTerminated") is False
            and recovery.get("stateSchemaVersion") is None,
            "stale-helper unexpectedly used a synthetic process checkpoint",
        )
        required_transition_commands = [
            ["hostwright-containerization-helper", "negotiate", "h1"],
            ["hostwright-containerization-helper", "shutdown", "h1"],
            ["hostwright-containerization-helper", "negotiate", "h2"],
            ["hostwright-containerization-helper", "shutdown", "h2"],
        ]
        command_arguments = [command["arguments"] for command in commands if command["exitStatus"] == 0]
        require(
            all(arguments in command_arguments for arguments in required_transition_commands),
            "stale-helper helper process-cycle evidence is incomplete",
        )

runner_command = ["hostwright-runtime-conformance", *runner_arguments]
for index, argument in enumerate(runner_command):
    if argument == runner_path:
        runner_command[index] = "<runner-output>"

environment = {
    "architecture": architecture,
    "cpuCount": int(cpu_count),
    "hardwareModel": hardware_model,
    "memoryBytes": int(memory_bytes),
    "macOSBuild": os_build,
    "macOSVersion": os_version,
}
provider_tools = {}
if container_version:
    provider_tools["appleContainerVersion"] = container_version
if asset_verification:
    provider_tools["containerizationAssets"] = asset_verification

envelope = {
    "environment": environment,
    "kind": "phase03QualificationEvidence",
    "operation": operation,
    "providerTools": provider_tools,
    "runner": {"name": "hostwright-runtime-conformance", "version": runner_version},
    "runnerEvidence": report,
    "runnerInvocation": {"arguments": runner_command, "exitStatus": int(runner_status)},
    "schemaVersion": 1,
}
encoded = json.dumps(envelope, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"
require(len(encoded) <= 8 * 1024 * 1024, "final evidence exceeds 8 MiB")
with open(final_path, "wb") as handle:
    handle.write(encoded)
    handle.flush()
    os.fsync(handle.fileno())
PY

cleanup_work_root

"$PYTHON_BIN" - "$FINAL_TEMP" "$OUTPUT" <<'PY'
import os
import sys

source, destination = sys.argv[1:]
os.link(source, destination)
os.unlink(source)
parent = os.open(os.path.dirname(destination), os.O_RDONLY)
try:
    os.fsync(parent)
finally:
    os.close(parent)
PY
FINAL_PUBLISHED=1
trap - EXIT
printf 'Phase 03 %s evidence passed: %s\n' "$OPERATION" "$OUTPUT"
