#!/usr/bin/env bash
set -euo pipefail

readonly duration_seconds=259200
readonly sample_interval_seconds=300
readonly expected_samples=864
readonly compaction_attempt_limit=5
readonly power_evidence_version=1
readonly qualification_schema_version=2
readonly checkpoint_schema_version=1
readonly genesis_checkpoint_sha256='0000000000000000000000000000000000000000000000000000000000000000'
readonly uuid_pattern='^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$'
readonly resource_uuid_pattern='^[a-f0-9]{8}-[a-f0-9]{4}-8[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$'
readonly resource_identifier_pattern='^[a-z0-9][a-z0-9-]{0,127}$'
readonly subsystem='dev.hostwright'
readonly checkpoint_header='sequence\tqualificationID\tsegmentID\tsegmentSample\tepoch\tqualifiedSeconds\tdaemonPID\trssKB\tfileDescriptors\tdatabaseBytes\toperations\tactiveGroups\tevents\ttraces\tretries\toslog10m\truntimeInventorySHA256\tconfigSHA256\tintegritySHA256\tresourceIdentifier\tresourceUUID\tprojectName\thostwrightSHA256\tdaemonSHA256\ttemplateSHA256\thostIdentitySHA256\tsourceCommit\tpredecessorCheckpointSHA256\tcheckpointSHA256'

daemon_pid=''
daemon_generation=0
resource_identifier=''
resource_uuid=''
project_name=''
state_file=''
evidence_file=''
sample_file=''
checkpoint_root=''
segment_file=''
active_run_root=''
qualification_id=''
segment_id=''
segment_sample=0
cumulative_samples=0
cumulative_seconds=0
previous_checkpoint_sha256=''
last_sample_epoch=0
source_sha=''
hostwright_sha=''
daemon_sha=''
template_sha=''
host_identity_sha=''
last_config_sha256=''

die() {
  local message="$1"
  if [[ -n "$evidence_file" && -f "$evidence_file" ]]; then
    printf '%s\tfailure\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$message" >> "$evidence_file"
    chmod 600 "$evidence_file"
  fi
  printf '%s\n' "$message" >&2
  exit "${2:-70}"
}

contract() {
  printf '%s\n' 'Phase 08 aggregate soak qualification contract v2 is valid.'
  printf '%s\n' 'The cumulative qualifying duration is exactly 259200 seconds with 864 durable 300-second samples.'
  printf '%s\n' 'A failed, interrupted, sleeping, or powered-off segment resumes from its last validated checkpoint instead of sequence zero.'
  printf '%s\n' 'Every checkpoint is predecessor-hashed and bound to exact source, binary, configuration, physical host, project, resource, and runtime-inventory identity.'
  printf '%s\n' 'Gaps and partial samples never count; completed cumulative samples and fault-cell receipts are never repeated after validation.'
  printf '%s\n' 'One foreground daemon, one exact digest-bound workload, and one private schema-v17 database are used.'
  printf '%s\n' 'The global Apple-container inventory must contain no other Hostwright-managed runtime before or throughout the run.'
  printf '%s\n' 'The clean source, executables, template, and private evidence root must remain on writable internal non-removable storage.'
  printf '%s\n' 'Configuration churn, bounded pressure, daemon/workload/helper/runtime faults, and all local observability sinks are exercised serially.'
  printf '%s\n' 'A timestamp-bound real sleep then wake must occur inside a qualified segment; the runner never forces either transition.'
  printf '%s\n' 'Failure preserves evidence and exact resource identity; success performs confirmation-bound owned-only cleanup.'
  printf '%s\n' 'No CI, GitHub, network listener, upload, reboot, logout, release, tag, tap, or website action is performed.'
}

sha256() {
  /usr/bin/shasum -a 256 "$1" | awk '{ print $1 }'
}

sha256_text() {
  /usr/bin/shasum -a 256 | awk '{ print $1 }'
}

durable_sync() {
  local path="$1"
  /usr/bin/python3 - "$path" <<'PY'
import os
import sys

path = sys.argv[1]
descriptor = os.open(path, os.O_RDONLY)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
parent = os.open(os.path.dirname(path), os.O_RDONLY)
try:
    os.fsync(parent)
finally:
    os.close(parent)
PY
}

latest_state_value() {
  local key="$1"
  awk -F '\t' -v key="$key" '$1 == key { value = $2 } END { print value }' "$state_file"
}

append_state() {
  local key="$1"
  local value="$2"
  [[ "$key" =~ ^[A-Za-z][A-Za-z0-9]*$ && "$value" != *$'\t'* && "$value" != *$'\n'* ]] \
    || die 'A qualification state checkpoint was malformed.' 75
  printf '%s\t%s\n' "$key" "$value" >> "$state_file"
  chmod 600 "$state_file"
  durable_sync "$state_file" \
    || die 'A qualification state checkpoint could not be durably synchronized.' 74
}

new_uuid() {
  /usr/bin/uuidgen | tr '[:upper:]' '[:lower:]'
}

boot_identity() {
  /usr/sbin/sysctl -n kern.boottime | sha256_text
}

current_host_identity() {
  local platform_uuid hardware_model architecture os_build
  platform_uuid="$(/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice \
    | awk -F '"' '/IOPlatformUUID/ { print $(NF - 1); exit }')"
  hardware_model="$(/usr/sbin/sysctl -n hw.model)"
  architecture="$(/usr/bin/uname -m)"
  os_build="$(/usr/bin/sw_vers -buildVersion)"
  [[ "$platform_uuid" =~ ^[A-F0-9-]{36}$ \
      && "$hardware_model" =~ ^[A-Za-z0-9,]+$ \
      && "$architecture" =~ ^[A-Za-z0-9_]+$ \
      && "$os_build" =~ ^[A-Za-z0-9]+$ ]] \
    || die 'The physical host identity could not be derived safely.' 69
  printf '%s\n%s\n%s\n%s' \
    "$platform_uuid" "$hardware_model" "$architecture" "$os_build" | sha256_text
}

private_file_is_valid() {
  local path="$1"
  [[ -f "$path" && ! -L "$path" \
      && "$(stat -f '%u' "$path")" == "$(id -u)" \
      && "$(stat -f '%Lp' "$path")" == 600 ]]
}

private_directory_is_valid() {
  local path="$1"
  [[ -d "$path" && ! -L "$path" \
      && "$(stat -f '%u' "$path")" == "$(id -u)" \
      && "$(stat -f '%Lp' "$path")" == 700 ]]
}

source_digest() {
  {
    git rev-parse HEAD
    git diff --binary HEAD -- . ':(exclude)tmp'
    while IFS= read -r path; do
      [[ "$path" == tmp || "$path" == tmp/* ]] && continue
      /usr/bin/shasum -a 256 "$path"
    done < <(git ls-files --others --exclude-standard | LC_ALL=C sort)
  } | /usr/bin/shasum -a 256 | awk '{ print $1 }'
}

require_canonical_file() {
  local variable="$1"
  local path="${!variable:-}"
  [[ "$path" == /* && "$path" != *$'\n'* && -f "$path" && ! -L "$path" \
      && "$(/bin/realpath "$path")" == "$path" ]] \
    || die "$variable must name one canonical absolute regular non-symlink file." 66
}

storage_properties() {
  local path="$1"
  local device
  device="$(/bin/df -P "$path" | awk 'NR == 2 { print $1 }')"
  [[ "$device" == /dev/* ]] || return 1
  /usr/sbin/diskutil info -plist "$device"
}

require_internal_persistent_path() {
  local path="$1"
  local label="$2"
  local properties internal external writable mount_point
  properties="$(storage_properties "$path")" \
    || die "$label storage identity could not be resolved." 69
  internal="$(printf '%s' "$properties" | /usr/bin/plutil -extract Internal raw -o - - 2>/dev/null)" \
    || die "$label storage did not declare internal identity." 77
  external="$(printf '%s' "$properties" | /usr/bin/plutil -extract RemovableMediaOrExternalDevice raw -o - - 2>/dev/null)" \
    || die "$label storage did not declare removable-media identity." 77
  writable="$(printf '%s' "$properties" | /usr/bin/plutil -extract WritableVolume raw -o - - 2>/dev/null)" \
    || die "$label storage did not declare writable-volume identity." 77
  mount_point="$(printf '%s' "$properties" | /usr/bin/plutil -extract MountPoint raw -o - - 2>/dev/null)" \
    || die "$label storage did not declare a mount point." 77
  [[ "$internal" == true && "$external" == false && "$writable" == true \
      && "$mount_point" == /* ]] \
    || die "$label must remain on writable internal non-removable storage." 77
}

managed_runtime_count() {
  /usr/bin/jq -er '[.[] | select((.configuration.labels["dev.hostwright.managed"] // "") == "true")] | length'
}

require_empty_managed_runtime_inventory() {
  local inventory count
  inventory="$(container list --all --format json)" \
    || die 'The global Apple-container inventory could not be read.' 69
  count="$(printf '%s' "$inventory" | managed_runtime_count)" \
    || die 'The global Apple-container inventory was not valid bounded JSON.' 69
  [[ "$count" == 0 ]] \
    || die 'Another Hostwright-managed Apple-container runtime blocks this exclusive soak qualification.' 75
}

verify_exclusive_runtime_inventory() {
  local output_path="${1:-}"
  local inventory current_uuid
  inventory="$(container list --all --format json)" \
    || die 'The global Apple-container inventory could not be read.' 69
  if [[ -n "$output_path" ]]; then
    [[ ! -e "$output_path" ]] \
      || die 'A per-sample runtime inventory artifact already exists.' 75
    printf '%s\n' "$inventory" > "$output_path"
    chmod 600 "$output_path"
  fi
  printf '%s' "$inventory" | /usr/bin/jq -e \
    --arg id "$resource_identifier" \
    --arg project "$project_name" \
    --arg image "$HOSTWRIGHT_PHASE08_SOAK_IMAGE" '
      [.[] | select((.configuration.labels["dev.hostwright.managed"] // "") == "true")] as $managed
      | ($managed | length) == 1
        and $managed[0].id == $id
        and $managed[0].configuration.id == $id
        and $managed[0].configuration.image.reference == $image
        and $managed[0].configuration.labels["dev.hostwright.resource-id"] == $id
        and $managed[0].configuration.labels["dev.hostwright.project"] == $project
        and $managed[0].configuration.labels["dev.hostwright.provider-id"] == "apple-container-cli"
        and $managed[0].configuration.labels["dev.hostwright.identity-version"] == "2"
        and $managed[0].status.state == "running"
    ' >/dev/null \
    || die 'The global Apple-container inventory contains a foreign, ambiguous, or changed Hostwright-managed runtime.' 75
  current_uuid="$(printf '%s' "$inventory" | /usr/bin/jq -er \
    --arg id "$resource_identifier" \
    '.[] | select(.id == $id) | .configuration.labels["dev.hostwright.resource-uuid"]')" \
    || die 'The exact soak resource UUID is absent from the global runtime inventory.' 75
  [[ "$current_uuid" =~ $resource_uuid_pattern ]] \
    || die 'The exact soak resource UUID is malformed.' 75
  if [[ -n "$resource_uuid" && "$resource_uuid" != "$current_uuid" ]]; then
    die 'The soak runtime UUID changed.' 75
  fi
  resource_uuid="$current_uuid"
}

verify_resume_runtime_inventory() {
  local inventory count current_uuid
  inventory="$(container list --all --format json)" \
    || die 'The global Apple-container inventory could not be read.' 69
  count="$(printf '%s' "$inventory" | managed_runtime_count)" \
    || die 'The global Apple-container inventory was not valid bounded JSON.' 69
  if [[ "$count" == 0 ]]; then
    ! /usr/sbin/lsof -nP -iTCP:"$HOSTWRIGHT_PHASE08_SOAK_HOST_PORT" -sTCP:LISTEN >/dev/null 2>&1 \
      || die 'The selected soak host port is occupied while the checkpointed runtime is absent.' 75
    return
  fi
  printf '%s' "$inventory" | /usr/bin/jq -e \
    --arg id "$resource_identifier" \
    --arg uuid "$resource_uuid" \
    --arg project "$project_name" \
    --arg image "$HOSTWRIGHT_PHASE08_SOAK_IMAGE" '
      [.[] | select((.configuration.labels["dev.hostwright.managed"] // "") == "true")] as $managed
      | ($managed | length) == 1
        and $managed[0].id == $id
        and $managed[0].configuration.id == $id
        and $managed[0].configuration.image.reference == $image
        and $managed[0].configuration.labels["dev.hostwright.resource-id"] == $id
        and $managed[0].configuration.labels["dev.hostwright.resource-uuid"] == $uuid
        and $managed[0].configuration.labels["dev.hostwright.project"] == $project
        and $managed[0].configuration.labels["dev.hostwright.provider-id"] == "apple-container-cli"
        and $managed[0].configuration.labels["dev.hostwright.identity-version"] == "2"
    ' >/dev/null \
    || die 'Resume found a foreign, ambiguous, or changed Hostwright-managed runtime.' 75
  current_uuid="$(printf '%s' "$inventory" | /usr/bin/jq -er \
    --arg id "$resource_identifier" \
    '.[] | select(.id == $id) | .configuration.labels["dev.hostwright.resource-uuid"]')" \
    || die 'Resume could not recover the exact soak resource UUID.' 75
  [[ "$current_uuid" == "$resource_uuid" && "$current_uuid" =~ $resource_uuid_pattern ]] \
    || die 'Resume found changed or malformed soak resource identity.' 75
}

validate_root() {
  : "${HOSTWRIGHT_PHASE08_SOAK_ROOT:?HOSTWRIGHT_PHASE08_SOAK_ROOT is required}"
  local account_home qualification_parent root_parent root_name user_id
  account_home="$(/usr/bin/python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
  qualification_parent="${account_home}/Library/Application Support/Hostwright/qualification"
  root_parent="$(dirname "$HOSTWRIGHT_PHASE08_SOAK_ROOT")"
  root_name="$(basename "$HOSTWRIGHT_PHASE08_SOAK_ROOT")"
  user_id="$(id -u)"
  [[ -d "$qualification_parent" && ! -L "$qualification_parent" \
      && "$(/bin/realpath "$qualification_parent")" == "$qualification_parent" \
      && "$(stat -f '%u' "$qualification_parent")" == "$user_id" \
      && "$(stat -f '%Lp' "$qualification_parent")" == 700 \
      && "$root_parent" == "$qualification_parent" \
      && "$root_name" =~ ^phase08-gate16-soak-${uuid_pattern#^} \
      && -d "$HOSTWRIGHT_PHASE08_SOAK_ROOT" \
      && ! -L "$HOSTWRIGHT_PHASE08_SOAK_ROOT" \
      && "$(/bin/realpath "$HOSTWRIGHT_PHASE08_SOAK_ROOT")" == "$HOSTWRIGHT_PHASE08_SOAK_ROOT" \
      && "$(stat -f '%u' "$HOSTWRIGHT_PHASE08_SOAK_ROOT")" == "$user_id" \
      && "$(stat -f '%Lp' "$HOSTWRIGHT_PHASE08_SOAK_ROOT")" == 700 ]] \
    || die 'The soak root must be one private phase08-gate16-soak-<uuid> child of the persistent Hostwright qualification parent.' 77
  require_internal_persistent_path "$qualification_parent" 'The qualification parent'
  require_internal_persistent_path "$HOSTWRIGHT_PHASE08_SOAK_ROOT" 'The soak root'
}

validate_inputs() {
  local mode="${1:-new}"
  [[ "$mode" == new || "$mode" == resume ]] \
    || die 'The soak validation mode is invalid.' 64
  validate_root
  local source_root
  source_root="$(git rev-parse --show-toplevel)"
  [[ "$(pwd -P)" == "$source_root" ]] \
    || die 'The soak must run from the exact clean source root.' 70
  require_canonical_file HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT
  require_canonical_file HOSTWRIGHT_PHASE08_SOAK_DAEMON
  require_canonical_file HOSTWRIGHT_PHASE08_SOAK_CONFIG_TEMPLATE
  [[ -x "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" \
      && -x "$HOSTWRIGHT_PHASE08_SOAK_DAEMON" \
      && "${HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT##*/}" == hostwright \
      && "${HOSTWRIGHT_PHASE08_SOAK_DAEMON##*/}" == hostwrightd ]] \
    || die 'The soak executables must be exact executable hostwright and hostwrightd files.' 66
  : "${HOSTWRIGHT_PHASE08_SOAK_IMAGE:?HOSTWRIGHT_PHASE08_SOAK_IMAGE is required}"
  : "${HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT:?HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT is required}"
  : "${HOSTWRIGHT_PHASE08_SOAK_HOST_PORT:?HOSTWRIGHT_PHASE08_SOAK_HOST_PORT is required}"
  [[ "$HOSTWRIGHT_PHASE08_SOAK_IMAGE" =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ \
      && "$HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT" =~ ^[a-f0-9]{40}$ \
      && "$HOSTWRIGHT_PHASE08_SOAK_HOST_PORT" =~ ^[0-9]+$ \
      && "$HOSTWRIGHT_PHASE08_SOAK_HOST_PORT" -ge 20000 \
      && "$HOSTWRIGHT_PHASE08_SOAK_HOST_PORT" -le 49000 ]] \
    || die 'The soak image, source commit, or host port is invalid.' 66
  [[ "$(git rev-parse HEAD)" == "$HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT" \
      && -z "$(git status --porcelain --untracked-files=all -- . ':(exclude)tmp')" ]] \
    || die 'The soak requires the exact clean committed source head.' 70
  for tool in /bin/date /bin/df /bin/ps /bin/realpath /usr/bin/jq /usr/bin/plutil \
      /usr/bin/python3 \
      /usr/bin/sqlite3 /usr/bin/stat /usr/bin/uuidgen /usr/sbin/diskutil \
      /usr/sbin/ioreg /usr/sbin/lsof /usr/bin/log /usr/bin/pmset /usr/bin/shasum \
      /usr/sbin/sysctl /usr/bin/sw_vers /usr/bin/uname; do
    [[ -x "$tool" ]] || die "Required soak tool is unavailable: $tool" 69
  done
  require_internal_persistent_path "$source_root" 'The source root'
  require_internal_persistent_path "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" 'The hostwright executable'
  require_internal_persistent_path "$HOSTWRIGHT_PHASE08_SOAK_DAEMON" 'The daemon executable'
  require_internal_persistent_path "$HOSTWRIGHT_PHASE08_SOAK_CONFIG_TEMPLATE" 'The configuration template'
  [[ "$(container system status)" == *'status             running'* ]] \
    || die 'Apple container is not running.' 69
  if [[ "$mode" == new ]]; then
    require_empty_managed_runtime_inventory
  else
    verify_resume_runtime_inventory
  fi
  local image_digest="${HOSTWRIGHT_PHASE08_SOAK_IMAGE##*@}"
  container image list --format json \
    | /usr/bin/jq -e --arg digest "$image_digest" \
      '[.[] | .id, .configuration.descriptor.digest, (.variants[].digest)] | any(. == $digest)' >/dev/null \
    || die 'The exact digest-bound soak image is not already local; pulling is forbidden.' 69
  if [[ "$mode" == new ]]; then
    ! /usr/sbin/lsof -nP -iTCP:"$HOSTWRIGHT_PHASE08_SOAK_HOST_PORT" -sTCP:LISTEN >/dev/null 2>&1 \
      || die 'The selected soak host port is already listening.' 75
  fi
}

record() {
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$evidence_file"
  chmod 600 "$evidence_file"
  durable_sync "$evidence_file" \
    || die 'Qualification evidence could not be durably synchronized.' 74
}

find_sleep_wake_pair() {
  local start_epoch="$1"
  local end_epoch="$2"
  local line timestamp event_epoch sleep_epoch=''
  [[ "$start_epoch" =~ ^[0-9]+$ && "$end_epoch" =~ ^[0-9]+$ \
      && "$end_epoch" -gt "$start_epoch" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" == *$'\tEntering Sleep state'* || "$line" == *$'\tWake from'* ]] \
      || continue
    timestamp="${line:0:25}"
    [[ "$timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ [+-][0-9]{4}$ ]] \
      || continue
    event_epoch="$(LC_ALL=C /bin/date -j -f '%Y-%m-%d %H:%M:%S %z' "$timestamp" '+%s' 2>/dev/null)" \
      || continue
    if [[ "$line" == *$'\tEntering Sleep state'* ]]; then
      if [[ "$event_epoch" -ge "$start_epoch" && "$event_epoch" -le "$end_epoch" ]]; then
        sleep_epoch="$event_epoch"
      fi
      continue
    fi
    if [[ -n "$sleep_epoch" && "$event_epoch" -gt "$sleep_epoch" \
        && "$event_epoch" -le "$end_epoch" ]]; then
      printf '%s\t%s\n' "$sleep_epoch" "$event_epoch"
      return 0
    fi
  done
  return 1
}

find_qualified_sleep_wake_pair() {
  local log_file="$1"
  local window_start window_finish pair
  while IFS=$'\t' read -r window_start window_finish; do
    pair="$(find_sleep_wake_pair "$window_start" "$window_finish" < "$log_file")" \
      || continue
    printf '%s\n' "$pair"
    return 0
  done < <(
    awk -F '\t' '
      NR == FNR {
        if ($2 == "start") { starts[$1] = $3; order[++count] = $1 }
        next
      }
      FNR == 1 { next }
      $5 ~ /^[0-9]+$/ && $5 > finishes[$3] { finishes[$3] = $5 }
      END {
        for (position = 1; position <= count; position++) {
          id = order[position]
          if (starts[id] ~ /^[0-9]+$/ && finishes[id] ~ /^[0-9]+$/ && finishes[id] > starts[id]) {
            print starts[id] "\t" finishes[id]
          }
        }
      }
    ' "$segment_file" "$sample_file"
  )
  return 1
}

write_manifest() {
  local generation="$1"
  local root_uuid next
  root_uuid="${HOSTWRIGHT_PHASE08_SOAK_ROOT##*-soak-}"
  project_name="p08-soak-${root_uuid%%-*}"
  next="$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml.next"
  [[ ! -e "$next" && ! -L "$next" ]] || die 'A stale soak manifest write exists.'
  sed \
    -e "s/project: phase04-single/project: $project_name/" \
    -e "s#docker.io/library/python@sha256:[a-f0-9]*#$HOSTWRIGHT_PHASE08_SOAK_IMAGE#" \
    -e "s/18080:8080/$HOSTWRIGHT_PHASE08_SOAK_HOST_PORT:8080/" \
    -e '/^# soak-generation=/d' \
    "$HOSTWRIGHT_PHASE08_SOAK_CONFIG_TEMPLATE" > "$next"
  cat >> "$next" <<EOF

retention:
  recoveryHorizon: 3600s
  maximumDatabaseBytes: 268435456
  targetDatabaseBytes: 134217728
  classes:
    operations: { maxAge: 86400s, maxRecords: 5000, minimumRecords: 100 }
    observations: { maxAge: 7200s, maxRecords: 5000, minimumRecords: 100 }
    events: { maxAge: 86400s, maxRecords: 5000, minimumRecords: 100 }
    logs: { maxAge: 86400s, maxRecords: 5000, minimumRecords: 100 }
    metrics: { maxAge: 86400s, maxRecords: 5000, minimumRecords: 100 }
    traces: { maxAge: 86400s, maxRecords: 5000, minimumRecords: 100 }
    audits: { maxAge: 604800s, maxRecords: 5000, minimumRecords: 100 }
    supportEvidence: { maxAge: 604800s, maxRecords: 1000, minimumRecords: 10 }
    backups: { maxAge: 604800s, maxRecords: 16, minimumRecords: 2 }
    tombstones: { maxAge: 172800s, maxRecords: 5000, minimumRecords: 100 }
# soak-generation=$generation
EOF
  chmod 600 "$next"
  mv -f "$next" "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml"
  durable_sync "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" \
    || die 'The soak manifest could not be durably synchronized.' 74
}

start_daemon() {
  daemon_generation=$((daemon_generation + 1))
  local log_file="$HOSTWRIGHT_PHASE08_SOAK_ROOT/daemon-${daemon_generation}.log"
  "$HOSTWRIGHT_PHASE08_SOAK_DAEMON" \
    --foreground \
    --config "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" \
    --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" \
    --lock-file "$HOSTWRIGHT_PHASE08_SOAK_ROOT/daemon.lock" \
    --interval 4 --jitter 1 --max-backoff 30 --parallelism 1 \
    > "$log_file" 2>&1 &
  daemon_pid=$!
  chmod 600 "$log_file"
  printf '%s\n' "$daemon_pid" > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/daemon.pid"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/daemon.pid"
  append_state daemonGeneration "$daemon_generation"
  record "daemon-started generation=$daemon_generation pid=$daemon_pid"
}

daemon_process_running() {
  [[ -n "$daemon_pid" ]] || return 1
  local process_state
  process_state="$(/bin/ps -o stat= -p "$daemon_pid" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$process_state" && "$process_state" != Z* ]]
}

stop_daemon() {
  if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
    if daemon_process_running; then
      kill -TERM "$daemon_pid"
    fi
    local attempt=0
    while daemon_process_running && [[ "$attempt" -lt 30 ]]; do
      sleep 1
      attempt=$((attempt + 1))
    done
    daemon_process_running \
      && die 'The exact foreground daemon did not stop after SIGTERM.'
    wait "$daemon_pid" || true
    record "daemon-stopped generation=$daemon_generation pid=$daemon_pid"
  fi
  daemon_pid=''
}

verify_running() {
  local attempt=0 status_json lifecycle current_identifier
  while [[ "$attempt" -lt 36 ]]; do
    if [[ -n "$daemon_pid" ]] && ! daemon_process_running; then
      die 'The foreground daemon exited before healthy convergence.'
    fi
    if status_json="$("$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" status \
        "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" \
        --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" \
        --runtime-provider apple-cli --output json 2>/dev/null)"; then
      lifecycle="$(printf '%s' "$status_json" | /usr/bin/jq -er '.services[0].observed.lifecycle // empty' 2>/dev/null || true)"
      current_identifier="$(printf '%s' "$status_json" | /usr/bin/jq -er '.services[0].observed.resourceIdentifier // empty' 2>/dev/null || true)"
      if [[ "$lifecycle" == running && "$current_identifier" =~ $resource_identifier_pattern ]]; then
        if [[ -n "$resource_identifier" && "$resource_identifier" != "$current_identifier" ]]; then
          die 'The soak workload identity changed.'
        fi
        resource_identifier="$current_identifier"
        verify_exclusive_runtime_inventory
        if [[ -n "$state_file" && -f "$state_file" ]]; then
          local runtime_binding existing_binding
          runtime_binding="${resource_identifier}|${resource_uuid}"
          existing_binding="$(latest_state_value runtimeBinding)"
          if [[ -z "$existing_binding" ]]; then
            append_state runtimeBinding "$runtime_binding"
          else
            [[ "$existing_binding" == "$runtime_binding" ]] \
              || die 'The durable soak runtime binding changed.' 75
          fi
        fi
        return
      fi
    fi
    sleep 5
    attempt=$((attempt + 1))
  done
  die 'The exact soak workload did not converge to running within three minutes.'
}

read_with_retry() {
  local output="$1"
  shift
  local attempt=0
  while [[ "$attempt" -lt 3 ]]; do
    if "$@" > "$output" 2> "$output.error"; then
      chmod 600 "$output" "$output.error"
      return
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  chmod 600 "$output.error" 2>/dev/null || true
  die "A bounded read-only soak observation failed: ${*##*/}"
}

checkpoint_path() {
  local sequence="$1"
  printf '%s/sequence-%04d.tsv\n' "$checkpoint_root" "$sequence"
}

commit_checkpoint() {
  local sequence="$1"
  local material="$2"
  local checkpoint_sha256 checkpoint next
  checkpoint_sha256="$(printf '%s' "$material" | sha256_text)"
  [[ "$checkpoint_sha256" =~ ^[a-f0-9]{64}$ ]] \
    || die 'A sample checkpoint hash was malformed.' 75
  checkpoint="$(checkpoint_path "$sequence")"
  next="${checkpoint}.next.$$"
  [[ ! -e "$checkpoint" && ! -L "$checkpoint" \
      && ! -e "$next" && ! -L "$next" ]] \
    || die 'A cumulative sample checkpoint already exists.' 75
  {
    printf '%b\n' "$checkpoint_header"
    printf '%s\t%s\n' "$material" "$checkpoint_sha256"
  } > "$next"
  chmod 600 "$next"
  durable_sync "$next" \
    || die 'A cumulative sample checkpoint could not be durably synchronized.' 74
  mv "$next" "$checkpoint"
  durable_sync "$checkpoint" \
    || die 'A committed cumulative sample checkpoint could not be durably synchronized.' 74
  printf '%s\t%s\n' "$material" "$checkpoint_sha256" >> "$sample_file"
  chmod 600 "$sample_file"
  durable_sync "$sample_file" \
    || die 'The cumulative sample ledger could not be durably synchronized.' 74
  cumulative_samples="$sequence"
  cumulative_seconds=$((sequence * sample_interval_seconds))
  previous_checkpoint_sha256="$checkpoint_sha256"
  append_state lastSequence "$cumulative_samples"
  append_state qualifiedSeconds "$cumulative_seconds"
  append_state checkpointSHA256 "$previous_checkpoint_sha256"
}

load_qualification_state() {
  state_file="$HOSTWRIGHT_PHASE08_SOAK_ROOT/state-v2.tsv"
  evidence_file="$HOSTWRIGHT_PHASE08_SOAK_ROOT/evidence-v2.log"
  sample_file="$HOSTWRIGHT_PHASE08_SOAK_ROOT/samples-v2.tsv"
  checkpoint_root="$HOSTWRIGHT_PHASE08_SOAK_ROOT/checkpoints-v1"
  segment_file="$HOSTWRIGHT_PHASE08_SOAK_ROOT/segments-v1.tsv"
  active_run_root="$HOSTWRIGHT_PHASE08_SOAK_ROOT/active-run-v2"
  [[ "$(dirname "$state_file")" == "$HOSTWRIGHT_PHASE08_SOAK_ROOT" \
      && "$(dirname "$evidence_file")" == "$HOSTWRIGHT_PHASE08_SOAK_ROOT" \
      && "$(dirname "$checkpoint_root")" == "$HOSTWRIGHT_PHASE08_SOAK_ROOT" \
      && "$(dirname "$segment_file")" == "$HOSTWRIGHT_PHASE08_SOAK_ROOT" ]] \
    || die 'The resumable qualification authority escaped its private root.' 75
  private_file_is_valid "$state_file" \
      && private_file_is_valid "$evidence_file" \
      && private_directory_is_valid "$checkpoint_root" \
      && private_file_is_valid "$segment_file" \
    || die 'The resumable qualification authority is missing or unsafe.' 75
  [[ "$(latest_state_value schemaVersion)" == "$qualification_schema_version" ]] \
    || die 'The resumable qualification schema is unsupported.' 75
  qualification_id="$(latest_state_value qualificationID)"
  source_sha="$(latest_state_value sourceDigest)"
  hostwright_sha="$(latest_state_value hostwrightSHA256)"
  daemon_sha="$(latest_state_value daemonSHA256)"
  template_sha="$(latest_state_value templateSHA256)"
  host_identity_sha="$(latest_state_value hostIdentitySHA256)"
  project_name="$(latest_state_value projectName)"
  local runtime_binding
  runtime_binding="$(latest_state_value runtimeBinding)"
  if [[ -n "$runtime_binding" ]]; then
    [[ "${runtime_binding//[^|]/}" == '|' ]] \
      || die 'The checkpointed runtime binding is malformed.' 75
    resource_identifier="${runtime_binding%%|*}"
    resource_uuid="${runtime_binding#*|}"
  fi
  daemon_generation="$(latest_state_value daemonGeneration)"
  [[ "$qualification_id" =~ $uuid_pattern \
      && "$source_sha" =~ ^[a-f0-9]{64}$ \
      && "$hostwright_sha" =~ ^[a-f0-9]{64}$ \
      && "$daemon_sha" =~ ^[a-f0-9]{64}$ \
      && "$template_sha" =~ ^[a-f0-9]{64}$ \
      && "$host_identity_sha" =~ ^[a-f0-9]{64}$ \
      && "$daemon_generation" =~ ^[0-9]+$ \
      && "$(latest_state_value expectedSamples)" == "$expected_samples" \
      && "$(latest_state_value requiredQualifiedSeconds)" == "$duration_seconds" ]] \
    || die 'The resumable qualification authority is malformed.' 75
  [[ "$(latest_state_value sourceCommit)" == "$HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT" \
      && "$source_sha" == "$(source_digest)" \
      && "$hostwright_sha" == "$(sha256 "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT")" \
      && "$daemon_sha" == "$(sha256 "$HOSTWRIGHT_PHASE08_SOAK_DAEMON")" \
      && "$template_sha" == "$(sha256 "$HOSTWRIGHT_PHASE08_SOAK_CONFIG_TEMPLATE")" \
      && "$host_identity_sha" == "$(current_host_identity)" \
      && "$(latest_state_value imageReference)" == "$HOSTWRIGHT_PHASE08_SOAK_IMAGE" \
      && "$(latest_state_value hostPort)" == "$HOSTWRIGHT_PHASE08_SOAK_HOST_PORT" ]] \
    || die 'Resume refused changed source, binary, configuration, or physical-host identity.' 75
  [[ "$project_name" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] \
    || die 'The checkpointed project identity is malformed.' 75
  if [[ -n "$resource_identifier" || -n "$resource_uuid" ]]; then
    [[ "$resource_identifier" =~ $resource_identifier_pattern \
        && "$resource_uuid" =~ $resource_uuid_pattern ]] \
      || die 'The checkpointed runtime identity is malformed.' 75
  fi
}

validate_segment_ledger() {
  [[ "$(sed -n '1p' "$segment_file")" \
      == $'segmentID\tevent\tepoch\tsequence\tqualifiedSeconds\tcheckpointSHA256\tdetail1\tdetail2' ]] \
    || die 'The segment ledger header changed.' 75
  awk -F '\t' \
    -v expectedSamples="$expected_samples" \
    -v interval="$sample_interval_seconds" \
    -v sourceCommit="$HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT" '
      NR == 1 { next }
      NF != 8 { exit 1 }
      $1 !~ /^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/ { exit 1 }
      $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/ { exit 1 }
      length($6) != 64 || $6 !~ /^[a-f0-9]+$/ { exit 1 }
      $4 > expectedSamples || $5 != $4 * interval { exit 1 }
      $2 == "start" {
        if (++starts[$1] != 1 || finishes[$1] != 0) exit 1
        if ($7 !~ /^gapSeconds=[0-9]+$/ || $8 != "sourceCommit=" sourceCommit) exit 1
        startEpoch[$1] = $3
        next
      }
      $2 == "finish" {
        if (starts[$1] != 1 || ++finishes[$1] != 1 || $3 < startEpoch[$1]) exit 1
        if ($7 !~ /^(passed|failed|interrupted)$/ || $8 !~ /^[0-9]+$/) exit 1
        next
      }
      { exit 1 }
      END {
        open = 0
        for (id in starts) if (finishes[id] == 0) open++
        if (open > 1) exit 1
      }
    ' "$segment_file" \
    || die 'The segment ledger is malformed, duplicated, or overlapping.' 75
}

validate_checkpoint_chain() {
  local mode="${1:-rebuild}"
  [[ "$mode" == rebuild || "$mode" == read-only ]] \
    || die 'The checkpoint validation mode is invalid.' 64
  local rebuilt="${sample_file}.rebuild.$$"
  if [[ "$mode" == read-only ]]; then
    rebuilt=/dev/null
  fi
  local expected_sequence=1 expected_predecessor="$genesis_checkpoint_sha256"
  local checkpoint header row material computed file_name inventory_file inventory_sha
  local sequence row_qualification_id row_segment_id row_segment_sample epoch qualified_seconds row_daemon_pid
  local rss_kb descriptors database_bytes operations active_groups events traces retries oslog_count
  local runtime_inventory_sha256 config_sha256 integrity_sha256 row_resource_identifier
  local row_resource_uuid row_project_name row_hostwright_sha row_daemon_sha row_template_sha
  local row_host_identity_sha row_source_commit predecessor_sha256 checkpoint_sha256
  local prior_segment_id='' prior_segment_sample=0
  validate_segment_ledger
  [[ -z "$(find "$checkpoint_root" -mindepth 1 -maxdepth 1 \
      \( ! -type f -o \( ! -name 'sequence-*.tsv' -a ! -name 'sequence-*.tsv.next.*' \) \) \
      -print -quit)" ]] \
    || die 'The checkpoint authority contains an unexpected artifact.' 75
  printf '%b\n' "$checkpoint_header" > "$rebuilt"
  if [[ "$mode" == rebuild ]]; then
    chmod 600 "$rebuilt"
  fi
  while IFS= read -r checkpoint; do
    [[ -f "$checkpoint" && ! -L "$checkpoint" \
        && "$(stat -f '%Lp' "$checkpoint")" == 600 \
        && "$(stat -f '%u' "$checkpoint")" == "$(id -u)" ]] \
      || die 'A cumulative checkpoint file is unsafe.' 75
    file_name="${checkpoint##*/}"
    [[ "$file_name" == "sequence-$(printf '%04d' "$expected_sequence").tsv" \
        && "$(wc -l < "$checkpoint" | tr -d ' ')" == 2 ]] \
      || die 'The cumulative checkpoint sequence is missing, duplicated, or malformed.' 75
    header="$(sed -n '1p' "$checkpoint")"
    row="$(sed -n '2p' "$checkpoint")"
    [[ "$header" == "$(printf '%b' "$checkpoint_header")" \
        && "$(printf '%s\n' "$row" | awk -F '\t' '{ print NF }')" == 29 ]] \
      || die 'A cumulative checkpoint contract changed.' 75
    IFS=$'\t' read -r sequence row_qualification_id row_segment_id row_segment_sample epoch qualified_seconds \
      row_daemon_pid rss_kb descriptors database_bytes operations active_groups events traces \
      retries oslog_count runtime_inventory_sha256 config_sha256 integrity_sha256 \
      row_resource_identifier row_resource_uuid row_project_name row_hostwright_sha \
      row_daemon_sha row_template_sha row_host_identity_sha row_source_commit \
      predecessor_sha256 checkpoint_sha256 \
      <<< "$row"
    material="${row%$'\t'*}"
    computed="$(printf '%s' "$material" | sha256_text)"
    [[ "$sequence" == "$expected_sequence" \
        && "$row_qualification_id" == "$qualification_id" \
        && "$row_segment_id" =~ $uuid_pattern \
        && "$row_segment_sample" =~ ^[1-9][0-9]*$ \
        && "$epoch" =~ ^[0-9]+$ \
        && "$qualified_seconds" == "$((sequence * sample_interval_seconds))" \
        && "$row_daemon_pid" =~ ^[1-9][0-9]*$ \
        && "$rss_kb" =~ ^[0-9]+$ \
        && "$descriptors" =~ ^[0-9]+$ \
        && "$database_bytes" =~ ^[0-9]+$ \
        && "$operations" =~ ^[0-9]+$ \
        && "$active_groups" =~ ^[0-9]+$ \
        && "$events" =~ ^[0-9]+$ \
        && "$traces" =~ ^[0-9]+$ \
        && "$retries" =~ ^[0-9]+$ \
        && "$oslog_count" =~ ^[1-9][0-9]*$ \
        && "$runtime_inventory_sha256" =~ ^[a-f0-9]{64}$ \
        && "$config_sha256" =~ ^[a-f0-9]{64}$ \
        && "$integrity_sha256" =~ ^[a-f0-9]{64}$ \
        && "$row_resource_identifier" == "$resource_identifier" \
        && "$row_resource_uuid" == "$resource_uuid" \
        && "$row_project_name" == "$project_name" \
        && "$row_hostwright_sha" == "$hostwright_sha" \
        && "$row_daemon_sha" == "$daemon_sha" \
        && "$row_template_sha" == "$template_sha" \
        && "$row_host_identity_sha" == "$host_identity_sha" \
        && "$row_source_commit" == "$HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT" \
        && "$predecessor_sha256" == "$expected_predecessor" \
        && "$checkpoint_sha256" == "$computed" ]] \
      || die 'A cumulative checkpoint failed identity, bound, or predecessor validation.' 75
    if [[ "$row_segment_id" == "$prior_segment_id" ]]; then
      [[ "$row_segment_sample" == "$((prior_segment_sample + 1))" ]] \
        || die 'A cumulative checkpoint skipped or duplicated a segment sample.' 75
    else
      [[ "$row_segment_sample" == 1 ]] \
        || die 'A cumulative checkpoint did not begin its segment at sample one.' 75
    fi
    awk -F '\t' \
      -v id="$row_segment_id" \
      -v sequence="$sequence" \
      -v segmentSample="$row_segment_sample" \
      -v predecessor="$predecessor_sha256" \
      -v interval="$sample_interval_seconds" '
        $1 == id && $2 == "start" {
          count++
          startSequence = $4
          startSeconds = $5
          startCheckpoint = $6
        }
        END {
          if (count != 1 || startSeconds != startSequence * interval) exit 1
          if (sequence - startSequence != segmentSample) exit 1
          if (segmentSample == 1 && startCheckpoint != predecessor) exit 1
        }
      ' "$segment_file" \
      || die 'A cumulative checkpoint is not bound to one valid segment start.' 75
    inventory_file="$HOSTWRIGHT_PHASE08_SOAK_ROOT/runtime-inventory-v1/sequence-$(printf '%04d' "$sequence").json"
    private_file_is_valid "$inventory_file" \
      || die 'A checkpointed runtime inventory is missing.' 75
    inventory_sha="$(sha256 "$inventory_file")"
    [[ "$inventory_sha" == "$runtime_inventory_sha256" ]] \
      || die 'A checkpointed runtime inventory hash changed.' 75
    printf '%s\n' "$row" >> "$rebuilt"
    expected_predecessor="$checkpoint_sha256"
    last_config_sha256="$config_sha256"
    prior_segment_id="$row_segment_id"
    prior_segment_sample="$row_segment_sample"
    last_sample_epoch="$epoch"
    expected_sequence=$((expected_sequence + 1))
  done < <(find "$checkpoint_root" -mindepth 1 -maxdepth 1 -type f -name 'sequence-*.tsv' | LC_ALL=C sort)
  if [[ "$mode" == rebuild ]]; then
    mv "$rebuilt" "$sample_file"
    chmod 600 "$sample_file"
    durable_sync "$sample_file" \
      || die 'The rebuilt cumulative sample ledger could not be durably synchronized.' 74
  fi
  cumulative_samples=$((expected_sequence - 1))
  cumulative_seconds=$((cumulative_samples * sample_interval_seconds))
  previous_checkpoint_sha256="$expected_predecessor"
  [[ "$cumulative_samples" -le "$expected_samples" ]] \
    || die 'The cumulative checkpoint chain exceeds its fixed sample budget.' 75
}

recover_uncommitted_artifacts() {
  local recovery_id recovery_root expected_sequence moved=false path file_name sequence destination
  recovery_id="$(new_uuid)"
  recovery_root="$HOSTWRIGHT_PHASE08_SOAK_ROOT/recovered-partials-v1/$recovery_id"
  expected_sequence=$((cumulative_samples + 1))
  while IFS= read -r path; do
    [[ -e "$path" ]] || continue
    if [[ "$moved" == false ]]; then
      mkdir -p "$recovery_root"
      chmod 700 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/recovered-partials-v1" "$recovery_root"
      moved=true
    fi
    file_name="${path##*/}"
    destination="$recovery_root/${file_name}.partial"
    [[ -f "$path" && ! -L "$path" \
        && "$(stat -f '%u' "$path")" == "$(id -u)" ]] \
      || die 'An uncommitted partial artifact is unsafe.' 75
    [[ ! -e "$destination" && ! -L "$destination" ]] \
      || die 'A recovered partial artifact destination already exists.' 75
    mv "$path" "$destination"
    chmod 600 "$destination"
  done < <(
    find "$checkpoint_root" "$HOSTWRIGHT_PHASE08_SOAK_ROOT/fault-checkpoints-v1" \
      -mindepth 1 -maxdepth 1 -type f -name '*.next.*' -print 2>/dev/null
    if [[ -f "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml.next" ]]; then
      printf '%s\n' "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml.next"
    fi
    if [[ -f "$HOSTWRIGHT_PHASE08_SOAK_ROOT/pressure-v1.bin" ]]; then
      printf '%s\n' "$HOSTWRIGHT_PHASE08_SOAK_ROOT/pressure-v1.bin"
    fi
  )
  while IFS= read -r path; do
    file_name="${path##*/}"
    [[ "$file_name" =~ ^sequence-[0-9]{4}\.json$ ]] \
      || die 'An uncommitted runtime inventory name is malformed.' 75
    sequence="${file_name#sequence-}"
    sequence="${sequence%.json}"
    sequence="$((10#$sequence))"
    if [[ "$sequence" -le "$cumulative_samples" ]]; then
      continue
    fi
    [[ "$sequence" == "$expected_sequence" ]] \
      || die 'A future uncommitted runtime inventory exceeds the next checkpoint.' 75
    if [[ "$moved" == false ]]; then
      mkdir -p "$recovery_root"
      chmod 700 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/recovered-partials-v1" "$recovery_root"
      moved=true
    fi
    destination="$recovery_root/${file_name}.uncommitted"
    [[ ! -e "$destination" && ! -L "$destination" ]] \
      || die 'A recovered runtime inventory destination already exists.' 75
    mv "$path" "$destination"
    chmod 600 "$destination"
  done < <(
    if [[ -d "$HOSTWRIGHT_PHASE08_SOAK_ROOT/runtime-inventory-v1" ]]; then
      find "$HOSTWRIGHT_PHASE08_SOAK_ROOT/runtime-inventory-v1" \
        -mindepth 1 -maxdepth 1 -type f -name 'sequence-*.json' | LC_ALL=C sort
    fi
  )
  if [[ "$moved" == true ]]; then
    durable_sync "$recovery_root" \
      || die 'Recovered partial artifacts could not be durably synchronized.' 74
    record "uncommitted-artifacts-preserved recovery=$recovery_id nextSequence=$expected_sequence"
  fi
}

record_sample() {
  local sequence="$1"
  local sample_root="$HOSTWRIGHT_PHASE08_SOAK_ROOT/current-sample"
  local inventory_root="$HOSTWRIGHT_PHASE08_SOAK_ROOT/runtime-inventory-v1"
  local inventory_file
  mkdir -p "$sample_root"
  chmod 700 "$sample_root"
  mkdir -p "$inventory_root"
  chmod 700 "$inventory_root"
  inventory_file="$inventory_root/sequence-$(printf '%04d' "$sequence").json"
  verify_exclusive_runtime_inventory "$inventory_file"
  durable_sync "$inventory_file" \
    || die 'A per-sample runtime inventory could not be durably synchronized.' 74
  read_with_retry "$sample_root/metrics.json" \
    "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" metrics snapshot \
      --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" --output json
  read_with_retry "$sample_root/traces.json" \
    "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" traces inspect --limit 100 \
      --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" --output json
  read_with_retry "$sample_root/events.json" \
    "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" events --limit 1000 --sort desc \
      --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" --output json
  read_with_retry "$sample_root/support-preview.json" \
    "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" diagnostics support preview \
      --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" \
      --project "$project_name" \
      --manifest "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" --output json
  read_with_retry "$sample_root/integrity.json" \
    "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" state integrity \
      --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" --output json

  local epoch rss_kb descriptors database_bytes operations active_groups events traces retries
  local metrics_series oslog_count runtime_inventory_sha256 config_sha256 integrity_sha256
  local qualified_seconds material
  epoch="$(date +%s)"
  rss_kb="$(ps -o rss= -p "$daemon_pid" | tr -d ' ')"
  descriptors="$(/usr/sbin/lsof -p "$daemon_pid" 2>/dev/null | wc -l | tr -d ' ')"
  database_bytes="$(stat -f '%z' "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite")"
  operations="$(/usr/bin/sqlite3 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" 'SELECT count(*) FROM operation_ledger;')"
  active_groups="$(/usr/bin/sqlite3 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" "SELECT count(*) FROM operation_groups WHERE status = 'active';")"
  events="$(/usr/bin/sqlite3 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" 'SELECT count(*) FROM event_ledger;')"
  traces="$(/usr/bin/sqlite3 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" "SELECT count(*) FROM event_ledger WHERE type = 'trace.span.v1';")"
  retries="$(/usr/bin/sqlite3 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" 'SELECT count(*) FROM restart_attempt_history;')"
  metrics_series="$(/usr/bin/jq -er '.series | length' "$sample_root/metrics.json")"
  runtime_inventory_sha256="$(sha256 "$inventory_file")"
  config_sha256="$(sha256 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml")"
  integrity_sha256="$(sha256 "$sample_root/integrity.json")"
  oslog_count="$(/usr/bin/log show --last 10m --style ndjson --predicate "subsystem == \"$subsystem\"" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$rss_kb" =~ ^[0-9]+$ && "$descriptors" =~ ^[0-9]+$ \
      && "$database_bytes" =~ ^[0-9]+$ && "$operations" =~ ^[0-9]+$ \
      && "$active_groups" =~ ^[0-9]+$ && "$events" =~ ^[0-9]+$ \
      && "$traces" =~ ^[0-9]+$ && "$retries" =~ ^[0-9]+$ \
      && "$metrics_series" == 59 && "$runtime_inventory_sha256" =~ ^[a-f0-9]{64}$ \
      && "$config_sha256" =~ ^[a-f0-9]{64}$ && "$integrity_sha256" =~ ^[a-f0-9]{64}$ \
      && "$oslog_count" -gt 0 ]] \
    || die 'A soak sample was incomplete, unbounded, or lost exact runtime/observability identity.'
  qualified_seconds=$((sequence * sample_interval_seconds))
  printf -v material '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$sequence" "$qualification_id" "$segment_id" "$segment_sample" "$epoch" "$qualified_seconds" \
    "$daemon_pid" "$rss_kb" "$descriptors" "$database_bytes" "$operations" \
    "$active_groups" "$events" "$traces" "$retries" "$oslog_count" \
    "$runtime_inventory_sha256" "$config_sha256" "$integrity_sha256" \
    "$resource_identifier" "$resource_uuid" "$project_name" "$hostwright_sha" \
    "$daemon_sha" "$template_sha" "$host_identity_sha" \
    "$HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT" \
    "$previous_checkpoint_sha256"
  commit_checkpoint "$sequence" "$material"
  last_sample_epoch="$epoch"
}

churn_configuration() {
  local sequence="$1"
  local current="$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml"
  local next="$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml.next"
  [[ ! -e "$next" && ! -L "$next" ]] \
    || die 'A stale configuration churn write exists.' 75
  sed -e '/^# soak-generation=/d' "$current" > "$next"
  printf '# soak-generation=%s\n' "$sequence" >> "$next"
  chmod 600 "$next"
  mv -f "$next" "$current"
  durable_sync "$current" \
    || die 'The churned soak configuration could not be durably synchronized.' 74
}

inject_pressure() {
  local pressure="$HOSTWRIGHT_PHASE08_SOAK_ROOT/pressure-v1.bin"
  [[ ! -e "$pressure" ]] || die 'The bounded pressure artifact already exists.'
  dd if=/dev/zero of="$pressure" bs=1048576 count=64 >/dev/null 2>&1
  chmod 600 "$pressure"
  (
    ulimit -n 64
    "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" state integrity \
      --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" --output json
  ) > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/pressure-integrity.json"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/pressure-integrity.json"
  [[ -f "$pressure" && ! -L "$pressure" && "$(stat -f '%z' "$pressure")" == 67108864 ]] \
    || die 'The bounded pressure artifact identity changed.'
  rm -f "$pressure"
  record 'pressure-cell-pass bytes=67108864 fdLimit=64'
}

compact_state() {
  local sequence="$1"
  local attempt=1
  while [[ "$attempt" -le "$compaction_attempt_limit" ]]; do
    local prefix="$HOSTWRIGHT_PHASE08_SOAK_ROOT/compaction-${sequence}-attempt-${attempt}"
    local plan="${prefix}-plan.json"
    local plan_error="${prefix}-plan.error"
    local result="${prefix}-result.json"
    local result_error="${prefix}-result.error"
    if ! "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" state compact \
        "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" --dry-run \
        --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" --output json \
        > "$plan" 2> "$plan_error"; then
      chmod 600 "$plan" "$plan_error"
      die "Soak compaction dry-run failed at sequence $sequence attempt $attempt."
    fi
    chmod 600 "$plan" "$plan_error"
    if [[ "$(/usr/bin/jq -er '.executable' "$plan")" != true ]]; then
      record "compaction-noop sequence=$sequence attempt=$attempt"
      return
    fi

    local token status
    token="$(/usr/bin/jq -er '.confirmationToken' "$plan")" \
      || die "Soak compaction plan omitted its confirmation token at sequence $sequence attempt $attempt."
    status=0
    "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" state compact \
      "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" --confirm-compact "$token" \
      --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" --output json \
      > "$result" 2> "$result_error" || status=$?
    chmod 600 "$result" "$result_error"
    if [[ "$status" == 0 ]]; then
      [[ "$(/usr/bin/jq -er '.integrityHealth' "$result")" == healthy ]] \
        || die 'Confirmed soak compaction did not preserve healthy integrity.'
      record "compaction-pass sequence=$sequence attempt=$attempt"
      return
    fi
    if [[ "$status" == 70 ]] \
        && /usr/bin/jq -e '.code == "HW-CLI-003"' "$result_error" >/dev/null 2>&1; then
      record "compaction-stale-plan sequence=$sequence attempt=$attempt"
      attempt=$((attempt + 1))
      sleep 1
      continue
    fi
    die "Soak compaction confirmation failed at sequence $sequence attempt $attempt with exit $status."
  done
  die "Soak compaction exhausted $compaction_attempt_limit fresh confirmation attempts at sequence $sequence."
}

recover_active_run_marker() {
  if [[ ! -e "$active_run_root" ]]; then
    [[ "$(awk -F '\t' '
        NR > 1 && $2 == "start" { starts[$1]++ }
        NR > 1 && $2 == "finish" { finishes[$1]++ }
        END { for (id in starts) if (finishes[id] == 0) open++; print open + 0 }
      ' "$segment_file")" == 0 ]] \
      || die 'An open segment exists without its exact active-run owner marker.' 75
    return
  fi
  local owner="$active_run_root/owner-v1.tsv"
  private_directory_is_valid "$active_run_root" \
      && private_file_is_valid "$owner" \
    || die 'The active-run marker is malformed.' 75
  local prior_pid prior_command prior_boot prior_segment prior_start_epoch
  local prior_start_sequence prior_start_checkpoint prior_gap_seconds current_boot
  local start_count finish_count finish_epoch
  prior_pid="$(awk -F '\t' '$1 == "pid" { print $2 }' "$owner")"
  prior_boot="$(awk -F '\t' '$1 == "bootIdentity" { print $2 }' "$owner")"
  prior_segment="$(awk -F '\t' '$1 == "segmentID" { print $2 }' "$owner")"
  prior_start_epoch="$(awk -F '\t' '$1 == "startEpoch" { print $2 }' "$owner")"
  prior_start_sequence="$(awk -F '\t' '$1 == "startSequence" { print $2 }' "$owner")"
  prior_start_checkpoint="$(awk -F '\t' '$1 == "startCheckpointSHA256" { print $2 }' "$owner")"
  prior_gap_seconds="$(awk -F '\t' '$1 == "gapSeconds" { print $2 }' "$owner")"
  [[ "$prior_pid" =~ ^[1-9][0-9]*$ \
      && "$prior_boot" =~ ^[a-f0-9]{64}$ \
      && "$prior_segment" =~ $uuid_pattern \
      && "$prior_start_epoch" =~ ^[0-9]+$ \
      && "$prior_start_sequence" =~ ^[0-9]+$ \
      && "$prior_start_sequence" -le "$cumulative_samples" \
      && "$prior_gap_seconds" =~ ^[0-9]+$ \
      && "$prior_start_checkpoint" =~ ^[a-f0-9]{64}$ ]] \
    || die 'The active-run marker identity is malformed.' 75
  current_boot="$(boot_identity)"
  if [[ "$prior_boot" == "$current_boot" ]] && kill -0 "$prior_pid" 2>/dev/null; then
    prior_command="$(/bin/ps -o command= -p "$prior_pid" 2>/dev/null)"
    [[ "$prior_command" != *phase08-soak-qualification.sh* ]] \
      || die 'Another qualification segment still owns this checkpoint root.' 75
    die 'The stale qualification PID was reused; refusing unsafe marker recovery.' 75
  fi
  start_count="$(awk -F '\t' -v id="$prior_segment" '$1 == id && $2 == "start" { count++ } END { print count + 0 }' "$segment_file")"
  finish_count="$(awk -F '\t' -v id="$prior_segment" '$1 == id && $2 == "finish" { count++ } END { print count + 0 }' "$segment_file")"
  [[ "$start_count" -le 1 && "$finish_count" -le 1 ]] \
    || die 'The stale active segment has duplicate ledger events.' 75
  if [[ "$start_count" == 0 ]]; then
    printf '%s\tstart\t%s\t%s\t%s\t%s\tgapSeconds=%s\tsourceCommit=%s\n' \
      "$prior_segment" "$prior_start_epoch" "$prior_start_sequence" \
      "$((prior_start_sequence * sample_interval_seconds))" \
      "$prior_start_checkpoint" "$prior_gap_seconds" \
      "$HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT" >> "$segment_file"
  else
    awk -F '\t' \
      -v id="$prior_segment" \
      -v epoch="$prior_start_epoch" \
      -v sequence="$prior_start_sequence" \
      -v checkpoint="$prior_start_checkpoint" '
        $1 == id && $2 == "start" {
          if ($3 != epoch || $4 != sequence || $6 != checkpoint) exit 1
          found++
        }
        END { if (found != 1) exit 1 }
      ' "$segment_file" \
      || die 'The stale active-run marker disagrees with its segment ledger.' 75
  fi
  if [[ "$finish_count" == 0 ]]; then
    finish_epoch="$last_sample_epoch"
    if [[ "$finish_epoch" -lt "$prior_start_epoch" ]]; then
      finish_epoch="$prior_start_epoch"
    fi
    printf '%s\tfinish\t%s\t%s\t%s\t%s\tinterrupted\t255\n' \
      "$prior_segment" "$finish_epoch" "$cumulative_samples" "$cumulative_seconds" \
      "$previous_checkpoint_sha256" >> "$segment_file"
  fi
  chmod 600 "$segment_file"
  durable_sync "$segment_file" \
    || die 'The recovered segment ledger could not be durably synchronized.' 74
  validate_segment_ledger
  rm -f "$owner"
  rmdir "$active_run_root"
  durable_sync "$HOSTWRIGHT_PHASE08_SOAK_ROOT" \
    || die 'The recovered active-run marker removal was not durable.' 74
  append_state phase resumable
  record "stale-segment-marker-recovered priorPID=$prior_pid priorBoot=$prior_boot currentBoot=$current_boot segment=$prior_segment sequence=$cumulative_samples"
}

begin_segment() {
  recover_active_run_marker
  segment_id="$(new_uuid)"
  [[ "$segment_id" =~ $uuid_pattern ]] \
    || die 'The new qualification segment identity is malformed.' 75
  segment_sample=0
  local start_epoch gap_seconds=0 current_boot
  start_epoch="$(date +%s)"
  current_boot="$(boot_identity)"
  if [[ "$last_sample_epoch" -gt 0 && "$start_epoch" -gt "$last_sample_epoch" ]]; then
    gap_seconds=$((start_epoch - last_sample_epoch))
  fi
  mkdir "$active_run_root"
  {
    printf 'schemaVersion\t1\n'
    printf 'pid\t%s\n' "$$"
    printf 'bootIdentity\t%s\n' "$current_boot"
    printf 'segmentID\t%s\n' "$segment_id"
    printf 'startEpoch\t%s\n' "$start_epoch"
    printf 'startSequence\t%s\n' "$cumulative_samples"
    printf 'startCheckpointSHA256\t%s\n' "$previous_checkpoint_sha256"
    printf 'gapSeconds\t%s\n' "$gap_seconds"
  } > "$active_run_root/owner-v1.tsv"
  chmod 700 "$active_run_root"
  chmod 600 "$active_run_root/owner-v1.tsv"
  durable_sync "$active_run_root/owner-v1.tsv" \
    || die 'The active segment marker could not be durably synchronized.' 74
  durable_sync "$active_run_root" \
    || die 'The active segment directory could not be durably synchronized.' 74
  printf '%s\tstart\t%s\t%s\t%s\t%s\tgapSeconds=%s\tsourceCommit=%s\n' \
    "$segment_id" "$start_epoch" "$cumulative_samples" "$cumulative_seconds" \
    "$previous_checkpoint_sha256" "$gap_seconds" \
    "$HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT" >> "$segment_file"
  chmod 600 "$segment_file"
  durable_sync "$segment_file" \
    || die 'The segment ledger could not be durably synchronized.' 74
  append_state phase running
  append_state segmentID "$segment_id"
  append_state segmentStartEpoch "$start_epoch"
  append_state segmentStartSequence "$cumulative_samples"
  append_state segmentGapSeconds "$gap_seconds"
  record "segment-start id=$segment_id sequence=$cumulative_samples qualifiedSeconds=$cumulative_seconds gapSeconds=$gap_seconds"
}

close_segment() {
  local outcome="$1"
  local status="$2"
  local finish_epoch
  [[ -n "$segment_id" ]] || return
  finish_epoch="$(date +%s)"
  printf '%s\tfinish\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$segment_id" "$finish_epoch" "$cumulative_samples" "$cumulative_seconds" \
    "$previous_checkpoint_sha256" "$outcome" "$status" >> "$segment_file"
  chmod 600 "$segment_file"
  durable_sync "$segment_file" \
    || die 'The segment completion could not be durably synchronized.' 74
  append_state segmentFinishEpoch "$finish_epoch"
  append_state segmentOutcome "$outcome"
  append_state segmentExitCode "$status"
  record "segment-finish id=$segment_id outcome=$outcome status=$status sequence=$cumulative_samples qualifiedSeconds=$cumulative_seconds"
  if [[ -d "$active_run_root" ]]; then
    rm -f "$active_run_root/owner-v1.tsv"
    rmdir "$active_run_root"
    durable_sync "$HOSTWRIGHT_PHASE08_SOAK_ROOT" \
      || die 'The active segment marker removal was not durable.' 74
  fi
  segment_id=''
}

fault_receipt_path() {
  local sequence="$1"
  local label="$2"
  printf '%s/fault-checkpoints-v1/sequence-%04d-%s.tsv\n' \
    "$HOSTWRIGHT_PHASE08_SOAK_ROOT" "$sequence" "$label"
}

fault_receipt_valid() {
  local sequence="$1"
  local label="$2"
  local receipt row material recorded_sha computed_sha config_sha
  receipt="$(fault_receipt_path "$sequence" "$label")"
  [[ -f "$receipt" && ! -L "$receipt" \
      && "$(stat -f '%Lp' "$receipt")" == 600 \
      && "$(wc -l < "$receipt" | tr -d ' ')" == 2 \
      && "$(sed -n '1p' "$receipt")" == $'schemaVersion\tqualificationID\tsequence\tlabel\tsourceCommit\thostwrightSHA256\tdaemonSHA256\thostIdentitySHA256\tresourceIdentifier\tresourceUUID\tprojectName\tconfigSHA256\tpredecessorCheckpointSHA256\treceiptSHA256' ]] \
    || return 1
  row="$(sed -n '2p' "$receipt")"
  [[ "$(printf '%s\n' "$row" | awk -F '\t' '{ print NF }')" == 14 ]] || return 1
  recorded_sha="${row##*$'\t'}"
  material="${row%$'\t'*}"
  computed_sha="$(printf '%s' "$material" | sha256_text)"
  config_sha="$(sha256 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml")"
  [[ "$material" == "$checkpoint_schema_version"$'\t'"$qualification_id"$'\t'"$sequence"$'\t'"$label"$'\t'"$HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT"$'\t'"$hostwright_sha"$'\t'"$daemon_sha"$'\t'"$host_identity_sha"$'\t'"$resource_identifier"$'\t'"$resource_uuid"$'\t'"$project_name"$'\t'"$config_sha"$'\t'"$previous_checkpoint_sha256" \
      && "$recorded_sha" == "$computed_sha" ]]
}

run_checkpointed_fault() {
  local sequence="$1"
  local label="$2"
  shift 2
  if fault_receipt_valid "$sequence" "$label"; then
    record "fault-receipt-reused sequence=$sequence label=$label"
    return
  fi
  local receipt next material receipt_sha config_sha
  receipt="$(fault_receipt_path "$sequence" "$label")"
  [[ ! -e "$receipt" ]] \
    || die "A fault receipt is corrupt for sequence $sequence label $label." 75
  "$@"
  config_sha="$(sha256 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml")"
  printf -v material '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$checkpoint_schema_version" "$qualification_id" "$sequence" "$label" \
    "$HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT" "$hostwright_sha" "$daemon_sha" \
    "$host_identity_sha" "$resource_identifier" "$resource_uuid" "$project_name" "$config_sha" \
    "$previous_checkpoint_sha256"
  receipt_sha="$(printf '%s' "$material" | sha256_text)"
  next="${receipt}.next.$$"
  [[ ! -e "$next" && ! -L "$next" ]] \
    || die 'A stale fault receipt write exists.' 75
  {
    printf 'schemaVersion\tqualificationID\tsequence\tlabel\tsourceCommit\thostwrightSHA256\tdaemonSHA256\thostIdentitySHA256\tresourceIdentifier\tresourceUUID\tprojectName\tconfigSHA256\tpredecessorCheckpointSHA256\treceiptSHA256\n'
    printf '%s\t%s\n' "$material" "$receipt_sha"
  } > "$next"
  chmod 600 "$next"
  durable_sync "$next" \
    || die 'A fault completion receipt could not be durably synchronized.' 74
  mv "$next" "$receipt"
  durable_sync "$receipt" \
    || die 'A committed fault receipt could not be durably synchronized.' 74
  record "fault-receipt-committed sequence=$sequence label=$label sha256=$receipt_sha"
}

run_scheduled_faults() {
  local sequence="$1"
  if (( sequence % 12 == 0 )); then
    run_checkpointed_fault "$sequence" compaction compact_state "$sequence"
  fi
  if (( sequence % 72 == 0 )); then
    run_checkpointed_fault "$sequence" pressure inject_pressure
    run_checkpointed_fault "$sequence" workload inject_workload_fault
  fi
  if (( sequence % 144 == 0 )); then
    run_checkpointed_fault "$sequence" daemon inject_daemon_fault
  fi
  if (( sequence == 288 )); then
    run_checkpointed_fault "$sequence" helper \
      run_fault_cell \
      'RuntimeQualificationRecoveryDriverTests.testWriterIsKilledAndFreshExecutableResumesItsDurableCheckpoint' \
      'helper-fault-cell'
  fi
  if (( sequence == 576 )); then
    run_checkpointed_fault "$sequence" runtime \
      run_fault_cell \
      'RuntimeQualificationProcessControlTests.testCrashProbeTerminatesTheObservedDescendantTree' \
      'runtime-fault-cell'
  fi
}

runner_exit() {
  local status=$?
  trap - EXIT
  set +e
  if [[ "$status" -ne 0 && -n "$state_file" && -f "$state_file" ]]; then
    local current_phase
    current_phase="$(awk -F '\t' '$1 == "phase" { phase = $2 } END { print phase }' "$state_file")"
    if [[ "$current_phase" == running ]]; then
      append_state phase resumable
      append_state failureEpoch "$(date +%s)"
      append_state runnerExitCode "$status"
      record "runner-exit-classified status=$status resumable=true sequence=$cumulative_samples"
    fi
  fi
  if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
    if daemon_process_running; then
      kill -TERM "$daemon_pid" 2>/dev/null
    fi
    local attempt=0
    while daemon_process_running && [[ "$attempt" -lt 30 ]]; do
      sleep 1
      attempt=$((attempt + 1))
    done
    wait "$daemon_pid" 2>/dev/null
  fi
  if [[ "$status" -ne 0 ]]; then
    if [[ "$status" == 130 || "$status" == 143 ]]; then
      close_segment interrupted "$status"
    else
      close_segment failed "$status"
    fi
  fi
  exit "$status"
}

inject_workload_fault() {
  container stop "$resource_identifier" >/dev/null
  record "workload-stop-injected resource=$resource_identifier"
  verify_running
  record "workload-recovered resource=$resource_identifier"
}

inject_daemon_fault() {
  local prior_pid="$daemon_pid"
  stop_daemon
  start_daemon
  verify_running
  [[ "$daemon_pid" != "$prior_pid" ]] || die 'The daemon fault did not produce a fresh process identity.'
  record "daemon-recovered priorPID=$prior_pid currentPID=$daemon_pid"
}

run_fault_cell() {
  local selector="$1"
  local label="$2"
  local log_file="$HOSTWRIGHT_PHASE08_SOAK_ROOT/$label.log"
  (umask 022 && swift test --filter "$selector") > "$log_file" 2>&1
  chmod 600 "$log_file"
  record "$label-pass selector=$selector"
}

export_observability() {
  local metrics="$HOSTWRIGHT_PHASE08_SOAK_ROOT/final-metrics.json"
  local traces="$HOSTWRIGHT_PHASE08_SOAK_ROOT/final-traces.json"
  local preview="$HOSTWRIGHT_PHASE08_SOAK_ROOT/final-support-preview.json"
  "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" metrics snapshot \
    --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" --output json > "$metrics"
  chmod 600 "$metrics"
  "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" metrics export \
    --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" \
    --output-path "$HOSTWRIGHT_PHASE08_SOAK_ROOT/metrics-export-v1.json" \
    --confirm-snapshot "$(/usr/bin/jq -er '.snapshotSHA256' "$metrics")" \
    --output json > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/metrics-export-receipt.json"
  "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" traces inspect --limit 100 \
    --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" --output json > "$traces"
  chmod 600 "$traces"
  local trace_id trace_sha
  trace_id="$(/usr/bin/jq -er '.traces[] | select(.complete == true) | .traceID' "$traces" | head -n 1)"
  trace_sha="$(/usr/bin/jq -er --arg id "$trace_id" '.traces[] | select(.traceID == $id) | .traceSHA256' "$traces")"
  "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" traces export --trace-id "$trace_id" \
    --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" \
    --output-path "$HOSTWRIGHT_PHASE08_SOAK_ROOT/trace-export-v1.json" \
    --confirm-trace "$trace_sha" --output json \
    > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/trace-export-receipt.json"
  "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" diagnostics support preview \
    --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" \
    --project "$project_name" --manifest "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" \
    --output json > "$preview"
  chmod 600 "$preview"
  "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" diagnostics support create \
    --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" \
    --project "$project_name" --manifest "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" \
    --output-path "$HOSTWRIGHT_PHASE08_SOAK_ROOT/support-bundle-v1.json" \
    --confirm-preview "$(/usr/bin/jq -er '.previewSHA256' "$preview")" --output json \
    > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/support-create-receipt.json"
  local bundle_sha
  bundle_sha="$(/usr/bin/jq -er '.outputSHA256' "$HOSTWRIGHT_PHASE08_SOAK_ROOT/support-create-receipt.json")"
  "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" diagnostics support delete \
    --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" \
    --bundle "$HOSTWRIGHT_PHASE08_SOAK_ROOT/support-bundle-v1.json" \
    --confirm-bundle "$bundle_sha" --output json \
    > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/support-delete-receipt.json"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT"/*receipt.json \
    "$HOSTWRIGHT_PHASE08_SOAK_ROOT/metrics-export-v1.json" \
    "$HOSTWRIGHT_PHASE08_SOAK_ROOT/trace-export-v1.json"
}

analyze_samples() {
  local count
  count="$(( $(wc -l < "$sample_file") - 1 ))"
  [[ "$count" -ge "$expected_samples" ]] \
    || die "The soak recorded only $count of $expected_samples required samples."
  awk -F '\t' '
    NR == 1 { next }
    {
      if ($9 > maxFD) maxFD = $9
      if ($10 > maxDB) maxDB = $10
      if ($12 > maxActive) maxActive = $12
      if ($15 > maxRetry) maxRetry = $15
      if (samples == 0) { firstRSS = $8; firstFD = $9; firstDB = $10 }
      if (samples > 0 && $8 < priorRSS) rssDrops++
      if (samples > 0 && $9 < priorFD) fdDrops++
      priorRSS = $8; priorFD = $9
      lastRSS = $8; lastFD = $9; lastDB = $10
      samples++
    }
    END {
      if (samples < 864 || maxFD > 256 || maxDB > 268435456 || maxActive > 1 || maxRetry > 5000) exit 1
      if (rssDrops == 0 && lastRSS > firstRSS + 65536) exit 2
      if (fdDrops == 0 && lastFD > firstFD + 16) exit 3
      if (lastDB > firstDB && lastDB > 134217728) exit 4
    }
  ' "$sample_file" || die 'The soak resource series exceeded a bound or showed monotonic leak behavior.'
}

cleanup_workload() {
  local plan="$HOSTWRIGHT_PHASE08_SOAK_ROOT/final-rm-plan.json"
  local result="$HOSTWRIGHT_PHASE08_SOAK_ROOT/final-rm-result.json"
  "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" rm \
    "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" --dry-run \
    --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" \
    --runtime-provider apple-cli --timeout 300 --output json > "$plan"
  chmod 600 "$plan"
  "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" rm \
    "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" \
    --confirm-plan "$(/usr/bin/jq -er '.planSHA256' "$plan")" \
    --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" \
    --runtime-provider apple-cli --timeout 300 --output json > "$result"
  chmod 600 "$result"
  [[ "$(/usr/bin/jq -er '.status' "$result")" == succeeded \
      && "$(container list --all --format json | /usr/bin/jq --arg id "$resource_identifier" '[.[] | select(.id == $id)] | length')" == 0 ]] \
    || die 'The soak workload did not complete exact owned-only cleanup.'
  require_empty_managed_runtime_inventory
  record "workload-cleanup-pass resource=$resource_identifier"
}

configure_authority_paths() {
  state_file="$HOSTWRIGHT_PHASE08_SOAK_ROOT/state-v2.tsv"
  evidence_file="$HOSTWRIGHT_PHASE08_SOAK_ROOT/evidence-v2.log"
  sample_file="$HOSTWRIGHT_PHASE08_SOAK_ROOT/samples-v2.tsv"
  checkpoint_root="$HOSTWRIGHT_PHASE08_SOAK_ROOT/checkpoints-v1"
  segment_file="$HOSTWRIGHT_PHASE08_SOAK_ROOT/segments-v1.tsv"
  active_run_root="$HOSTWRIGHT_PHASE08_SOAK_ROOT/active-run-v2"
}

initialize_qualification() {
  [[ -z "$(find "$HOSTWRIGHT_PHASE08_SOAK_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || die 'A new cumulative qualification requires one empty private root.' 75
  umask 077
  configure_authority_paths
  mkdir "$checkpoint_root" "$HOSTWRIGHT_PHASE08_SOAK_ROOT/fault-checkpoints-v1"
  chmod 700 "$checkpoint_root" "$HOSTWRIGHT_PHASE08_SOAK_ROOT/fault-checkpoints-v1"
  touch "$evidence_file"
  chmod 600 "$evidence_file"
  durable_sync "$evidence_file" \
    || die 'The initial qualification evidence could not be durably synchronized.' 74
  printf 'segmentID\tevent\tepoch\tsequence\tqualifiedSeconds\tcheckpointSHA256\tdetail1\tdetail2\n' \
    > "$segment_file"
  chmod 600 "$segment_file"
  durable_sync "$segment_file" \
    || die 'The initial segment ledger could not be durably synchronized.' 74
  printf '%b\n' "$checkpoint_header" > "$sample_file"
  chmod 600 "$sample_file"
  durable_sync "$sample_file" \
    || die 'The initial cumulative sample ledger could not be durably synchronized.' 74
  write_manifest 0
  "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" validate "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" \
    > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/manifest-validation.log"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/manifest-validation.log"

  local created_epoch
  created_epoch="$(date +%s)"
  qualification_id="$(new_uuid)"
  source_sha="$(source_digest)"
  hostwright_sha="$(sha256 "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT")"
  daemon_sha="$(sha256 "$HOSTWRIGHT_PHASE08_SOAK_DAEMON")"
  template_sha="$(sha256 "$HOSTWRIGHT_PHASE08_SOAK_CONFIG_TEMPLATE")"
  host_identity_sha="$(current_host_identity)"
  previous_checkpoint_sha256="$genesis_checkpoint_sha256"
  {
    printf 'schemaVersion\t%s\n' "$qualification_schema_version"
    printf 'qualificationID\t%s\n' "$qualification_id"
    printf 'phase\tprepared\n'
    printf 'sourceCommit\t%s\n' "$HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT"
    printf 'sourceDigest\t%s\n' "$source_sha"
    printf 'hostwrightSHA256\t%s\n' "$hostwright_sha"
    printf 'daemonSHA256\t%s\n' "$daemon_sha"
    printf 'templateSHA256\t%s\n' "$template_sha"
    printf 'hostIdentitySHA256\t%s\n' "$host_identity_sha"
    printf 'imageReference\t%s\n' "$HOSTWRIGHT_PHASE08_SOAK_IMAGE"
    printf 'hostPort\t%s\n' "$HOSTWRIGHT_PHASE08_SOAK_HOST_PORT"
    printf 'projectName\t%s\n' "$project_name"
    printf 'createdEpoch\t%s\n' "$created_epoch"
    printf 'expectedSamples\t%s\n' "$expected_samples"
    printf 'requiredQualifiedSeconds\t%s\n' "$duration_seconds"
    printf 'powerEvidenceVersion\t%s\n' "$power_evidence_version"
    printf 'daemonGeneration\t0\n'
    printf 'lastSequence\t0\n'
    printf 'qualifiedSeconds\t0\n'
    printf 'checkpointSHA256\t%s\n' "$previous_checkpoint_sha256"
  } > "$state_file"
  chmod 600 "$state_file"
  durable_sync "$state_file" \
    || die 'The initial qualification state could not be durably synchronized.' 74
  container list --all --format json > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/pre-runtime-inventory.json"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/pre-runtime-inventory.json"
  [[ "$(managed_runtime_count < "$HOSTWRIGHT_PHASE08_SOAK_ROOT/pre-runtime-inventory.json")" == 0 ]] \
    || die 'A Hostwright-managed runtime appeared between qualification validation and startup.' 75
}

prepare_resume() {
  validate_root
  configure_authority_paths
  load_qualification_state
  local phase checkpointed_project
  phase="$(latest_state_value phase)"
  [[ "$phase" == resumable || "$phase" == running || "$phase" == prepared ]] \
    || die 'Only a prepared or resumable cumulative qualification can continue.' 75
  validate_checkpoint_chain
  recover_uncommitted_artifacts
  checkpointed_project="$project_name"
  write_manifest "$cumulative_samples"
  [[ "$project_name" == "$checkpointed_project" ]] \
    || die 'Resume changed the checkpointed project identity.' 75
  if [[ "$cumulative_samples" -gt 0 ]]; then
    [[ "$(sha256 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml")" == "$last_config_sha256" ]] \
      || die 'Resume could not reconstruct the exact last checkpointed configuration.' 75
  fi
  "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" validate "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" \
    > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/manifest-resume-validation.log"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/manifest-resume-validation.log"
  validate_inputs resume
  record "checkpoint-chain-validated sequence=$cumulative_samples qualifiedSeconds=$cumulative_seconds checkpoint=$previous_checkpoint_sha256"
}

run_qualification_segment() {
  trap runner_exit EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  begin_segment
  container list --all --format json \
    > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/segment-${segment_id}-pre-runtime-inventory.json"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/segment-${segment_id}-pre-runtime-inventory.json"
  start_daemon
  verify_running
  record "segment-runtime-ready id=$segment_id project=$project_name resource=$resource_identifier uuid=$resource_uuid"

  local next_sample now sequence
  next_sample=$(( $(date +%s) + sample_interval_seconds ))
  while [[ "$cumulative_samples" -lt "$expected_samples" ]]; do
    now="$(date +%s)"
    if [[ "$now" -lt "$next_sample" ]]; then
      sleep $((next_sample - now))
    fi
    sequence=$((cumulative_samples + 1))
    segment_sample=$((segment_sample + 1))
    churn_configuration "$sequence"
    verify_running
    run_scheduled_faults "$sequence"
    verify_running
    record_sample "$sequence"
    record "sample-checkpoint-committed sequence=$cumulative_samples segment=$segment_id segmentSample=$segment_sample qualifiedSeconds=$cumulative_seconds checkpoint=$previous_checkpoint_sha256"
    next_sample=$((last_sample_epoch + sample_interval_seconds))
  done

  local finish_epoch power_pair sleep_epoch wake_epoch created_epoch
  finish_epoch="$(date +%s)"
  [[ "$cumulative_samples" == "$expected_samples" \
      && "$cumulative_seconds" == "$duration_seconds" ]] \
    || die 'The cumulative qualification ended before its exact duration and sample budget.'
  analyze_samples
  /usr/bin/pmset -g log > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/pmset-final.log"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/pmset-final.log"
  power_pair="$(find_qualified_sleep_wake_pair \
    "$HOSTWRIGHT_PHASE08_SOAK_ROOT/pmset-final.log")" \
    || die 'No ordered timestamp-bound macOS sleep/wake pair occurred inside a qualified segment.'
  sleep_epoch="${power_pair%%$'\t'*}"
  wake_epoch="${power_pair#*$'\t'}"
  append_state sleepEpoch "$sleep_epoch"
  append_state wakeEpoch "$wake_epoch"
  record "sleep-wake-pass sleepEpoch=$sleep_epoch wakeEpoch=$wake_epoch"
  created_epoch="$(latest_state_value createdEpoch)"
  /usr/bin/log show --start "$(date -r "$created_epoch" '+%Y-%m-%d %H:%M:%S')" --style ndjson \
    --predicate "subsystem == \"$subsystem\"" \
    > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/oslog-v2.ndjson"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/oslog-v2.ndjson"
  [[ -s "$HOSTWRIGHT_PHASE08_SOAK_ROOT/oslog-v2.ndjson" ]] \
    || die 'The cumulative qualification OSLog evidence is empty.'
  export_observability
  stop_daemon
  cleanup_workload
  container list --all --format json > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/post-runtime-inventory.json"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/post-runtime-inventory.json"
  close_segment passed 0
  append_state phase passed
  append_state finishEpoch "$finish_epoch"
  append_state samples "$cumulative_samples"
  append_state resource "$resource_identifier"
  find "$HOSTWRIGHT_PHASE08_SOAK_ROOT" -type f ! -name 'evidence-v2.sha256' -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 /usr/bin/shasum -a 256 > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/evidence-v2.sha256"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/evidence-v2.sha256"
  trap - EXIT TERM INT
  printf 'Phase 08 cumulative checkpointed soak qualification passed source=%s seconds=%s samples=%s resource=%s\n' \
    "$source_sha" "$cumulative_seconds" "$cumulative_samples" "$resource_identifier"
}

run_soak() {
  local mode="${1:-new}"
  if [[ "$mode" == new ]]; then
    validate_inputs new
    initialize_qualification
  elif [[ "$mode" == resume ]]; then
    prepare_resume
  else
    die 'The cumulative qualification mode is invalid.' 64
  fi
  run_qualification_segment
}

qualification_status() {
  validate_root
  configure_authority_paths
  load_qualification_state
  validate_checkpoint_chain read-only
  local schema phase samples seconds checkpoint remaining_seconds progress_percent runner_state=none
  schema="$(latest_state_value schemaVersion)"
  phase="$(latest_state_value phase)"
  samples="$cumulative_samples"
  seconds="$cumulative_seconds"
  checkpoint="$previous_checkpoint_sha256"
  [[ "$schema" == "$qualification_schema_version" \
      && "$phase" =~ ^(prepared|running|resumable|passed)$ \
      && "$samples" =~ ^[0-9]+$ \
      && "$seconds" =~ ^[0-9]+$ \
      && "$checkpoint" =~ ^[a-f0-9]{64}$ \
      && "$samples" -le "$expected_samples" \
      && "$seconds" -le "$duration_seconds" ]] \
    || die 'The cumulative qualification status is malformed.' 75
  if [[ -e "$active_run_root" ]]; then
    runner_state=stale
    if private_directory_is_valid "$active_run_root" \
        && private_file_is_valid "$active_run_root/owner-v1.tsv"; then
      local owner_pid owner_boot
      owner_pid="$(awk -F '\t' '$1 == "pid" { print $2 }' "$active_run_root/owner-v1.tsv")"
      owner_boot="$(awk -F '\t' '$1 == "bootIdentity" { print $2 }' "$active_run_root/owner-v1.tsv")"
      if [[ "$owner_pid" =~ ^[1-9][0-9]*$ && "$owner_boot" == "$(boot_identity)" ]] \
          && kill -0 "$owner_pid" 2>/dev/null; then
        runner_state=active
      fi
    fi
  fi
  remaining_seconds=$((duration_seconds - seconds))
  progress_percent="$(awk -v samples="$samples" -v expected="$expected_samples" \
    'BEGIN { printf "%.2f", (samples * 100) / expected }')"
  printf 'Phase 08 cumulative soak status phase=%s runner=%s progressPercent=%s samples=%s/%s qualifiedSeconds=%s/%s remainingSeconds=%s checkpoint=%s\n' \
    "$phase" "$runner_state" "$progress_percent" "$samples" "$expected_samples" "$seconds" "$duration_seconds" \
    "$remaining_seconds" "$checkpoint"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
case "${1:-}" in
  contract)
    [[ "$#" == 1 ]] || die 'Usage: phase08-soak-qualification.sh contract|preflight|run|resume|status' 64
    contract
    ;;
  preflight)
    [[ "$#" == 1 ]] || die 'Usage: phase08-soak-qualification.sh contract|preflight|run|resume|status' 64
    validate_inputs new
    printf 'Phase 08 aggregate soak preflight passed source=%s root=%s\n' \
      "$(source_digest)" "$HOSTWRIGHT_PHASE08_SOAK_ROOT"
    ;;
  run)
    [[ "$#" == 1 ]] || die 'Usage: phase08-soak-qualification.sh contract|preflight|run|resume|status' 64
    run_soak new
    ;;
  resume)
    [[ "$#" == 1 ]] || die 'Usage: phase08-soak-qualification.sh contract|preflight|run|resume|status' 64
    run_soak resume
    ;;
  status)
    [[ "$#" == 1 ]] || die 'Usage: phase08-soak-qualification.sh contract|preflight|run|resume|status' 64
    qualification_status
    ;;
  *)
    die 'Usage: phase08-soak-qualification.sh contract|preflight|run|resume|status' 64
    ;;
esac
fi
