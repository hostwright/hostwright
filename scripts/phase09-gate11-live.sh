#!/bin/bash
set -euo pipefail

readonly signing_identity='Developer ID Application: Dev Trivedi (993YC3JY4Q)'
readonly service_identifier='dev.hostwright.xpc-provider'
readonly entitlement_source='/Users/dev/Documents/hostwright-phase09/scripts/phase09-xpc-provider.entitlements'
readonly uid="$(/usr/bin/id -u)"
readonly domain="gui/$uid"

: "${HOSTWRIGHT_XPC_LIVE_ROOT:?HOSTWRIGHT_XPC_LIVE_ROOT is required}"
: "${HOSTWRIGHT_XPC_OWNERSHIP_LEDGER:?HOSTWRIGHT_XPC_OWNERSHIP_LEDGER is required}"
: "${HOSTWRIGHT_XPC_HOST_BIN:?HOSTWRIGHT_XPC_HOST_BIN is required}"
readonly live_root="$HOSTWRIGHT_XPC_LIVE_ROOT"
readonly ledger="$HOSTWRIGHT_XPC_OWNERSHIP_LEDGER"
readonly host_bin="$HOSTWRIGHT_XPC_HOST_BIN"
readonly require_notary="${HOSTWRIGHT_XPC_REQUIRE_NOTARY:-1}"

die() { printf '%s\n' "$1" >&2; exit "${2:-70}"; }
now() { /bin/date -u +%Y-%m-%dT%H:%M:%SZ; }
sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

validate() {
  local entitlement_json
  [[ "$require_notary" == 0 || "$require_notary" == 1 ]] || die 'HOSTWRIGHT_XPC_REQUIRE_NOTARY must be 0 or 1.' 64
  [[ -d "$live_root" && ! -L "$live_root" && "$(/bin/realpath "$live_root")" == "$live_root" \
    && "$(/usr/bin/stat -f '%u' "$live_root")" == "$uid" \
    && "$(/usr/bin/stat -f '%Lp' "$live_root")" == 700 ]] || die 'The XPC live root is unsafe.' 66
  [[ -f "$ledger" && ! -L "$ledger" && "$(/usr/bin/stat -f '%u' "$ledger")" == "$uid" \
    && "$(/usr/bin/stat -f '%Lp' "$ledger")" == 600 ]] || die 'The XPC ownership ledger is unsafe.' 66
  [[ -x "$host_bin/hostwright-xpc-provider-service" \
    && -x "$host_bin/hostwright-xpc-provider-qualification" ]] || die 'Gate 11 host products are unavailable.' 69
  [[ -f "$entitlement_source" && ! -L "$entitlement_source" ]] || die 'The XPC entitlement file is unavailable.' 69
  entitlement_json="$(/usr/bin/plutil -convert json -o - "$entitlement_source")"
  [[ "$entitlement_json" == '{"com.apple.security.app-sandbox":true}' ]] \
    || die 'The XPC service entitlement set is not the frozen sandbox-only contract.' 78
  [[ -z "$(/usr/bin/find "$live_root" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die 'The XPC live root must be empty.' 73
}

record() {
  local type="$1" identifier="$2" path="$3" identity="${4:-owned=gate11}"
  [[ "$path" == "$live_root" || "$path" == "$live_root"/* ]] || die 'Refusing to record a path outside the XPC live root.'
  [[ -e "$path" && ! -L "$path" ]] || die 'Refusing to record a missing or symlinked XPC artifact.'
  /usr/bin/awk -F $'\t' -v p="$path" '$4==p{found=1}END{exit found?0:1}' "$ledger" && return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$type" "$identifier" "$path" \
    "$(/usr/bin/stat -f '%d' "$path")" "$(/usr/bin/stat -f '%i' "$path")" "$identity" >> "$ledger"
}

record_tree() {
  local root="$1" identifier="$2" path
  while IFS= read -r -d '' path; do record temporary-file "$identifier" "$path"; done \
    < <(/usr/bin/find "$root" -type f -print0)
  while IFS= read -r -d '' path; do record temporary-directory "$identifier" "$path"; done \
    < <(/usr/bin/find "$root" -type d -print0)
}

record_launchd() {
  local label="$1" plist="$2"
  printf '%s\tlaunchd\t%s\t%s\t%s\t%s\tdomain=%s\n' "$(now)" "$label" "$plist" \
    "$(/usr/bin/stat -f '%d' "$plist")" "$(/usr/bin/stat -f '%i' "$plist")" "$domain" >> "$ledger"
}

record_pid() {
  local label="$1" executable="$2" pid command start
  pid="$(/bin/launchctl print "$domain/$label" | /usr/bin/awk '/^[[:space:]]*pid = [0-9]+/{print $3; exit}')"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  command="$(/bin/ps -p "$pid" -o command=)"; start="$(/bin/ps -p "$pid" -o lstart=)"
  printf '%s\tprocess\t%s\t%s\t%s\t%s\tpid=%s;command_sha256=%s;start_sha256=%s\n' \
    "$(now)" "$label" "$executable" "$(/usr/bin/stat -f '%d' "$executable")" \
    "$(/usr/bin/stat -f '%i' "$executable")" "$pid" \
    "$(printf '%s' "$command" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')" \
    "$(printf '%s' "$start" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')" >> "$ledger"
}

cleanup() {
  local label path device inode pid command expected_command_hash actual_command_hash
  while IFS=$'\t' read -r label path device inode; do
    [[ -f "$path" && ! -L "$path" && "$(/usr/bin/stat -f '%d' "$path")" == "$device" \
      && "$(/usr/bin/stat -f '%i' "$path")" == "$inode" ]] \
      || die 'An owned XPC launchd plist changed; cleanup is frozen.' 124
    /bin/launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    ! /bin/launchctl print "$domain/$label" >/dev/null 2>&1 \
      || die 'An owned XPC launchd job remained loaded; cleanup is frozen.' 124
  done < <(/usr/bin/awk -F $'\t' '$2=="launchd"{print $3"\t"$4"\t"$5"\t"$6}' "$ledger")
  while IFS=$'\t' read -r path device inode pid expected_command_hash; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || die 'An owned XPC process ledger entry is invalid.' 124
    /bin/kill -0 "$pid" >/dev/null 2>&1 || continue
    [[ -f "$path" && ! -L "$path" && "$(/usr/bin/stat -f '%d' "$path")" == "$device" \
      && "$(/usr/bin/stat -f '%i' "$path")" == "$inode" ]] \
      || die 'An owned XPC executable changed; cleanup is frozen.' 124
    command="$(/bin/ps -p "$pid" -o command=)"
    actual_command_hash="$(printf '%s' "$command" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
    [[ "$actual_command_hash" == "$expected_command_hash" ]] \
      || die 'An owned XPC PID was reused; cleanup is frozen.' 124
    /bin/kill -TERM "$pid"
  done < <(/usr/bin/awk -F $'\t' '$2=="process"{split($7,a,";"); sub(/^pid=/,"",a[1]); sub(/^command_sha256=/,"",a[2]); print $4"\t"$5"\t"$6"\t"a[1]"\t"a[2]}' "$ledger")
  while IFS=$'\t' read -r path device inode; do
    [[ -e "$path" ]] || continue
    [[ -f "$path" && ! -L "$path" && "$(/usr/bin/stat -f '%d' "$path")" == "$device" \
      && "$(/usr/bin/stat -f '%i' "$path")" == "$inode" ]] || die 'An owned XPC file changed; cleanup is frozen.' 124
    /bin/unlink "$path"
  done < <(/usr/bin/awk -F $'\t' '$2=="temporary-file"{print length($4)"\t"$4"\t"$5"\t"$6}' "$ledger" \
    | /usr/bin/sort -rn | /usr/bin/cut -f2-)
  while IFS=$'\t' read -r path device inode; do
    [[ -e "$path" ]] || continue
    [[ -d "$path" && ! -L "$path" && "$(/usr/bin/stat -f '%d' "$path")" == "$device" \
      && "$(/usr/bin/stat -f '%i' "$path")" == "$inode" ]] || die 'An owned XPC directory changed; cleanup is frozen.' 124
    /bin/rmdir "$path"
  done < <(/usr/bin/awk -F $'\t' '$2=="temporary-directory"{print length($4)"\t"$4"\t"$5"\t"$6}' "$ledger" \
    | /usr/bin/sort -rn | /usr/bin/cut -f2-)
  while IFS=$'\t' read -r path device inode; do
    [[ -e "$path" ]] || continue
    [[ -d "$path" && ! -L "$path" && "$(/usr/bin/stat -f '%d' "$path")" == "$device" \
      && "$(/usr/bin/stat -f '%i' "$path")" == "$inode" ]] || die 'The owned XPC live root changed; cleanup is frozen.' 124
    /bin/rmdir "$path"
  done < <(/usr/bin/awk -F $'\t' '$2=="temporary-root"{print $4"\t"$5"\t"$6}' "$ledger")
}

on_exit() {
  local status=$?
  trap - EXIT
  cleanup
  exit "$status"
}
trap on_exit EXIT

create_info() {
  local path="$1" identifier="$2" executable="$3" package_type="$4"
  /usr/bin/plutil -create xml1 "$path"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$identifier" "$path"
  /usr/bin/plutil -insert CFBundleExecutable -string "$executable" "$path"
  /usr/bin/plutil -insert CFBundlePackageType -string "$package_type" "$path"
  /usr/bin/plutil -insert CFBundleVersion -string 1 "$path"
  /usr/bin/plutil -insert CFBundleShortVersionString -string 1.0 "$path"
}

create_job() {
  local name="$1" mode="$2" service_signing="$3" service_id="$4" entitlements="$5" client_id="$6"
  local scenario="$7" label job app contents macos client xpc xpc_contents xpc_macos service info plist out err signing_entitlements
  label="dev.hostwright.xpc-provider.g11.$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
  job="$live_root/$name"; /bin/mkdir "$job"; /bin/chmod 700 "$job"; record temporary-directory "$name" "$job"
  app="$job/HostwrightXPCQualification.app"; contents="$app/Contents"; macos="$contents/MacOS"
  xpc="$contents/XPCServices/dev.hostwright.xpc-provider.xpc"; xpc_contents="$xpc/Contents"; xpc_macos="$xpc_contents/MacOS"
  /bin/mkdir -p "$macos" "$xpc_macos"
  client="$macos/hostwright-xpc-provider-qualification"
  service="$xpc_macos/hostwright-xpc-provider-service"
  /bin/cp "$host_bin/hostwright-xpc-provider-qualification" "$client"
  /bin/cp "$host_bin/hostwright-xpc-provider-service" "$service"
  /bin/chmod 500 "$client" "$service"
  info="$xpc_contents/Info.plist"; create_info "$info" "$service_id" hostwright-xpc-provider-service 'XPC!'
  /usr/bin/plutil -insert XPCService -json '{"ServiceType":"Application"}' "$info"
  signing_entitlements="$entitlement_source"
  if [[ "$entitlements" == over-entitled ]]; then
    signing_entitlements="$job/over-entitled.plist"
    /usr/bin/plutil -create xml1 "$signing_entitlements"
    /bin/chmod 600 "$signing_entitlements"
    record temporary-file "$name" "$signing_entitlements"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$signing_entitlements"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.network.client bool true' "$signing_entitlements"
  fi
  if [[ "$service_signing" == adhoc ]]; then
    /usr/bin/codesign --force --options runtime --sign - --identifier "$service_id" "$xpc"
  elif [[ "$entitlements" == sandbox || "$entitlements" == over-entitled ]]; then
    /usr/bin/codesign --force --options runtime --timestamp --sign "$signing_identity" \
      --identifier "$service_id" --entitlements "$signing_entitlements" "$xpc"
  else
    /usr/bin/codesign --force --options runtime --timestamp --sign "$signing_identity" \
      --identifier "$service_id" "$xpc"
  fi
  create_info "$contents/Info.plist" "dev.hostwright.xpc-qualification.$name" \
    hostwright-xpc-provider-qualification 'APPL'
  /usr/bin/codesign --force --options runtime --timestamp --sign "$signing_identity" \
    --identifier "$client_id" "$app"
  record_tree "$app" "$name"
  plist="$job/$label.plist"; out="$job/service.stdout"; err="$job/service.stderr"
  /usr/bin/plutil -create xml1 "$plist"
  /usr/libexec/PlistBuddy -c "Add :Label string $label" "$plist"
  /usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$plist"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $service" "$plist"
  /usr/libexec/PlistBuddy -c 'Add :ProgramArguments:1 string --mode' "$plist"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string $mode" "$plist"
  /usr/libexec/PlistBuddy -c 'Add :ProgramArguments:3 string --service-name' "$plist"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string $label" "$plist"
  /usr/libexec/PlistBuddy -c 'Add :MachServices dict' "$plist"
  /usr/libexec/PlistBuddy -c "Add :MachServices:$label bool true" "$plist"
  /usr/libexec/PlistBuddy -c "Add :StandardOutPath string $out" "$plist"
  /usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $err" "$plist"
  /usr/bin/touch "$out" "$err"; /bin/chmod 600 "$plist" "$out" "$err"
  record temporary-file "$name" "$plist"; record temporary-file "$name" "$out"; record temporary-file "$name" "$err"
  record_launchd "$label" "$plist"
  /bin/launchctl bootstrap "$domain" "$plist"
  "$client" --service-name "$label" --scenario "$scenario"
  record_pid "$label" "$service"
  [[ ! -s "$err" ]] || die "The $name XPC service wrote unexpected diagnostics."
  if [[ "$name" == normal ]]; then
    /bin/launchctl kill SIGKILL "$domain/$label"
    /bin/launchctl kickstart -k "$domain/$label"
    "$client" --service-name "$label" --scenario proof
    record_pid "$label" "$service"
  fi
  /bin/launchctl bootout "$domain/$label"
  ! /bin/launchctl print "$domain/$label" >/dev/null 2>&1 || die 'Owned XPC launchd cleanup did not converge.' 124
  if [[ "$name" == normal ]]; then printf '%s\n' "$app" > "$live_root/notary-app-path"; record temporary-file notary "$live_root/notary-app-path"; fi
}

validate
record temporary-root gate11-xpc-live "$live_root"
create_job normal normal developer "$service_identifier" sandbox hostwrightd proof
create_job hang-timeout hang developer "$service_identifier" sandbox hostwrightd timeout
create_job hang-cancel hang developer "$service_identifier" sandbox hostwrightd cancel
create_job hang-revoke hang developer "$service_identifier" sandbox hostwrightd revoke
create_job malformed malformed developer "$service_identifier" sandbox hostwrightd malformed
create_job oversized oversized developer "$service_identifier" sandbox hostwrightd oversized
create_job crash crash developer "$service_identifier" sandbox hostwrightd unavailable
create_job wrong-identifier normal developer "$service_identifier.wrong" sandbox hostwrightd authentication
create_job wrong-entitlement normal developer "$service_identifier" none hostwrightd authentication
create_job over-entitled normal developer "$service_identifier" over-entitled hostwrightd authentication
create_job over-entitled-malformed malformed developer "$service_identifier" over-entitled hostwrightd authentication
create_job wrong-team normal adhoc "$service_identifier" none hostwrightd authentication
create_job wrong-client normal developer "$service_identifier" sandbox hostwrightd.wrong unavailable

if [[ "$require_notary" == 1 ]]; then
  : "${HOSTWRIGHT_NOTARY_PROFILE:?HOSTWRIGHT_NOTARY_PROFILE is required for Gate 11 notarization}"
  normal_app="$(/bin/cat "$live_root/notary-app-path")"
  archive="$live_root/HostwrightXPCQualification.zip"
  /usr/bin/ditto -c -k --keepParent "$normal_app" "$archive"; /bin/chmod 600 "$archive"
  record temporary-file notary "$archive"
  xcrun notarytool submit "$archive" --keychain-profile "$HOSTWRIGHT_NOTARY_PROFILE" --wait
  xcrun stapler staple "$normal_app"
  xcrun stapler validate "$normal_app"
  /usr/bin/spctl --assess --type execute --verbose=2 "$normal_app"
fi

printf '%s\n' 'Gate 11 signed XPC live qualification passed.'
