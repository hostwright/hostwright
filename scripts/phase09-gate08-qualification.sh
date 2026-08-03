#!/usr/bin/env bash
set -euo pipefail

readonly schema='hostwright.phase09.gate08.qualification.manifest.v1'
readonly gate=8 readonly_branch='feat/v0.0.2-phase-09'
readonly live_parent='/Volumes/T9/hostwright/qualification'
readonly signing_fingerprint='A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB'
readonly signing_identity='Developer ID Application: Dev Trivedi (993YC3JY4Q)'
readonly signing_identifier='hostwright-control'
readonly daemon_signing_identifier='hostwrightd'
readonly pinned_image='docker.io/library/python@sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92'
readonly pinned_image_digest='sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92'
readonly state_header=$'gate\tcell\tstatus\tsource_digest\tconfig_digest\ttoolchain_digest\tstarted_at\tfinished_at\tstdout_sha256\tstderr_sha256'
readonly ownership_header=$'recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity'
root='' parent='' source_digest_value='' config_digest_value='' toolchain_digest_value='' source_commit=''
root_lock_created=0 gate_lock_created=0 run_succeeded=0
live_runtime='' live_daemon_pid='' live_daemon_path='' live_container=''

die(){ printf '%s\n' "$1" >&2; exit "${2:-70}"; }
now(){ /bin/date -u +%Y-%m-%dT%H:%M:%SZ; }
sha(){ /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
stream_sha(){ /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'; }
testing(){ [[ "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" == 1 ]]; }

contract(){ cat <<'EOF'
Phase 09 Gate 8 qualification harness contract v1
Gate 8 — 50.00% — streams, watches, backpressure, and recovery (#197).
Exactly one Gate 8 qualification may be active. Cells 1..6 run strictly serially.
Focused U/I/L/M/S/R evidence covers the strict stream state machine, authenticated multiplexing,
signed subject-bound cursors, durable watches, backpressure/cancellation, a signed qualification
tool plus one owned pinned Apple-container runtime probe, schema-v20 compatibility, adversarial
cursor/session/resource cases, daemon restart, and recovery. Failed evidence is immutable;
passing evidence is reused cryptographically.
Only ledgered current-user-owned live artifacts are removed after inode/device revalidation.
Exact Gate 8 Keychain service/account pairs are ledgered, deleted after daemon shutdown, and
verified absent before the owned runtime root is removed.
EOF
}

qualification_parent(){ if testing; then : "${HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT:?test parent required}"; printf '%s\n' "$HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT"; else printf '%s\n' "$live_parent"; fi; }
validate_worktree(){ [[ "$(git branch --show-current)" == "$readonly_branch" ]] || die "Gate 8 requires branch $readonly_branch." 66; local top; top="$(/bin/realpath "$(git rev-parse --show-toplevel)")"; [[ "$top" == /Users/dev/Documents/hostwright-phase09 ]] || die 'Gate 8 requires the isolated Phase 09 worktree.' 66; }
validate_root(){ : "${HOSTWRIGHT_PHASE09_GATE_ROOT:?HOSTWRIGHT_PHASE09_GATE_ROOT is required}"; root="$HOSTWRIGHT_PHASE09_GATE_ROOT"; parent="$(qualification_parent)"; local canonical; canonical="$(/bin/realpath "$parent")"; [[ -d "$parent" && ! -L "$parent" && "$canonical" == "$parent" ]] || die 'qualification parent must be canonical and non-symlinked.' 66; if testing; then [[ "$canonical" == /private/var/folders/*/T/hostwright-phase09-harness-* || "$canonical" == /var/folders/*/T/hostwright-phase09-harness-* ]] || die 'test parent must be isolated.' 66; else [[ "$canonical" == "$live_parent" ]] || die 'Gate 8 evidence must use the fixed qualification parent.' 66; fi; [[ "$root" == /* && -d "$root" && ! -L "$root" && "$(/bin/realpath "$root")" == "$root" && "$(/bin/realpath "$(dirname "$root")")" == "$canonical" ]] || die 'evidence root is unsafe.' 66; [[ "${root##*/}" =~ ^phase09-gate08-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || die 'evidence root name is not a Gate 8 lowercase UUID.' 66; [[ "$(stat -f '%u' "$root")" == "$(id -u)" && "$(stat -f '%Lp' "$root")" == 700 ]] || die 'evidence root must be current-user-owned and mode 0700.' 66; parent="$canonical"; }
empty_root(){ [[ -z "$(/usr/bin/find "$root" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die 'prepare requires an empty evidence root.' 73; }
source_digest(){ { git rev-parse HEAD; git diff --binary HEAD -- . ':(exclude)tmp'; while IFS= read -r -d '' p; do [[ "$p" == tmp/* || "$p" == .codex/* || "$p" == .claude/* ]] && continue; printf '%s\0' "$p"; /usr/bin/shasum -a 256 "$p"; done < <(git ls-files --others --exclude-standard -z | LC_ALL=C /usr/bin/sort -z); } | stream_sha; }
toolchain(){ { /usr/bin/sw_vers; xcodebuild -version; swift --version; container --version; xcrun --find codesign; security find-identity -p codesigning -v; } 2>&1; }
cell_command(){ case "$1" in
1) printf '%s\n' "swift test --filter 'ControlStreamFrameContractTests|ControlStreamSessionStateTests|ControlStreamCursorTests'";;
2) printf '%s\n' "swift test --filter 'PersistentControlStreamIntegrationTests|DaemonControlStreamSourcesTests|DaemonControlStreamAuthorizationPipelineTests|ControlIdentitySecurityAdapterTests|RBACAuthorizationEngineTests/testStreamAuthorizationMapsWatchAndExecuteToExactProjectAndResourceScopes'";;
3) printf '%s\n' 'signed hostwright-stream-qualification plus one owned pinned Apple-container workload';;
4) printf '%s\n' "swift test --filter 'EventStreamTests|StateUpgradeTests|ControlStreamCursorTests'";;
5) printf '%s\n' "swift test --filter 'ControlStreamCursorTests|ControlStreamFrameContractTests|PersistentControlStreamIntegrationTests/testInactiveSessionClosesTheActiveStreamConnection|DaemonControlStreamSourcesTests/testRejectsCrossSubjectCursorAndInvalidFilters|DaemonControlStreamAuthorizationPipelineTests/testAdmissionMutationEffectiveDenialIsAuditedBeforeFailClosedWithoutPersistence|DaemonControlStreamAuthorizationPipelineTests/testAuditFailureIsDegradedForReadStreamAndFailClosedForInteractiveStream'";;
6) printf '%s\n' "swift test --filter 'PersistentControlStreamIntegrationTests|PersistentControlAuditIntegrationTests|PersistentControlAdmissionIntegrationTests|DaemonControlStreamSourcesTests|DaemonControlStreamAuthorizationPipelineTests|HostwrightDaemonControlServiceTests|WorkloadProfileControlOperationsTests|ContainerizationHelperInteractiveExecutorTests|Phase09Gate08QualificationHarnessTests'; swift build --product hostwrightd; swift build --product hostwright-control; swift build --product hostwright-stream-qualification; scripts/lint.sh; git diff --check; scripts/check-docs.sh";; *) die 'unknown Gate 8 cell.' 70;; esac; }
classes(){ case "$1" in 1) printf '%s\n' '["U"]';;2) printf '%s\n' '["I"]';;3) printf '%s\n' '["L","I"]';;4) printf '%s\n' '["M"]';;5) printf '%s\n' '["S"]';;6) printf '%s\n' '["R","I"]';;*) die 'unknown evidence class.';;esac; }
config_digest(){ { sha "$0"; sha scripts/lint.sh; sha scripts/check-docs.sh; local n; for n in 1 2 3 4 5 6; do cell_command "$n"; classes "$n"; done; } | stream_sha; }
collect(){ source_commit="$(git rev-parse HEAD)"; source_digest_value="$(source_digest)"; config_digest_value="$(config_digest)"; toolchain_digest_value="$(toolchain | stream_sha)"; if ! testing; then [[ -z "$(git status --porcelain --untracked-files=all -- . ':(exclude)tmp')" ]] || die 'Gate 8 qualification requires a clean committed branch.' 73; fi; }
revalidate_dependencies(){ [[ "$(git rev-parse HEAD)" == "$source_commit" && "$(source_digest)" == "$source_digest_value" && "$(config_digest)" == "$config_digest_value" && "$(toolchain | stream_sha)" == "$toolchain_digest_value" ]] || die 'Gate 8 evidence dependencies changed during qualification; progress is frozen.' 73; }
cell_timeout(){ case "$1" in 3) printf '%s\n' 900;; 6) printf '%s\n' 1800;; *) printf '%s\n' 1200;; esac; }
cells_json(){ local n; for n in 1 2 3 4 5 6; do /usr/bin/jq -n --argjson cell "$n" --arg command "$(cell_command "$n")" --argjson evidenceClasses "$(classes "$n")" '{cell:$cell,command:$command,evidenceClasses:$evidenceClasses}'; done | /usr/bin/jq -s .; }
prepare(){ printf '%s\n' "$ownership_header" > "$root/ownership-v1.tsv"; printf '%s\n' "$state_header" > "$root/state-v1.tsv"; toolchain > "$root/toolchain-v1.txt"; /usr/bin/jq -n --arg schema "$schema" --argjson gate "$gate" --arg sourceCommit "$source_commit" --arg sourceDigest "$source_digest_value" --arg configDigest "$config_digest_value" --arg toolchainDigest "$toolchain_digest_value" --arg startedAt "$(now)" --argjson evidenceByCell "$(cells_json)" '{schema:$schema,gate:$gate,sourceCommit:$sourceCommit,sourceDigest:$sourceDigest,configDigest:$configDigest,toolchainDigest:$toolchainDigest,cellOrder:[1,2,3,4,5,6],evidenceByCell:$evidenceByCell,startedAt:$startedAt,completedAt:null,status:"prepared"}' > "$root/manifest-v1.json"; chmod 600 "$root"/*; }
prepared(){ local f; for f in manifest-v1.json ownership-v1.tsv state-v1.tsv toolchain-v1.txt; do [[ -f "$root/$f" && ! -L "$root/$f" ]] || die 'run requires a complete prepared evidence root.' 73; done; [[ "$(head -n 1 "$root/ownership-v1.tsv")" == "$ownership_header" && "$(head -n 1 "$root/state-v1.tsv")" == "$state_header" ]] || die 'prepared evidence headers are invalid.' 73; [[ "$(/usr/bin/jq -r .schema "$root/manifest-v1.json")" == "$schema" && "$(/usr/bin/jq -r .gate "$root/manifest-v1.json")" == "$gate" && "$(/usr/bin/jq -r .sourceDigest "$root/manifest-v1.json")" == "$source_digest_value" && "$(/usr/bin/jq -r .configDigest "$root/manifest-v1.json")" == "$config_digest_value" && "$(/usr/bin/jq -r .toolchainDigest "$root/manifest-v1.json")" == "$toolchain_digest_value" ]] || die 'prepared evidence dependencies changed; preserve this root.' 73; }
short_live_runtime(){ local suffix="${root##*/phase09-gate08-}"; printf '%s/.p09g8-%s\n' "$parent" "${suffix:0:17}"; }
record_root(){ local runtime="$1" expected; expected="$(short_live_runtime)"; [[ "$runtime" == "$expected" && "$(dirname "$runtime")" == "$parent" && -d "$runtime" && ! -L "$runtime" && "$(/bin/realpath "$runtime")" == "$runtime" && "$(stat -f '%u' "$runtime")" == "$(id -u)" && "$(stat -f '%Lp' "$runtime")" == 700 ]] || die 'live runtime root is unsafe.'; printf '%s\ttemporary-root\tgate08-live-runtime\t%s\t%s\t%s\tpath=%s;scope=gate08-live\n' "$(now)" "$runtime" "$(stat -f '%d' "$runtime")" "$(stat -f '%i' "$runtime")" "${runtime##*/}" >> "$root/ownership-v1.tsv"; }
record_artifact(){ local runtime="$1" p="$2" kind n="${2##*/}"; [[ "$p" == "$runtime"/* && ! -L "$p" && "$(stat -f '%u' "$p")" == "$(id -u)" ]] || die 'live artifact is not owned.'; if [[ -d "$p" ]]; then kind=temporary-directory; elif [[ -f "$p" ]]; then kind=temporary-file; elif [[ -S "$p" ]]; then kind=temporary-socket; else die 'live runtime contains an unsupported artifact type.'; fi; /usr/bin/awk -F $'\t' -v p="$p" '$4==p&&$2~/^temporary-/{n++}END{exit n?1:0}' "$root/ownership-v1.tsv" || return 0; printf '%s\t%s\t%s\t%s\t%s\t%s\tname=%s;scope=gate08-live\n' "$(now)" "$kind" "$n" "$p" "$(stat -f '%d' "$p")" "$(stat -f '%i' "$p")" "$n" >> "$root/ownership-v1.tsv"; }
inventory(){ local runtime="$1" p; while IFS= read -r -d '' p; do record_artifact "$runtime" "$p"; done < <(/usr/bin/find "$runtime" -mindepth 1 -print0); [[ -x "$runtime/signed-stream-tool" && -x "$runtime/signed-hostwrightd" && -f "$runtime/app-support/state/state.sqlite" ]] || die 'live inventory is incomplete.'; }
cleanup_live(){ local runtime="$1" line path d i root_path root_device root_inode; line="$(/usr/bin/awk -F $'\t' '$2=="temporary-root"&&$3=="gate08-live-runtime"{print $4"\t"$5"\t"$6}' "$root/ownership-v1.tsv")"; [[ -n "$line" && "$line" != *$'\n'* ]] || die 'live root ledger entry is missing or duplicated.'; IFS=$'\t' read -r root_path root_device root_inode <<< "$line"; [[ "$root_path" == "$runtime" && -d "$runtime" && ! -L "$runtime" && "$(stat -f '%d' "$runtime")" == "$root_device" && "$(stat -f '%i' "$runtime")" == "$root_inode" ]] || die 'live root identity changed; cleanup is refused.'; while IFS=$'\t' read -r path d i; do [[ "$path" == "$runtime"/* && ! -L "$path" && ! -d "$path" && "$(stat -f '%d' "$path")" == "$d" && "$(stat -f '%i' "$path")" == "$i" ]] || die 'live artifact identity changed; cleanup is refused.'; /bin/unlink "$path"; done < <(/usr/bin/awk -F $'\t' '$2=="temporary-file"||$2=="temporary-socket"{print $4"\t"$5"\t"$6}' "$root/ownership-v1.tsv"); while IFS=$'\t' read -r path d i; do [[ "$path" == "$runtime"/* && -d "$path" && ! -L "$path" && "$(stat -f '%d' "$path")" == "$d" && "$(stat -f '%i' "$path")" == "$i" ]] || die 'live directory identity changed; cleanup is refused.'; /bin/rmdir "$path"; done < <(/usr/bin/awk -F $'\t' '$2=="temporary-directory"{print length($4)"\t"$4"\t"$5"\t"$6}' "$root/ownership-v1.tsv" | /usr/bin/sort -rn | /usr/bin/cut -f2-); /bin/rmdir "$runtime"; }
record_process(){ local pid="$1" executable="$2" generation="$3" command start; kill -0 "$pid" 2>/dev/null || die 'owned daemon process is not alive.'; command="$(ps -p "$pid" -o command=)"; start="$(ps -p "$pid" -o lstart=)"; [[ -n "$command" && -n "$start" && "${command%% *}" == "$executable" ]] || die 'owned daemon process identity is incomplete.'; printf '%s\tprocess\thostwrightd-%s\t%s\t%s\t%s\tpid=%s;command_sha256=%s;start_sha256=%s;scope=gate08-live\n' "$(now)" "$generation" "$executable" "$(stat -f '%d' "$executable")" "$(stat -f '%i' "$executable")" "$pid" "$(printf '%s' "$command"|stream_sha)" "$(printf '%s' "$start"|stream_sha)" >> "$root/ownership-v1.tsv"; }
record_container(){ local resource="$1"; [[ "$resource" =~ ^hostwright-v2-[a-z0-9-]+$ && "${#resource}" -le 128 ]] || die 'Gate 8 live container identifier is unsafe.'; container list --all --format json | /usr/bin/jq -e --arg id "$resource" --arg digest "$pinned_image_digest" 'any(.[]; .id==$id and .configuration.image.descriptor.digest==$digest and .configuration.labels["dev.hostwright.project"]=="phase09-gate08-live" and .configuration.labels["dev.hostwright.service"]=="probe")' >/dev/null || die 'Gate 8 container identity is not exact.'; printf '%s\tcontainer-resource\t%s\t\t\t\timage=%s;project=phase09-gate08-live;service=probe;scope=gate08-live\n' "$(now)" "$resource" "$pinned_image_digest" >> "$root/ownership-v1.tsv"; }
keychain_namespace(){ printf '%s' "$1" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print substr($1,1,32)}'; }
record_keychain_item(){
  local service="$1" account="$2" attributes status
  [[ "$service" =~ ^dev\.hostwright\.(audit|stream-cursor)\.v1\.[a-f0-9]{32}$ ]] || die 'Gate 8 Keychain service is unsafe.'
  [[ "$account" == active-key-id || "$account" == chain-head-v1 || "$account" =~ ^signing-key:p256:[a-f0-9]{64}$ ]] || die 'Gate 8 Keychain account is unsafe.'
  if attributes="$(/usr/bin/security find-generic-password -s "$service" -a "$account" 2>&1)"; then
    :
  else
    status=$?
    [[ "$status" == 44 ]] && return 0
    die 'Gate 8 Keychain inventory failed.'
  fi
  printf '%s' "$attributes" | /usr/bin/grep -F '"gena"<blob>="hostwright-audit-owned-v1"' >/dev/null || die 'Gate 8 Keychain ownership marker changed.'
  printf '%s' "$attributes" | /usr/bin/grep -F '"acct"<blob>="'"$account"'"' >/dev/null || die 'Gate 8 Keychain account changed.'
  printf '%s' "$attributes" | /usr/bin/grep -F '"svce"<blob>="'"$service"'"' >/dev/null || die 'Gate 8 Keychain service changed.'
  /usr/bin/awk -F $'\t' -v s="$service" -v a="$account" '$2=="keychain-item"&&$7=="service="s";account="a";marker=hostwright-audit-owned-v1;scope=gate08-live"{n++}END{exit n?0:1}' "$root/ownership-v1.tsv" && return 0
  printf '%s\tkeychain-item\t%s/%s\t\t\t\tservice=%s;account=%s;marker=hostwright-audit-owned-v1;scope=gate08-live\n' "$(now)" "$service" "$account" "$service" "$account" >> "$root/ownership-v1.tsv"
}
record_keychain_items(){
  local runtime="$1" state="$2" namespace audit_service cursor_service key_id token prefix payload signature extra padded decoded
  [[ "$state" == "$runtime"/* && -f "$state" && ! -L "$state" && "$(stat -f '%u' "$state")" == "$(id -u)" ]] || die 'Gate 8 state database is unsafe for Keychain inventory.'
  namespace="$(keychain_namespace "$state")"
  audit_service="dev.hostwright.audit.v1.$namespace"
  cursor_service="dev.hostwright.stream-cursor.v1.$namespace"
  while IFS= read -r key_id; do
    [[ "$key_id" =~ ^p256:[a-f0-9]{64}$ ]] || die 'Gate 8 audit key identifier is unsafe.'
    record_keychain_item "$audit_service" "signing-key:$key_id"
  done < <(/usr/bin/sqlite3 "$state" 'SELECT key_id FROM audit_key_metadata ORDER BY generation;' 2>/dev/null || true)
  record_keychain_item "$audit_service" active-key-id
  record_keychain_item "$audit_service" chain-head-v1
  if [[ -f "$runtime/resume-cursor.txt" && ! -L "$runtime/resume-cursor.txt" ]]; then
    token="$(/bin/cat "$runtime/resume-cursor.txt")"
    IFS=. read -r prefix payload signature extra <<< "$token"
    [[ "$prefix" == hwsc1 && -z "$extra" && -n "$payload" && ${#payload} -le 8192 && -n "$signature" && ${#signature} -le 512 && "$payload" =~ ^[A-Za-z0-9_-]+$ && "$signature" =~ ^[A-Za-z0-9_-]+$ ]] || die 'Gate 8 cursor token is unsafe for Keychain inventory.'
    padded="$(printf '%s' "$payload" | /usr/bin/tr '_-' '/+')"
    while (( ${#padded} % 4 != 0 )); do padded="${padded}="; done
    decoded="$(printf '%s' "$padded" | /usr/bin/base64 -D 2>/dev/null)" || die 'Gate 8 cursor token did not decode.'
    key_id="$(printf '%s' "$decoded" | /usr/bin/jq -er '.keyID | select(test("^p256:[a-f0-9]{64}$"))')" || die 'Gate 8 cursor key identifier is unsafe.'
    record_keychain_item "$cursor_service" "signing-key:$key_id"
    record_keychain_item "$cursor_service" active-key-id
    record_keychain_item "$cursor_service" chain-head-v1
  fi
}
require_keychain_absent(){
  local service="$1" account="${2:-}" status
  if [[ -n "$account" ]]; then
    if /usr/bin/security find-generic-password -s "$service" -a "$account" >/dev/null 2>&1; then
      die 'Gate 8 Keychain item remained after cleanup.'
    else status=$?; fi
  else
    if /usr/bin/security find-generic-password -s "$service" >/dev/null 2>&1; then
      die 'Unledgered Gate 8 Keychain items remain.'
    else status=$?; fi
  fi
  [[ "$status" == 44 ]] || die 'Gate 8 Keychain absence verification failed.'
}
cleanup_keychain_items(){
  local runtime="$1" state="$2" expected_namespace expected_audit expected_cursor identity service account attributes
  [[ "$state" == "$runtime"/* && -f "$state" && ! -L "$state" && "$(stat -f '%u' "$state")" == "$(id -u)" ]] || die 'Gate 8 state database is unsafe for Keychain cleanup.'
  expected_namespace="$(keychain_namespace "$state")"
  expected_audit="dev.hostwright.audit.v1.$expected_namespace"
  expected_cursor="dev.hostwright.stream-cursor.v1.$expected_namespace"
  while IFS=$'\t' read -r identity; do
    service="${identity#service=}"; service="${service%%;*}"
    account="${identity#*account=}"; account="${account%%;*}"
    [[ "$service" == "$expected_audit" || "$service" == "$expected_cursor" ]] || die 'Gate 8 Keychain ledger service changed.'
    [[ "$account" == active-key-id || "$account" == chain-head-v1 || "$account" =~ ^signing-key:p256:[a-f0-9]{64}$ ]] || die 'Gate 8 Keychain ledger account changed.'
    attributes="$(/usr/bin/security find-generic-password -s "$service" -a "$account" 2>&1)" || die 'A ledgered Gate 8 Keychain item disappeared before cleanup.'
    printf '%s' "$attributes" | /usr/bin/grep -F '"gena"<blob>="hostwright-audit-owned-v1"' >/dev/null || die 'Gate 8 Keychain ownership changed before cleanup.'
    /usr/bin/security delete-generic-password -s "$service" -a "$account" >/dev/null 2>&1 || die 'Gate 8 Keychain item cleanup failed.'
    require_keychain_absent "$service" "$account"
  done < <(/usr/bin/awk -F $'\t' '$2=="keychain-item"{print $7}' "$root/ownership-v1.tsv")
  require_keychain_absent "$expected_audit"
  require_keychain_absent "$expected_cursor"
}
start_daemon(){ local runtime="$1" daemon="$2" config="$3" state="$4" generation="$5"; HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$runtime/app-support" HOSTWRIGHT_CACHE_DIR="$runtime/cache" HOSTWRIGHT_LOG_DIR="$runtime/logs" "$daemon" --foreground --config "$config" --state-db "$state" --interval 5 --jitter 0 --parallelism 1 >"$runtime/daemon-$generation.stdout.log" 2>"$runtime/daemon-$generation.stderr.log" & daemon_pid=$!; record_process "$daemon_pid" "$daemon" "$generation"; local n socket="$runtime/app-support/run/control-v2.sock"; for n in {1..240}; do [[ -S "$socket" ]] && return 0; kill -0 "$daemon_pid" 2>/dev/null || die 'owned daemon exited before publishing its socket.'; /bin/sleep 0.25; done; die 'owned daemon did not publish its socket before the deadline.' 124; }
stop_daemon(){ local pid="$1" n; kill -TERM "$pid" 2>/dev/null || true; for n in {1..120}; do kill -0 "$pid" 2>/dev/null || { wait "$pid" || true; return 0; }; /bin/sleep 0.25; done; die 'owned daemon did not stop before the deadline.' 124; }
wait_owned_container(){ local n matches; for n in {1..360}; do matches="$(container list --all --format json | /usr/bin/jq -r --arg digest "$pinned_image_digest" '[.[]|select(.configuration.image.descriptor.digest==$digest and .configuration.labels["dev.hostwright.project"]=="phase09-gate08-live" and .configuration.labels["dev.hostwright.service"]=="probe")|.id]|if length==1 then .[0] elif length==0 then "" else error("ambiguous") end')" || die 'Gate 8 container discovery was ambiguous.'; if [[ -n "$matches" ]]; then live_container="$matches"; record_container "$live_container"; return 0; fi; /bin/sleep 0.25; done; die 'owned Gate 8 container was not observed before the deadline.' 124; }
terminate_cell_group(){ local pgid="$1" n; kill -TERM -- "-$pgid" 2>/dev/null || return 0; for n in {1..50}; do kill -0 -- "-$pgid" 2>/dev/null || return 0; /bin/sleep 0.1; done; kill -KILL -- "-$pgid" 2>/dev/null || true; }
emergency_live_cleanup(){
  [[ -n "$root" && -f "$root/ownership-v1.tsv" ]] || return 0
  local cleanup_status=0 path device inode identity pid command command_sha start start_sha n runtime state resource container_present
  runtime="$(/usr/bin/awk -F $'\t' '$2=="temporary-root"&&$3=="gate08-live-runtime"{print $4}' "$root/ownership-v1.tsv")"
  [[ -n "$runtime" && "$runtime" != *$'\n'* && "$runtime" == "$(short_live_runtime)" ]] || return 0
  while IFS=$'\t' read -r path device inode identity; do
    pid="${identity#pid=}"; pid="${pid%%;*}"
    command_sha="${identity#*command_sha256=}"; command_sha="${command_sha%%;*}"
    start_sha="${identity#*start_sha256=}"; start_sha="${start_sha%%;*}"
    [[ "$pid" =~ ^[1-9][0-9]*$ && -f "$path" && ! -L "$path" && "$(stat -f '%d' "$path" 2>/dev/null)" == "$device" && "$(stat -f '%i' "$path" 2>/dev/null)" == "$inode" ]] || { cleanup_status=1; continue; }
    if kill -0 "$pid" 2>/dev/null; then
      command="$(ps -p "$pid" -o command= 2>/dev/null)"; start="$(ps -p "$pid" -o lstart= 2>/dev/null)"
      [[ "${command%% *}" == "$path" && "$(printf '%s' "$command"|stream_sha)" == "$command_sha" && "$(printf '%s' "$start"|stream_sha)" == "$start_sha" ]] || { cleanup_status=1; continue; }
      kill -TERM "$pid" 2>/dev/null || true
      for n in {1..50}; do kill -0 "$pid" 2>/dev/null || break; /bin/sleep 0.1; done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
      kill -0 "$pid" 2>/dev/null && cleanup_status=1
    fi
  done < <(/usr/bin/awk -F $'\t' '$2=="process"{print $4"\t"$5"\t"$6"\t"$7}' "$root/ownership-v1.tsv")
  [[ "$cleanup_status" == 0 ]] || return "$cleanup_status"
  resource="$(/usr/bin/awk -F $'\t' '$2=="container-resource"{print $3}' "$root/ownership-v1.tsv")"
  if [[ -n "$resource" && "$resource" != *$'\n'* ]]; then
    container_present="$(container list --all --format json | /usr/bin/jq -r --arg id "$resource" --arg digest "$pinned_image_digest" 'if any(.[]; .id==$id) then (if any(.[]; .id==$id and .configuration.image.descriptor.digest==$digest and .configuration.labels["dev.hostwright.project"]=="phase09-gate08-live" and .configuration.labels["dev.hostwright.service"]=="probe") then "yes" else error("identity") end) else "no" end')" || return 1
    [[ "$container_present" == no ]] || container delete --force "$resource" >/dev/null 2>&1 || cleanup_status=1
    container list --all --format json 2>/dev/null | /usr/bin/jq -e --arg id "$resource" 'all(.[]; .id!=$id)' >/dev/null 2>&1 || cleanup_status=1
  fi
  [[ "$cleanup_status" == 0 ]] || return "$cleanup_status"
  if [[ -n "$runtime" && "$runtime" != *$'\n'* && -d "$runtime" && ! -L "$runtime" ]]; then
    state="$runtime/app-support/state/state.sqlite"
    if [[ -f "$state" ]]; then
      record_keychain_items "$runtime" "$state" || cleanup_status=1
      [[ "$cleanup_status" == 0 ]] && cleanup_keychain_items "$runtime" "$state" || cleanup_status=1
    fi
    [[ "$cleanup_status" == 0 ]] || return "$cleanup_status"
    ( while IFS= read -r -d '' path; do record_artifact "$runtime" "$path"; done < <(/usr/bin/find "$runtime" -mindepth 1 -print0); cleanup_live "$runtime" ) || cleanup_status=1
  fi
  return "$cleanup_status"
}
on_exit(){ local status=$?; trap - EXIT; emergency_live_cleanup || true; release || true; exit "$status"; }
forced_live_failure_for_testing(){
  local runtime resource='hostwright-v2-p09-test-live' child_pid executable
  runtime="$(short_live_runtime)"
  mkdir "$runtime"; chmod 700 "$runtime"; record_root "$runtime"
  mkdir "$runtime/app-support"; chmod 700 "$runtime/app-support"
  executable="$runtime/signed-hostwrightd"; /bin/cp /bin/sleep "$executable"; chmod 700 "$executable"
  "$executable" 300 & child_pid=$!
  record_process "$child_pid" "$executable" testing
  container phase09-test-create "$resource"
  record_container "$resource"
  return 47
}
live(){ swift build --product hostwright-stream-qualification; swift build --product hostwrightd; local bin tool daemon runtime signed signed_daemon config state socket result resume status team canonical resource; bin="$(swift build --show-bin-path)"; tool="$bin/hostwright-stream-qualification"; daemon="$bin/hostwrightd"; [[ -x "$tool" && -x "$daemon" ]] || die 'Gate 8 live products were not built.'; container image list --format json | /usr/bin/jq -e --arg image "$pinned_image" --arg digest "$pinned_image_digest" 'any(.[]; .configuration.name==$image and .configuration.descriptor.digest==$digest)' >/dev/null || die 'the exact pinned Gate 8 image is not local; no pull is permitted.' 69; runtime="$(short_live_runtime)"; live_runtime="$runtime"; mkdir "$runtime"; chmod 700 "$runtime"; record_root "$runtime"; mkdir "$runtime/app-support" "$runtime/cache" "$runtime/logs"; chmod 700 "$runtime/app-support" "$runtime/cache" "$runtime/logs"; signed="$runtime/signed-stream-tool"; signed_daemon="$runtime/signed-hostwrightd"; live_daemon_path="$signed_daemon"; /bin/cp "$tool" "$signed"; /bin/cp "$daemon" "$signed_daemon"; codesign --force --sign "$signing_fingerprint" --identifier "$signing_identifier" "$signed"; codesign --force --sign "$signing_fingerprint" --identifier "$daemon_signing_identifier" "$signed_daemon"; codesign --verify --strict "$signed"; codesign --verify --strict "$signed_daemon"; team="$(codesign -d --verbose=4 "$signed" 2>&1|/usr/bin/awk -F= '$1=="TeamIdentifier"{print $2}')"; [[ "$team" == 993YC3JY4Q ]] || die 'signed live tool has the wrong team.'; config="$runtime/hostwright.yaml"; /bin/cp /dev/null "$config"; printf '%s\n' 'version: 2' 'project: phase09-gate08-live' 'imagePolicy: require-digest' 'services:' '  probe:' "    image: $pinned_image" '    command: ["python3", "-c", "import time; print(\"hostwright-gate08-log\", flush=True); time.sleep(600)"]' > "$config"; chmod 600 "$config"; state="$runtime/app-support/state/state.sqlite"; socket="$runtime/app-support/run/control-v2.sock"; (( ${#socket} < 104 )) || die 'the Gate 8 control socket exceeds the macOS Unix-domain path limit.' 66; "$signed" --bootstrap --root "$runtime" --state "$state" --socket "$socket"; start_daemon "$runtime" "$signed_daemon" "$config" "$state" 1; live_daemon_pid="$daemon_pid"; wait_owned_container; set +e; result="$("$signed" --live --root "$runtime" --state "$state" --socket "$socket")"; status=$?; set -e; [[ "$status" == 0 ]] || die 'stream live qualification failed.' "$status"; [[ -n "$result" && "${#result}" -le 1048576 ]] || die 'stream live qualification output is invalid.' 70; canonical="$(printf '%s' "$result"|/usr/bin/jq -cS .)"; [[ "$canonical" == "$result" ]] || die 'live result is not canonical JSON.'; printf '%s' "$result" | /usr/bin/jq -e '.kind=="hostwright.phase09.stream.live-qualification.v1" and .stateSchemaVersion==20 and .integrityHealth=="healthy" and .eventBackpressureRecovered==true and .heartbeatWhileCreditExhausted==true and .metricsWatchCompleted==true and .logsStreamCompleted==true and .execStreamCompleted==true and .fullDuplexInputAcknowledged==true and .fullDuplexEchoVerified==true and .cancellationTerminalObserved==true and .cancellationDurabilityVerified==true' >/dev/null || die 'live result assertions failed.' 70; resource="$(printf '%s' "$result" | /usr/bin/jq -r .resourceIdentifier)"; [[ "$resource" == "$live_container" ]] || die 'live result container identity changed.'; stop_daemon "$daemon_pid"; live_daemon_pid=''; start_daemon "$runtime" "$signed_daemon" "$config" "$state" 2; live_daemon_pid="$daemon_pid"; set +e; resume="$("$signed" --resume --root "$runtime" --state "$state" --socket "$socket")"; status=$?; set -e; if [[ "$status" != 0 ]]; then /bin/cat "$runtime/daemon-2.stdout.log" >&2; /bin/cat "$runtime/daemon-2.stderr.log" >&2; die 'stream resume qualification failed.' "$status"; fi; canonical="$(printf '%s' "$resume"|/usr/bin/jq -cS .)"; [[ "$canonical" == "$resume" ]] || die 'resume result is not canonical JSON.'; printf '%s' "$resume" | /usr/bin/jq -e '.kind=="hostwright.phase09.stream.resume-qualification.v1" and .resumedWithoutDuplicate==true and .daemonRestartCursorAccepted==true and .integrityHealth=="healthy"' >/dev/null || die 'resume result assertions failed.' 70; record_keychain_items "$runtime" "$state"; stop_daemon "$daemon_pid"; live_daemon_pid=''; container delete --force "$resource"; live_container=''; container list --all --format json | /usr/bin/jq -e --arg id "$resource" 'all(.[]; .id!=$id)' >/dev/null || die 'owned Gate 8 container cleanup failed.'; cleanup_keychain_items "$runtime" "$state"; inventory "$runtime"; printf '%s\n%s\n' "$result" "$resume"; cleanup_live "$runtime"; live_runtime=''; }
run_cell(){ case "$1" in 1) swift test --filter 'ControlStreamFrameContractTests|ControlStreamSessionStateTests|ControlStreamCursorTests';;2) swift test --filter 'PersistentControlStreamIntegrationTests|DaemonControlStreamSourcesTests|DaemonControlStreamAuthorizationPipelineTests|ControlIdentitySecurityAdapterTests|RBACAuthorizationEngineTests/testStreamAuthorizationMapsWatchAndExecuteToExactProjectAndResourceScopes';;3) if testing && [[ "${HOSTWRIGHT_PHASE09_HARNESS_TEST_FORCE_LIVE_FAILURE:-}" == 1 ]]; then forced_live_failure_for_testing; else live; fi;;4) swift test --filter 'EventStreamTests|StateUpgradeTests|ControlStreamCursorTests';;5) swift test --filter 'ControlStreamCursorTests|ControlStreamFrameContractTests|PersistentControlStreamIntegrationTests/testInactiveSessionClosesTheActiveStreamConnection|DaemonControlStreamSourcesTests/testRejectsCrossSubjectCursorAndInvalidFilters|DaemonControlStreamAuthorizationPipelineTests/testAdmissionMutationEffectiveDenialIsAuditedBeforeFailClosedWithoutPersistence|DaemonControlStreamAuthorizationPipelineTests/testAuditFailureIsDegradedForReadStreamAndFailClosedForInteractiveStream';;6) swift test --filter 'PersistentControlStreamIntegrationTests|PersistentControlAuditIntegrationTests|PersistentControlAdmissionIntegrationTests|DaemonControlStreamSourcesTests|DaemonControlStreamAuthorizationPipelineTests|HostwrightDaemonControlServiceTests|WorkloadProfileControlOperationsTests|ContainerizationHelperInteractiveExecutorTests|Phase09Gate08QualificationHarnessTests'; swift build --product hostwrightd; swift build --product hostwright-control; swift build --product hostwright-stream-qualification; scripts/lint.sh; git diff --check; scripts/check-docs.sh;;*) die 'unknown Gate 8 cell.';;esac; }
state(){ printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$gate" "$1" "$2" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" "$3" "$4" "$5" "$6" >> "$root/state-v1.tsv"; chmod 600 "$root/state-v1.tsv"; }
failure(){ [[ -f "$root/failure-v1.tsv" ]] || printf '%s\n' $'recorded_at\tgate\tcell\texit_status\tcommand\tstdout_sha256\tstderr_sha256' > "$root/failure-v1.tsv"; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$gate" "$1" "$2" "$3" "$4" "$5" >> "$root/failure-v1.tsv"; chmod 600 "$root/failure-v1.tsv"; }
manifest(){ local tmp="$root/.manifest.tmp"; /usr/bin/jq --arg s "$1" --arg t "$2" '.status=$s|.completedAt=(if $t==""then null else $t end)' "$root/manifest-v1.json">"$tmp"; chmod 600 "$tmp"; /bin/mv "$tmp" "$root/manifest-v1.json"; }
reusable(){ local n o e os es; for n in 1 2 3 4 5 6; do /usr/bin/awk -F $'\t' -v g="$gate" -v n="$n" -v s="$source_digest_value" -v c="$config_digest_value" -v t="$toolchain_digest_value" '$1==g&&$2==n&&$3=="pass"&&$4==s&&$5==c&&$6==t{f=1}END{exit f?0:1}' "$root/state-v1.tsv" || return 1; o="$root/cell-$(printf '%02d' "$n").stdout.log"; e="$root/cell-$(printf '%02d' "$n").stderr.log"; [[ -f "$o" && -f "$e" ]] || return 1; os="$(/usr/bin/awk -F $'\t' -v g="$gate" -v n="$n" '$1==g&&$2==n&&$3=="pass"{x=$9}END{print x}' "$root/state-v1.tsv")"; es="$(/usr/bin/awk -F $'\t' -v g="$gate" -v n="$n" '$1==g&&$2==n&&$3=="pass"{x=$10}END{print x}' "$root/state-v1.tsv")"; [[ "$(sha "$o")" == "$os" && "$(sha "$e")" == "$es" ]] || return 1; done; }
verify(){ local tmp status=0 count; [[ -f "$root/evidence-v1.sha256" && ! -L "$root/evidence-v1.sha256" && -f "$root/evidence-v1.cms" && ! -L "$root/evidence-v1.cms" ]] || return 1; count="$(/usr/bin/wc -l < "$root/evidence-v1.sha256"|tr -d ' ')"; [[ "$count" == 17 ]] || return 1; /usr/bin/awk 'NF!=2||$1!~/^[a-f0-9]{64}$/||$2!~/^(manifest-v1\.json|state-v1\.tsv|ownership-v1\.tsv|toolchain-v1\.txt|gate-active-run-v1-info\.tsv|cell-[0-9][0-9]\.(stdout|stderr)\.log)$/||seen[$2]++{exit 1}END{exit NR==17?0:1}' "$root/evidence-v1.sha256" || return 1; tmp="$(/usr/bin/mktemp /tmp/hostwright-phase09-gate08-evidence.XXXXXX)" || return 1; security cms -D -u 9 -i "$root/evidence-v1.cms" -o "$tmp" >/dev/null 2>&1 || status=1; /usr/bin/cmp -s "$root/evidence-v1.sha256" "$tmp" || status=1; (cd "$root"&&/usr/bin/shasum -a 256 -c evidence-v1.sha256 >/dev/null) || status=1; /bin/unlink "$tmp"; [[ "$status" == 0 ]]; }
release(){ if [[ "$run_succeeded" == 1 && "$root_lock_created" == 1 && "$gate_lock_created" == 1 ]]; then /bin/rmdir "$root/active-run-v1"; /bin/rmdir "$parent/.phase09-gate08-active-v1"; root_lock_created=0; gate_lock_created=0; fi; }
write_digest(){ (cd "$root"; for f in manifest-v1.json state-v1.tsv ownership-v1.tsv toolchain-v1.txt gate-active-run-v1-info.tsv cell-*.stdout.log cell-*.stderr.log; do [[ -f "$f" ]]&&/usr/bin/shasum -a 256 "$f"; done|LC_ALL=C sort)>"$root/evidence-v1.sha256"; chmod 600 "$root/evidence-v1.sha256"; security cms -S -N "$signing_identity" -H SHA256 -u 9 -i "$root/evidence-v1.sha256" -o "$root/evidence-v1.cms"; chmod 600 "$root/evidence-v1.cms"; }
run(){ prepared; if [[ -e "$root/evidence-v1.sha256" || -e "$root/evidence-v1.cms" ]]; then [[ "$(/usr/bin/jq -r .status "$root/manifest-v1.json")" == passed ]]&&reusable&&verify || die 'completed evidence is incomplete or changed; preserve this root and do not rerun.' 73; printf '%s\n' 'Gate 8 evidence is valid and reused; no cells were rerun.'; return; fi; local lock="$parent/.phase09-gate08-active-v1" n cmd out err start end status cell_pid watchdog; [[ ! -e "$root/active-run-v1" && ! -e "$lock" ]] || die 'An active Gate 8 qualification already exists; do not duplicate it.' 75; mkdir "$lock"; chmod 700 "$lock"; printf '%s\n' $'root\tpid\tstarted_at\tsource_digest\tconfig_digest\ttoolchain_digest'>"$lock/info-v1.tsv"; printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$root" "$$" "$(now)" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value">>"$lock/info-v1.tsv"; chmod 600 "$lock/info-v1.tsv"; gate_lock_created=1; mkdir "$root/active-run-v1"; chmod 700 "$root/active-run-v1"; root_lock_created=1; trap on_exit EXIT; for n in 1 2 3 4 5 6; do revalidate_dependencies; cmd="$(cell_command "$n")"; out="$root/cell-$(printf '%02d' "$n").stdout.log"; err="$root/cell-$(printf '%02d' "$n").stderr.log"; [[ ! -e "$out" && ! -e "$err" ]]||die 'Cell logs already exist; preserve this root and do not rerun.' 73; start="$(now)"; set +e; set -m; (set -e;run_cell "$n")>"$out" 2>"$err" & cell_pid=$!; set +m; /usr/bin/perl -e '$p=shift;$s=shift;sleep $s;kill 15,-$p;sleep 5;kill 9,-$p' "$cell_pid" "$(cell_timeout "$n")" & watchdog=$!; wait "$cell_pid"; status=$?; kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null; [[ "$status" == 0 ]] || terminate_cell_group "$cell_pid"; set -e; chmod 600 "$out" "$err"; end="$(now)"; if [[ "$status" != 0 ]]; then state "$n" failed "$start" "$end" "$(sha "$out")" "$(sha "$err")"; failure "$n" "$status" "$cmd" "$(sha "$out")" "$(sha "$err")"; manifest failed "$end"; die "Gate 8 cell $n failed; progress is frozen and locks are preserved." "$status"; fi; revalidate_dependencies; state "$n" pass "$start" "$end" "$(sha "$out")" "$(sha "$err")"; done; manifest passed "$(now)"; /bin/cp "$lock/info-v1.tsv" "$root/gate-active-run-v1-info.tsv"; chmod 600 "$root/gate-active-run-v1-info.tsv"; write_digest; /bin/unlink "$lock/info-v1.tsv"; run_succeeded=1; release; printf '%s\n' 'Gate 8 qualification passed.'; }
main(){ [[ "$#" -ge 1 ]]||die 'usage: phase09-gate08-qualification.sh <contract|prepare|run>.' 64; case "$1" in contract) [[ "$#" == 1 ]]||die 'contract accepts no arguments.' 64;contract;;prepare) [[ "$#" == 2 && "$2" == 8 ]]||die 'Gate 8 harness accepts only prepare 8.' 64;validate_worktree;validate_root;empty_root;collect;prepare;printf '%s\n' 'Gate 8 evidence root prepared.';;run) [[ "$#" == 2 && "$2" == 8 ]]||die 'Gate 8 harness accepts only run 8.' 64;validate_worktree;validate_root;collect;run;;*) die 'unknown qualification command.' 64;;esac; }
main "$@"
