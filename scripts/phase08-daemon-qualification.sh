#!/usr/bin/env bash
set -euo pipefail

readonly managed_label="dev.hostwright.daemon"
readonly homebrew_label="homebrew.mxcl.hostwright"
readonly user_id="$(id -u)"
readonly managed_target="gui/${user_id}/${managed_label}"
readonly homebrew_target="gui/${user_id}/${homebrew_label}"
readonly uuid_pattern='^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$'

die() {
  printf '%s\n' "$1" >&2
  exit "${2:-70}"
}

usage() {
  cat <<'EOF'
Usage:
  scripts/phase08-daemon-qualification.sh contract
  scripts/phase08-daemon-qualification.sh prepare
  scripts/phase08-daemon-qualification.sh resume-reboot
  scripts/phase08-daemon-qualification.sh resume-login
  scripts/phase08-daemon-qualification.sh cleanup

Required environment for every action except contract:
  HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT  Pre-created empty mode-0700 direct child of
                                         ~/Library/Application Support/Hostwright/qualification
                                         named phase08-gate1-<canonical-uuid>
  HOSTWRIGHT_PHASE08_HOSTWRIGHT          Exact absolute built hostwright path
  HOSTWRIGHT_PHASE08_DAEMON              Exact absolute built hostwrightd path
  HOSTWRIGHT_PHASE08_CONFIG              Exact absolute qualification config path

Re-export the same four values after reboot or logout/login before a resume action.
EOF
  exit 64
}

validate_host() {
  [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] \
    || die "Phase 08 daemon qualification requires macOS on Apple silicon." 69
  [[ -x /bin/launchctl && -x /usr/bin/shasum && -x /usr/sbin/sysctl ]] \
    || die "Required macOS qualification tools are unavailable." 69
  command -v python3 >/dev/null \
    || die "Python 3 is required to validate structured status." 69
}

require_canonical_file() {
  local name="$1"
  local path="${!name:-}"
  [[ "$path" == /* && "$path" != *$'\n'* && -f "$path" && ! -L "$path" ]] \
    || die "$name must name one absolute regular non-symlink file." 66
  [[ "$(/bin/realpath "$path")" == "$path" ]] \
    || die "$name must already be canonical." 66
}

validate_inputs() {
  local account_home qualification_parent root_parent root_name
  : "${HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT:?HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT is required}"
  account_home="$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
  qualification_parent="${account_home}/Library/Application Support/Hostwright/qualification"
  root_parent="$(dirname "$HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT")"
  root_name="$(basename "$HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT")"
  [[ -d "$qualification_parent" && ! -L "$qualification_parent" \
      && "$(/bin/realpath "$qualification_parent")" == "$qualification_parent" \
      && "$(stat -f '%u' "$qualification_parent")" == "$user_id" \
      && "$(stat -f '%Lp' "$qualification_parent")" == 700 ]] \
    || die "The persistent Phase 08 qualification parent must be canonical, current-user-owned, and mode 0700." 77
  [[ "$root_parent" == "$qualification_parent" \
      && "$root_name" =~ ^phase08-gate1-${uuid_pattern#^} ]] \
    || die "The Phase 08 qualification root must be a persistent phase08-gate1-<canonical-uuid> directory under the private Hostwright qualification parent." 66
  [[ "$HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT" == /* \
      && "$HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT" != / \
      && "$HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT" != *$'\n'* \
      && -d "$HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT" \
      && ! -L "$HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT" ]] \
    || die "The Phase 08 qualification root must be one safe absolute directory." 66
  [[ "$(/bin/realpath "$HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT")" \
      == "$HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT" \
      && "$(stat -f '%u' "$HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT")" == "$user_id" \
      && "$(stat -f '%Lp' "$HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT")" == 700 ]] \
    || die "The Phase 08 qualification root must be canonical, current-user-owned, and mode 0700." 77
  require_canonical_file HOSTWRIGHT_PHASE08_HOSTWRIGHT
  require_canonical_file HOSTWRIGHT_PHASE08_DAEMON
  require_canonical_file HOSTWRIGHT_PHASE08_CONFIG
  [[ -x "$HOSTWRIGHT_PHASE08_HOSTWRIGHT" && -x "$HOSTWRIGHT_PHASE08_DAEMON" \
      && "${HOSTWRIGHT_PHASE08_HOSTWRIGHT##*/}" == hostwright \
      && "${HOSTWRIGHT_PHASE08_DAEMON##*/}" == hostwrightd ]] \
    || die "Qualification executables must be executable and have exact Hostwright names." 66
}

state_file=""
evidence_file=""

bind_paths() {
  state_file="$HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT/state-v1"
  evidence_file="$HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT/evidence-v1.log"
  for path in "$state_file" "$evidence_file"; do
    if [[ -e "$path" ]]; then
      [[ -f "$path" && ! -L "$path" \
          && "$(stat -f '%u' "$path")" == "$user_id" \
          && "$(stat -f '%Lp' "$path")" == 600 ]] \
        || die "Qualification state or evidence ownership changed." 70
    fi
  done
}

sha256() {
  /usr/bin/shasum -a 256 "$1" | awk '{ print $1 }'
}

boot_epoch() {
  local record
  record="$(/usr/sbin/sysctl -n kern.boottime)"
  [[ "$record" =~ sec[[:space:]]*=[[:space:]]*([0-9]+),[[:space:]]*usec[[:space:]]*=[[:space:]]*([0-9]+) ]] \
    || die "The kernel boot identity is unavailable." 69
  printf '%s-%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

login_session_handle() {
  local handle
  handle="$(/bin/launchctl print "gui/${user_id}" | awk '$1 == "handle" && $2 == "=" { print $3; exit }')"
  [[ "$handle" =~ ^[0-9]+$ ]] || die "The current GUI login-session handle is unavailable." 69
  printf '%s\n' "$handle"
}

json_value() {
  local document="$1"
  local path="$2"
  python3 -c '
import json
import sys
value = json.loads(sys.argv[2])
for component in sys.argv[1].split("."):
    value = value[component]
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
' "$path" "$document"
}

record() {
  umask 077
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$evidence_file"
  chmod 600 "$evidence_file"
}

write_state() {
  local phase="$1"
  local boot="$2"
  local session_handle="$3"
  local process_id="$4"
  local installation_id="$5"
  local next="${state_file}.next"
  [[ "$phase" == preparing || "$phase" == reboot-required || "$phase" == logout-required ]] \
    || die "Invalid Phase 08 qualification phase."
  [[ "$boot" =~ ^[0-9]+-[0-9]{1,6}$ && "$session_handle" =~ ^[0-9]+$ \
      && "$process_id" =~ ^(0|[1-9][0-9]*)$ \
      && ( "$installation_id" == none || "$installation_id" =~ $uuid_pattern ) ]] \
    || die "Invalid Phase 08 qualification identity."
  [[ ! -e "$next" ]] || die "A stale qualification state write exists."
  umask 077
  {
    printf 'schemaVersion=1\n'
    printf 'phase=%s\n' "$phase"
    printf 'bootEpoch=%s\n' "$boot"
    printf 'sessionHandle=%s\n' "$session_handle"
    printf 'processID=%s\n' "$process_id"
    printf 'installationID=%s\n' "$installation_id"
    printf 'hostwrightPath=%s\n' "$HOSTWRIGHT_PHASE08_HOSTWRIGHT"
    printf 'hostwrightSHA256=%s\n' "$(sha256 "$HOSTWRIGHT_PHASE08_HOSTWRIGHT")"
    printf 'daemonPath=%s\n' "$HOSTWRIGHT_PHASE08_DAEMON"
    printf 'daemonSHA256=%s\n' "$(sha256 "$HOSTWRIGHT_PHASE08_DAEMON")"
    printf 'configPath=%s\n' "$HOSTWRIGHT_PHASE08_CONFIG"
    printf 'configSHA256=%s\n' "$(sha256 "$HOSTWRIGHT_PHASE08_CONFIG")"
  } > "$next"
  chmod 600 "$next"
  mv -f "$next" "$state_file"
}

state_value() {
  local key="$1"
  local value
  value="$(awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2) }' "$state_file")"
  [[ -n "$value" && "$(grep -c "^${key}=" "$state_file")" == 1 ]] \
    || die "Qualification state is missing $key."
  printf '%s\n' "$value"
}

load_and_verify_state() {
  [[ -f "$state_file" && ! -L "$state_file" \
      && "$(wc -l < "$state_file" | tr -d ' ')" == 12 \
      && "$(state_value schemaVersion)" == 1 ]] \
    || die "No valid resumable Phase 08 qualification state exists." 66
  [[ "$(state_value hostwrightPath)" == "$HOSTWRIGHT_PHASE08_HOSTWRIGHT" \
      && "$(state_value hostwrightSHA256)" == "$(sha256 "$HOSTWRIGHT_PHASE08_HOSTWRIGHT")" \
      && "$(state_value daemonPath)" == "$HOSTWRIGHT_PHASE08_DAEMON" \
      && "$(state_value daemonSHA256)" == "$(sha256 "$HOSTWRIGHT_PHASE08_DAEMON")" \
      && "$(state_value configPath)" == "$HOSTWRIGHT_PHASE08_CONFIG" \
      && "$(state_value configSHA256)" == "$(sha256 "$HOSTWRIGHT_PHASE08_CONFIG")" ]] \
    || die "Qualification inputs changed across the attended boundary."
}

status_json() {
  "$HOSTWRIGHT_PHASE08_HOSTWRIGHT" daemon status --json
}

verify_running_identity() {
  local document="$1"
  local expected_installation="$2"
  [[ "$(json_value "$document" status.readiness)" == running \
      && "$(json_value "$document" status.installationID)" == "$expected_installation" \
      && "$(json_value "$document" status.daemonExecutablePath)" == "$HOSTWRIGHT_PHASE08_DAEMON" \
      && "$(json_value "$document" status.configPath)" == "$HOSTWRIGHT_PHASE08_CONFIG" \
      && "$(json_value "$document" status.generation)" == 1 ]] \
    || die "The managed daemon no longer matches the exact qualification identity."
}

prepare() {
  [[ ! -e "$state_file" && ! -e "$evidence_file" \
      && -z "$(find "$HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || die "The Phase 08 qualification root must be empty before prepare."
  /bin/launchctl print "$homebrew_target" >/dev/null 2>&1 \
    && die "The Homebrew Hostwright service must be absent." \
    || true
  local before result boot session_handle installation_id process_id
  before="$(status_json)"
  [[ "$(json_value "$before" status.readiness)" == not-installed ]] \
    || die "The managed LaunchAgent must be absent before prepare."
  ! /usr/bin/pgrep -x hostwrightd >/dev/null 2>&1 \
    || die "An unmanaged hostwrightd process blocks qualification."
  boot="$(boot_epoch)"
  session_handle="$(login_session_handle)"
  write_state preparing "$boot" "$session_handle" 0 none
  record "prepare-intent boot=${boot} session=${session_handle}"
  result="$("$HOSTWRIGHT_PHASE08_HOSTWRIGHT" daemon install \
    --daemon-executable "$HOSTWRIGHT_PHASE08_DAEMON" \
    --config "$HOSTWRIGHT_PHASE08_CONFIG" --json)"
  installation_id="$(json_value "$result" status.installationID)"
  process_id="$(json_value "$result" status.processID)"
  verify_running_identity "$result" "$installation_id"
  write_state reboot-required "$boot" "$session_handle" "$process_id" "$installation_id"
  record "prepare-passed installation=${installation_id} pid=${process_id} boot=${boot} session=${session_handle}"
  printf 'Gate 1 prepare passed. Reboot this attended Mac, then run resume-reboot.\n'
}

resume_reboot() {
  load_and_verify_state
  [[ "$(state_value phase)" == reboot-required ]] \
    || die "Qualification is not waiting for reboot."
  local previous_boot previous_session previous_pid current_boot current_session document installation_id process_id
  previous_boot="$(state_value bootEpoch)"
  previous_session="$(state_value sessionHandle)"
  previous_pid="$(state_value processID)"
  current_boot="$(boot_epoch)"
  current_session="$(login_session_handle)"
  [[ "$current_boot" != "$previous_boot" && "$current_session" != "$previous_session" ]] \
    || die "A real reboot and new GUI login session have not occurred."
  document="$(status_json)"
  installation_id="$(state_value installationID)"
  verify_running_identity "$document" "$installation_id"
  process_id="$(json_value "$document" status.processID)"
  [[ "$process_id" != "$previous_pid" ]] \
    || die "The daemon process did not restart across reboot."
  write_state logout-required "$current_boot" "$current_session" "$process_id" "$installation_id"
  record "reboot-passed installation=${installation_id} pid=${process_id} boot=${current_boot} session=${current_session}"
  printf 'Reboot proof passed. Log out and back in without rebooting, then run resume-login.\n'
}

resume_login() {
  load_and_verify_state
  [[ "$(state_value phase)" == logout-required ]] \
    || die "Qualification is not waiting for logout/login."
  local recorded_boot recorded_session recorded_pid current_boot current_session document installation_id process_id result
  recorded_boot="$(state_value bootEpoch)"
  recorded_session="$(state_value sessionHandle)"
  recorded_pid="$(state_value processID)"
  current_boot="$(boot_epoch)"
  current_session="$(login_session_handle)"
  [[ "$current_boot" == "$recorded_boot" && "$current_session" != "$recorded_session" ]] \
    || die "A distinct logout/login session without another reboot has not occurred."
  document="$(status_json)"
  installation_id="$(state_value installationID)"
  verify_running_identity "$document" "$installation_id"
  process_id="$(json_value "$document" status.processID)"
  [[ "$process_id" != "$recorded_pid" ]] \
    || die "The daemon process did not restart across logout/login."
  record "logout-login-passed installation=${installation_id} pid=${process_id} boot=${current_boot} session=${current_session}"
  result="$("$HOSTWRIGHT_PHASE08_HOSTWRIGHT" daemon uninstall --json)"
  [[ "$(json_value "$result" status.readiness)" == not-installed \
      && "$(json_value "$result" reasonCode)" == daemon.uninstalled ]] \
    || die "Final daemon uninstall did not report exact completion."
  /bin/launchctl print "$managed_target" >/dev/null 2>&1 \
    && die "The managed launchd target remained after uninstall." \
    || true
  ! /usr/bin/pgrep -x hostwrightd >/dev/null 2>&1 \
    || die "A hostwrightd process remained after uninstall."
  record "qualification-passed-and-lifecycle-cleaned installation=${installation_id}"
  rm -f "$state_file"
  printf 'Phase 08 Gate 1 reboot and logout/login qualification passed.\n'
}

cleanup() {
  load_and_verify_state
  local document expected_installation readiness current_installation current_daemon current_config
  document="$(status_json)"
  expected_installation="$(state_value installationID)"
  readiness="$(json_value "$document" status.readiness)"
  if [[ "$readiness" != not-installed ]]; then
    current_installation="$(json_value "$document" status.installationID)"
    current_daemon="$(json_value "$document" status.daemonExecutablePath)"
    current_config="$(json_value "$document" status.configPath)"
    if [[ "$expected_installation" == none ]]; then
      [[ "$current_daemon" == "$HOSTWRIGHT_PHASE08_DAEMON" \
          && "$current_config" == "$HOSTWRIGHT_PHASE08_CONFIG" ]] \
        || die "Cleanup refuses an installation outside its durable preparing intent."
    else
      [[ "$current_installation" == "$expected_installation" ]] \
        || die "Cleanup refuses a different managed daemon installation."
    fi
    "$HOSTWRIGHT_PHASE08_HOSTWRIGHT" daemon uninstall --json >/dev/null
  fi
  /bin/launchctl print "$managed_target" >/dev/null 2>&1 \
    && die "The managed target remained after cleanup." \
    || true
  ! /usr/bin/pgrep -x hostwrightd >/dev/null 2>&1 \
    || die "A daemon process remained after cleanup."
  record "qualified-installation-cleanup-completed installation=${expected_installation}"
  rm -f "$state_file"
  printf 'Phase 08 Gate 1 qualified installation cleanup passed.\n'
}

action="${1:-}"
[[ $# == 1 ]] || usage
if [[ "$action" == contract ]]; then
  printf 'Phase 08 daemon qualification contract v1 is valid; boot identity %s.\n' \
    "$(boot_epoch)"
  exit 0
fi

validate_host
validate_inputs
bind_paths

case "$action" in
  prepare) prepare ;;
  resume-reboot) resume_reboot ;;
  resume-login) resume_login ;;
  cleanup) cleanup ;;
  *) usage ;;
esac
