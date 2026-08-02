#!/usr/bin/env bash
set -euo pipefail

readonly duration_seconds=259200
readonly sample_interval_seconds=300
readonly expected_samples=864
readonly uuid_pattern='^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$'
readonly subsystem='dev.hostwright'

daemon_pid=''
daemon_generation=0
resource_identifier=''
project_name=''
state_file=''
evidence_file=''
sample_file=''

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
  printf '%s\n' 'Phase 08 aggregate soak qualification contract v1 is valid.'
  printf '%s\n' 'The qualifying duration is exactly 259200 seconds with 300-second samples.'
  printf '%s\n' 'One foreground daemon, one exact digest-bound workload, and one private schema-v17 database are used.'
  printf '%s\n' 'Configuration churn, bounded pressure, daemon/workload/helper/runtime faults, and all local observability sinks are exercised serially.'
  printf '%s\n' 'A real sleep and wake must occur during the uninterrupted window; the runner never forces either transition.'
  printf '%s\n' 'Failure preserves evidence and exact resource identity; success performs confirmation-bound owned-only cleanup.'
  printf '%s\n' 'No CI, GitHub, network listener, upload, reboot, logout, release, tag, tap, or website action is performed.'
}

sha256() {
  /usr/bin/shasum -a 256 "$1" | awk '{ print $1 }'
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

validate_root() {
  : "${HOSTWRIGHT_PHASE08_SOAK_ROOT:?HOSTWRIGHT_PHASE08_SOAK_ROOT is required}"
  local root_parent root_name user_id
  root_parent="$(dirname "$HOSTWRIGHT_PHASE08_SOAK_ROOT")"
  root_name="$(basename "$HOSTWRIGHT_PHASE08_SOAK_ROOT")"
  user_id="$(id -u)"
  [[ "$root_parent" =~ ^/Volumes/T9/hostwright/qualification/phase08-gate16-[a-f0-9]+$ \
      && "$root_name" =~ ^phase08-soak-${uuid_pattern#^} \
      && -d "$root_parent" && ! -L "$root_parent" \
      && "$(/bin/realpath "$root_parent")" == "$root_parent" \
      && "$(stat -f '%u' "$root_parent")" == "$user_id" \
      && "$(stat -f '%Lp' "$root_parent")" == 700 \
      && -d "$HOSTWRIGHT_PHASE08_SOAK_ROOT" \
      && ! -L "$HOSTWRIGHT_PHASE08_SOAK_ROOT" \
      && "$(/bin/realpath "$HOSTWRIGHT_PHASE08_SOAK_ROOT")" == "$HOSTWRIGHT_PHASE08_SOAK_ROOT" \
      && "$(stat -f '%u' "$HOSTWRIGHT_PHASE08_SOAK_ROOT")" == "$user_id" \
      && "$(stat -f '%Lp' "$HOSTWRIGHT_PHASE08_SOAK_ROOT")" == 700 ]] \
    || die 'The soak root must be one private phase08-soak-<uuid> child of the exact T9 Gate 16 evidence root.' 77
}

validate_inputs() {
  validate_root
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
  for tool in /usr/bin/jq /usr/bin/sqlite3 /usr/sbin/lsof /usr/bin/log /usr/bin/pmset /usr/bin/shasum; do
    [[ -x "$tool" ]] || die "Required soak tool is unavailable: $tool" 69
  done
  [[ "$(container system status)" == *'status             running'* ]] \
    || die 'Apple container is not running.' 69
  local image_digest="${HOSTWRIGHT_PHASE08_SOAK_IMAGE##*@}"
  container image list --format json \
    | /usr/bin/jq -e --arg digest "$image_digest" \
      '[.[] | .variants[] | .digest] | any(. == $digest)' >/dev/null \
    || die 'The exact digest-bound soak image is not already local; pulling is forbidden.' 69
  ! /usr/sbin/lsof -nP -iTCP:"$HOSTWRIGHT_PHASE08_SOAK_HOST_PORT" -sTCP:LISTEN >/dev/null 2>&1 \
    || die 'The selected soak host port is already listening.' 75
}

record() {
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$evidence_file"
  chmod 600 "$evidence_file"
}

pmset_count() {
  local pattern="$1"
  /usr/bin/pmset -g log | grep -c "$pattern" || true
}

write_manifest() {
  local generation="$1"
  local root_uuid next
  root_uuid="${HOSTWRIGHT_PHASE08_SOAK_ROOT##*-soak-}"
  project_name="p08-soak-${root_uuid%%-*}"
  next="$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml.next"
  [[ ! -e "$next" ]] || die 'A stale soak manifest write exists.'
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
}

start_daemon() {
  daemon_generation=$((daemon_generation + 1))
  local log_file="$HOSTWRIGHT_PHASE08_SOAK_ROOT/daemon-${daemon_generation}.log"
  "$HOSTWRIGHT_PHASE08_SOAK_DAEMON" \
    --foreground \
    --config "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" \
    --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" \
    --lock-file "$HOSTWRIGHT_PHASE08_SOAK_ROOT/daemon.lock" \
    --interval 5 --jitter 1 --max-backoff 30 --parallelism 1 \
    > "$log_file" 2>&1 &
  daemon_pid=$!
  chmod 600 "$log_file"
  printf '%s\n' "$daemon_pid" > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/daemon.pid"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/daemon.pid"
  record "daemon-started generation=$daemon_generation pid=$daemon_pid"
}

stop_daemon() {
  if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
    kill -TERM "$daemon_pid"
    local attempt=0
    while kill -0 "$daemon_pid" 2>/dev/null && [[ "$attempt" -lt 30 ]]; do
      sleep 1
      attempt=$((attempt + 1))
    done
    kill -0 "$daemon_pid" 2>/dev/null \
      && die 'The exact foreground daemon did not stop after SIGTERM.'
    wait "$daemon_pid" || true
    record "daemon-stopped generation=$daemon_generation pid=$daemon_pid"
  fi
  daemon_pid=''
}

verify_running() {
  local attempt=0 status_json lifecycle current_identifier
  while [[ "$attempt" -lt 36 ]]; do
    if [[ -n "$daemon_pid" ]] && ! kill -0 "$daemon_pid" 2>/dev/null; then
      die 'The foreground daemon exited before healthy convergence.'
    fi
    if status_json="$("$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" status \
        "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" \
        --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" \
        --runtime-provider apple-cli --output json 2>/dev/null)"; then
      lifecycle="$(printf '%s' "$status_json" | /usr/bin/jq -er '.services[0].observed.lifecycle // empty' 2>/dev/null || true)"
      current_identifier="$(printf '%s' "$status_json" | /usr/bin/jq -er '.services[0].observed.resourceIdentifier // empty' 2>/dev/null || true)"
      if [[ "$lifecycle" == running && -n "$current_identifier" ]]; then
        if [[ -n "$resource_identifier" && "$resource_identifier" != "$current_identifier" ]]; then
          die 'The soak workload identity changed.'
        fi
        resource_identifier="$current_identifier"
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

record_sample() {
  local sequence="$1"
  local sample_root="$HOSTWRIGHT_PHASE08_SOAK_ROOT/current-sample"
  mkdir -p "$sample_root"
  chmod 700 "$sample_root"
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

  local epoch rss_kb descriptors database_bytes operations active_groups events traces retries metrics_series containers oslog_count
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
  containers="$(container list --all --format json | /usr/bin/jq --arg id "$resource_identifier" '[.[] | select(.id == $id)] | length')"
  oslog_count="$(/usr/bin/log show --last 10m --style ndjson --predicate "subsystem == \"$subsystem\"" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$rss_kb" =~ ^[0-9]+$ && "$descriptors" =~ ^[0-9]+$ \
      && "$database_bytes" =~ ^[0-9]+$ && "$operations" =~ ^[0-9]+$ \
      && "$active_groups" =~ ^[0-9]+$ && "$events" =~ ^[0-9]+$ \
      && "$traces" =~ ^[0-9]+$ && "$retries" =~ ^[0-9]+$ \
      && "$metrics_series" == 59 && "$containers" == 1 \
      && "$oslog_count" -gt 0 ]] \
    || die 'A soak sample was incomplete, unbounded, or lost exact runtime/observability identity.'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$sequence" "$epoch" "$daemon_pid" "$rss_kb" "$descriptors" \
    "$database_bytes" "$operations" "$active_groups" "$events" \
    "$traces" "$retries" "$oslog_count" >> "$sample_file"
  chmod 600 "$sample_file"
}

churn_configuration() {
  local sequence="$1"
  local current="$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml"
  local next="$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml.next"
  sed -e '/^# soak-generation=/d' "$current" > "$next"
  printf '# soak-generation=%s\n' "$sequence" >> "$next"
  chmod 600 "$next"
  mv -f "$next" "$current"
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
  local plan="$HOSTWRIGHT_PHASE08_SOAK_ROOT/compaction-plan.json"
  local result="$HOSTWRIGHT_PHASE08_SOAK_ROOT/compaction-result.json"
  "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" state compact \
    "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" --dry-run \
    --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" --output json > "$plan"
  chmod 600 "$plan"
  if [[ "$(/usr/bin/jq -er '.executable' "$plan")" == true ]]; then
    local token
    token="$(/usr/bin/jq -er '.confirmationToken' "$plan")"
    "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" state compact \
      "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" --confirm-compact "$token" \
      --state-db "$HOSTWRIGHT_PHASE08_SOAK_ROOT/state.sqlite" --output json > "$result"
    chmod 600 "$result"
    [[ "$(/usr/bin/jq -er '.integrityHealth' "$result")" == healthy ]] \
      || die 'Confirmed soak compaction did not preserve healthy integrity.'
  fi
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
      if ($5 > maxFD) maxFD = $5
      if ($6 > maxDB) maxDB = $6
      if ($8 > maxActive) maxActive = $8
      if ($11 > maxRetry) maxRetry = $11
      if (samples == 0) { firstRSS = $4; firstFD = $5; firstDB = $6 }
      if (samples > 0 && $4 < priorRSS) rssDrops++
      if (samples > 0 && $5 < priorFD) fdDrops++
      priorRSS = $4; priorFD = $5
      lastRSS = $4; lastFD = $5; lastDB = $6
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
  record "workload-cleanup-pass resource=$resource_identifier"
}

run_soak() {
  validate_inputs
  state_file="$HOSTWRIGHT_PHASE08_SOAK_ROOT/state-v1.tsv"
  evidence_file="$HOSTWRIGHT_PHASE08_SOAK_ROOT/evidence-v1.log"
  sample_file="$HOSTWRIGHT_PHASE08_SOAK_ROOT/samples-v1.tsv"
  [[ -z "$(find "$HOSTWRIGHT_PHASE08_SOAK_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || die 'The soak root must be empty before its one qualifying run.' 75
  umask 077
  mkdir "$HOSTWRIGHT_PHASE08_SOAK_ROOT/active-run-v1"
  trap 'if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then kill -TERM "$daemon_pid" 2>/dev/null || true; fi' EXIT
  touch "$evidence_file"
  chmod 600 "$evidence_file"
  write_manifest 0
  "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT" validate "$HOSTWRIGHT_PHASE08_SOAK_ROOT/hostwright.yaml" \
    > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/manifest-validation.log"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/manifest-validation.log"

  local start_epoch end_epoch source_sha sleep_baseline wake_baseline
  start_epoch="$(date +%s)"
  end_epoch=$((start_epoch + duration_seconds))
  source_sha="$(source_digest)"
  sleep_baseline="$(pmset_count 'Entering Sleep state')"
  wake_baseline="$(pmset_count 'Wake from')"
  {
    printf 'schemaVersion\t1\n'
    printf 'phase\trunning\n'
    printf 'sourceCommit\t%s\n' "$HOSTWRIGHT_PHASE08_SOAK_SOURCE_COMMIT"
    printf 'sourceDigest\t%s\n' "$source_sha"
    printf 'hostwrightSHA256\t%s\n' "$(sha256 "$HOSTWRIGHT_PHASE08_SOAK_HOSTWRIGHT")"
    printf 'daemonSHA256\t%s\n' "$(sha256 "$HOSTWRIGHT_PHASE08_SOAK_DAEMON")"
    printf 'templateSHA256\t%s\n' "$(sha256 "$HOSTWRIGHT_PHASE08_SOAK_CONFIG_TEMPLATE")"
    printf 'startEpoch\t%s\n' "$start_epoch"
    printf 'requiredEndEpoch\t%s\n' "$end_epoch"
    printf 'sleepBaseline\t%s\n' "$sleep_baseline"
    printf 'wakeBaseline\t%s\n' "$wake_baseline"
  } > "$state_file"
  chmod 600 "$state_file"
  printf 'sequence\tepoch\tdaemonPID\trssKB\tfileDescriptors\tdatabaseBytes\toperations\tactiveGroups\tevents\ttraces\tretries\toslog10m\n' > "$sample_file"
  chmod 600 "$sample_file"
  container list --all --format json > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/pre-runtime-inventory.json"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/pre-runtime-inventory.json"

  start_daemon
  verify_running
  record "soak-start source=$source_sha project=$project_name resource=$resource_identifier endEpoch=$end_epoch"

  local sequence=0 next_sample="$start_epoch"
  while [[ "$(date +%s)" -lt "$end_epoch" ]]; do
    local now
    now="$(date +%s)"
    if [[ "$now" -lt "$next_sample" ]]; then
      sleep $((next_sample - now))
    fi
    sequence=$((sequence + 1))
    churn_configuration "$sequence"
    verify_running
    record_sample "$sequence"
    if (( sequence % 12 == 0 )); then
      compact_state
    fi
    if (( sequence % 72 == 0 )); then
      inject_pressure
      inject_workload_fault
    fi
    if (( sequence % 144 == 0 )); then
      inject_daemon_fault
    fi
    if (( sequence == 288 )); then
      run_fault_cell \
        'RuntimeQualificationRecoveryDriverTests.testWriterIsKilledAndFreshExecutableResumesItsDurableCheckpoint' \
        'helper-fault-cell'
    fi
    if (( sequence == 576 )); then
      run_fault_cell \
        'RuntimeQualificationProcessControlTests.testCrashProbeTerminatesTheObservedDescendantTree' \
        'runtime-fault-cell'
    fi
    next_sample=$((start_epoch + sequence * sample_interval_seconds))
  done

  local finish_epoch sleep_after wake_after
  finish_epoch="$(date +%s)"
  [[ "$finish_epoch" -ge "$end_epoch" ]] || die 'The soak clock finished before 72 uninterrupted hours.'
  record_sample $((sequence + 1))
  analyze_samples
  sleep_after="$(pmset_count 'Entering Sleep state')"
  wake_after="$(pmset_count 'Wake from')"
  [[ "$sleep_after" -gt "$sleep_baseline" && "$wake_after" -gt "$wake_baseline" ]] \
    || die 'No real paired macOS sleep/wake occurred during the uninterrupted soak window.'
  /usr/bin/pmset -g log > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/pmset-final.log"
  /usr/bin/log show --start "$(date -r "$start_epoch" '+%Y-%m-%d %H:%M:%S')" --style ndjson \
    --predicate "subsystem == \"$subsystem\"" \
    > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/oslog-v1.ndjson"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/pmset-final.log" \
    "$HOSTWRIGHT_PHASE08_SOAK_ROOT/oslog-v1.ndjson"
  [[ -s "$HOSTWRIGHT_PHASE08_SOAK_ROOT/oslog-v1.ndjson" ]] \
    || die 'The complete soak OSLog evidence is empty.'
  export_observability
  stop_daemon
  cleanup_workload
  container list --all --format json > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/post-runtime-inventory.json"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/post-runtime-inventory.json"
  printf 'phase\tpassed\nfinishEpoch\t%s\nsamples\t%s\nresource\t%s\n' \
    "$finish_epoch" "$((sequence + 1))" "$resource_identifier" >> "$state_file"
  chmod 600 "$state_file"
  find "$HOSTWRIGHT_PHASE08_SOAK_ROOT" -type f ! -name 'evidence-v1.sha256' -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 /usr/bin/shasum -a 256 > "$HOSTWRIGHT_PHASE08_SOAK_ROOT/evidence-v1.sha256"
  chmod 600 "$HOSTWRIGHT_PHASE08_SOAK_ROOT/evidence-v1.sha256"
  rmdir "$HOSTWRIGHT_PHASE08_SOAK_ROOT/active-run-v1"
  trap - EXIT
  printf 'Phase 08 aggregate soak qualification passed source=%s seconds=%s samples=%s resource=%s\n' \
    "$source_sha" "$duration_seconds" "$((sequence + 1))" "$resource_identifier"
}

case "${1:-}" in
  contract)
    [[ "$#" == 1 ]] || die 'Usage: phase08-soak-qualification.sh contract|preflight|run' 64
    contract
    ;;
  preflight)
    [[ "$#" == 1 ]] || die 'Usage: phase08-soak-qualification.sh contract|preflight|run' 64
    validate_inputs
    printf 'Phase 08 aggregate soak preflight passed source=%s root=%s\n' \
      "$(source_digest)" "$HOSTWRIGHT_PHASE08_SOAK_ROOT"
    ;;
  run)
    [[ "$#" == 1 ]] || die 'Usage: phase08-soak-qualification.sh contract|preflight|run' 64
    run_soak
    ;;
  *)
    die 'Usage: phase08-soak-qualification.sh contract|preflight|run' 64
    ;;
esac
