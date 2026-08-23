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
: "${HOSTWRIGHT_XPC_STAGING_ROOT:?HOSTWRIGHT_XPC_STAGING_ROOT is required}"
: "${HOSTWRIGHT_XPC_SOURCE_COMMIT:?HOSTWRIGHT_XPC_SOURCE_COMMIT is required}"
: "${HOSTWRIGHT_XPC_CONFIG_DIGEST:?HOSTWRIGHT_XPC_CONFIG_DIGEST is required}"
readonly live_root="$HOSTWRIGHT_XPC_LIVE_ROOT"
readonly ledger="$HOSTWRIGHT_XPC_OWNERSHIP_LEDGER"
readonly host_bin="$HOSTWRIGHT_XPC_HOST_BIN"
readonly staging_root="$HOSTWRIGHT_XPC_STAGING_ROOT"
readonly source_commit="$HOSTWRIGHT_XPC_SOURCE_COMMIT"
readonly config_digest="$HOSTWRIGHT_XPC_CONFIG_DIGEST"
readonly require_notary="${HOSTWRIGHT_XPC_REQUIRE_NOTARY:-1}"

die() { printf '%s\n' "$1" >&2; exit "${2:-70}"; }
now() { /bin/date -u +%Y-%m-%dT%H:%M:%SZ; }
sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

volume_mount_options() {
  local target="$1" tdev line mnt opts best='' best_opts='' mdev
  tdev="$(/usr/bin/stat -f '%d' "$target")"
  while IFS= read -r line; do
    mnt="$(printf '%s' "$line" | /usr/bin/sed -E 's/^[^ ]+ on (.*) \([^)]*\)$/\1/')"
    opts="$(printf '%s' "$line" | /usr/bin/sed -E 's/^[^ ]+ on .* \((.*)\)$/\1/')"
    [[ -d "$mnt" ]] || continue
    mdev="$(/usr/bin/stat -f '%d' "$mnt" 2>/dev/null)" || continue
    [[ "$mdev" == "$tdev" ]] || continue
    if [[ "${#mnt}" -ge "${#best}" ]]; then best="$mnt"; best_opts="$opts"; fi
  done < <(/sbin/mount)
  printf '%s\n' "$best_opts"
}

validate() {
  local entitlement_json
  [[ "$require_notary" == 0 || "$require_notary" == 1 ]] || die 'HOSTWRIGHT_XPC_REQUIRE_NOTARY must be 0 or 1.' 64
  [[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || die 'The XPC source commit binding is invalid.' 66
  [[ "$config_digest" =~ ^[a-f0-9]{64}$ ]] || die 'The XPC configuration digest binding is invalid.' 66
  [[ -d "$live_root" && ! -L "$live_root" && "$(/bin/realpath "$live_root")" == "$live_root" \
    && "$(/usr/bin/stat -f '%u' "$live_root")" == "$uid" \
    && "$(/usr/bin/stat -f '%Lp' "$live_root")" == 700 ]] || die 'The XPC live root is unsafe.' 66
  [[ -d "$staging_root" && ! -L "$staging_root" && "$(/bin/realpath "$staging_root")" == "$staging_root" \
    && "$(/usr/bin/stat -f '%u' "$staging_root")" == "$uid" \
    && "$(/usr/bin/stat -f '%Lp' "$staging_root")" == 700 \
    && "$staging_root" != "$live_root" && "$staging_root" != "$live_root"/* \
    && "$live_root" != "$staging_root"/* ]] || die 'The XPC staging root is unsafe.' 66
  [[ -z "$(/usr/bin/find "$staging_root" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die 'The XPC staging root must be empty.' 73
  [[ ",$(volume_mount_options "$staging_root")," != *,noowners,* ]] \
    || die 'The XPC staging root volume disables ownership; launchd jobs cannot be staged there.' 87
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

record_staged() {
  local type="$1" identifier="$2" path="$3" identity="${4:-owned=gate11}"
  [[ "$path" == "$staging_root" || "$path" == "$staging_root"/* ]] || die 'Refusing to record a path outside the XPC staging root.'
  [[ -e "$path" && ! -L "$path" ]] || die 'Refusing to record a missing or symlinked XPC staging artifact.'
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
  printf '%s\tlaunchd\t%s\t%s\t%s\t%s\tdomain=%s;sha256=%s;bytes=%s;source_commit=%s;config_digest=%s\n' \
    "$(now)" "$label" "$plist" \
    "$(/usr/bin/stat -f '%d' "$plist")" "$(/usr/bin/stat -f '%i' "$plist")" "$domain" \
    "$(sha "$plist")" "$(/usr/bin/stat -f '%z' "$plist")" "$source_commit" "$config_digest" >> "$ledger"
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
  local label path device inode pid command expected_command_hash actual_command_hash expected_sha
  while IFS=$'\t' read -r label path device inode identity; do
    [[ -f "$path" && ! -L "$path" && "$(/usr/bin/stat -f '%d' "$path")" == "$device" \
      && "$(/usr/bin/stat -f '%i' "$path")" == "$inode" \
      && "$(/usr/bin/stat -f '%Lp' "$path")" == 600 ]] \
      || die 'An owned XPC launchd plist changed; cleanup is frozen.' 124
    expected_sha="$(printf '%s' "$identity" | /usr/bin/sed -E 's/.*sha256=([a-f0-9]{64}).*/\1/')"
    [[ "$(sha "$path")" == "$expected_sha" ]] \
      || die 'An owned XPC launchd plist digest changed; cleanup is frozen.' 124
    /bin/launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    ! /bin/launchctl print "$domain/$label" >/dev/null 2>&1 \
      || die 'An owned XPC launchd job remained loaded; cleanup is frozen.' 124
  done < <(/usr/bin/awk -F $'\t' '$2=="launchd"{print $3"\t"$4"\t"$5"\t"$6"\t"$7}' "$ledger")
  while IFS=$'\t' read -r path device inode pid expected_command_hash; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || die 'An owned XPC process ledger entry is invalid.' 124
    if /bin/kill -0 "$pid" >/dev/null 2>&1; then
      [[ -f "$path" && ! -L "$path" && "$(/usr/bin/stat -f '%d' "$path")" == "$device" \
        && "$(/usr/bin/stat -f '%i' "$path")" == "$inode" ]] \
        || die 'An owned XPC executable changed; cleanup is frozen.' 124
      command="$(/bin/ps -p "$pid" -o command=)"
      actual_command_hash="$(printf '%s' "$command" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
      [[ "$actual_command_hash" == "$expected_command_hash" ]] \
        || die 'An owned XPC PID was reused; cleanup is frozen.' 124
      /bin/kill -TERM "$pid"
      local waited=0
      while /bin/kill -0 "$pid" >/dev/null 2>&1 && [[ "$waited" -lt 50 ]]; do
        /bin/sleep 0.1; waited=$((waited + 1))
      done
      if /bin/kill -0 "$pid" >/dev/null 2>&1; then /bin/kill -KILL "$pid"; fi
      ! /bin/kill -0 "$pid" >/dev/null 2>&1 \
        || die 'An owned XPC process did not terminate; cleanup is frozen.' 124
    fi
  done < <(/usr/bin/awk -F $'\t' '$2=="process"{split($7,a,";"); sub(/^pid=/,"",a[1]); sub(/^command_sha256=/,"",a[2]); print $4"\t"$5"\t"$6"\t"a[1]"\t"a[2]}' "$ledger")
  while IFS=$'\t' read -r path device inode; do
    [[ -e "$path" ]] || continue
    [[ -f "$path" && ! -L "$path" && "$(/usr/bin/stat -f '%d' "$path")" == "$device" \
      && "$(/usr/bin/stat -f '%i' "$path")" == "$inode" ]] || die 'An owned XPC file changed; cleanup is frozen.' 124
    expected_sha="$(/usr/bin/awk -F $'\t' -v p="$path" '$4==p{print $7}' "$ledger" | /usr/bin/sed -E 's/.*sha256=([a-f0-9]{64}).*/\1/')"
    if [[ "$expected_sha" =~ ^[a-f0-9]{64}$ ]]; then
      [[ "$(sha "$path")" == "$expected_sha" ]] \
        || die 'An owned XPC file digest changed before removal; cleanup is frozen.' 124
    fi
    /bin/unlink "$path"
    [[ ! -e "$path" && ! -L "$path" ]] \
      || die 'An owned XPC file survived unlink; cleanup is frozen.' 124
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
  [[ "$(/bin/launchctl print "$domain" 2>/dev/null | /usr/bin/grep -c 'dev\.hostwright\.xpc-provider\.g11\.')" == 0 ]] \
    || die 'A Gate 11 XPC launchd label remained loaded after cleanup.' 124
  [[ -z "$(/usr/bin/find "$staging_root" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || die 'The XPC staging root was not fully cleaned by ledgered removal.' 124
}

on_exit() {
  local status=$?
  trap - EXIT
  cleanup
  exit "$status"
}
trap on_exit EXIT
trap 'exit 124' INT TERM HUP

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
  local staged_job staged_service
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
  staged_job="$staging_root/$name"; /bin/mkdir "$staged_job"; /bin/chmod 700 "$staged_job"
  record_staged temporary-directory "$name" "$staged_job"
  staged_service="$staged_job/hostwright-xpc-provider-service"
  /bin/cp "$service" "$staged_service"; /bin/chmod 500 "$staged_service"
  /usr/bin/codesign --verify --strict "$staged_service" \
    || die "The staged $name XPC service copy failed strict signature verification." 69
  [[ "$(/usr/bin/codesign -d --verbose=4 "$staged_service" 2>&1 | /usr/bin/awk -F= '$1=="Identifier"{print $2}')" == "$service_id" ]] \
    || die "The staged $name XPC service code identity changed during staging." 69
  record_staged temporary-file "$name" "$staged_service" \
    "owned=gate11;sha256=$(sha "$staged_service");bytes=$(/usr/bin/stat -f '%z' "$staged_service");source_commit=$source_commit;config_digest=$config_digest"
  plist="$staged_job/$label.plist"; out="$staged_job/service.stdout"; err="$staged_job/service.stderr"
  /usr/bin/plutil -create xml1 "$plist"
  /usr/libexec/PlistBuddy -c "Add :Label string $label" "$plist"
  /usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$plist"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $staged_service" "$plist"
  /usr/libexec/PlistBuddy -c 'Add :ProgramArguments:1 string --mode' "$plist"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string $mode" "$plist"
  /usr/libexec/PlistBuddy -c 'Add :ProgramArguments:3 string --service-name' "$plist"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string $label" "$plist"
  /usr/libexec/PlistBuddy -c 'Add :MachServices dict' "$plist"
  /usr/libexec/PlistBuddy -c "Add :MachServices:$label bool true" "$plist"
  /usr/libexec/PlistBuddy -c "Add :StandardOutPath string $out" "$plist"
  /usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $err" "$plist"
  /usr/bin/touch "$out" "$err"; /bin/chmod 600 "$plist" "$out" "$err"
  record_staged temporary-file "$name" "$out" "owned=gate11;bytes=$(/usr/bin/stat -f '%z' "$out")"
  record_staged temporary-file "$name" "$err" "owned=gate11;bytes=$(/usr/bin/stat -f '%z' "$err")"
  record_staged temporary-file "$name" "$plist" \
    "owned=gate11;sha256=$(sha "$plist");bytes=$(/usr/bin/stat -f '%z' "$plist");source_commit=$source_commit;config_digest=$config_digest"
  record_launchd "$label" "$plist"
  /bin/launchctl bootstrap "$domain" "$plist"
  "$client" --service-name "$label" --scenario "$scenario"
  record_pid "$label" "$staged_service"
  [[ ! -s "$err" ]] || die "The $name XPC service wrote unexpected diagnostics."
  if [[ "$name" == normal ]]; then
    /bin/launchctl kill SIGKILL "$domain/$label"
    /bin/launchctl kickstart -k "$domain/$label"
    "$client" --service-name "$label" --scenario proof
    record_pid "$label" "$staged_service"
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
