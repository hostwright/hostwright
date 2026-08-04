#!/usr/bin/env bash
set -euo pipefail

readonly schema='hostwright.phase09.gate09.qualification.manifest.v1'
readonly gate=9 readonly_branch='feat/v0.0.2-phase-09'
readonly live_parent='/Volumes/T9/hostwright/qualification'
readonly signing_fingerprint='A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB'
readonly signing_identity='Developer ID Application: Dev Trivedi (993YC3JY4Q)'
readonly pinned_image='docker.io/library/python@sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92'
readonly pinned_image_digest='sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92'
readonly state_header=$'gate\tcell\tstatus\tsource_digest\tconfig_digest\ttoolchain_digest\tstarted_at\tfinished_at\tstdout_sha256\tstderr_sha256'
readonly ownership_header=$'recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity'
root='' parent='' source_commit='' source_digest_value='' config_digest_value='' toolchain_digest_value='' live_project=''
root_lock_created=0 gate_lock_created=0 run_succeeded=0

die(){ printf '%s\n' "$1" >&2; exit "${2:-70}"; }
now(){ /bin/date -u +%Y-%m-%dT%H:%M:%SZ; }
sha(){ /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
stream_sha(){ /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'; }
testing(){ [[ "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" == 1 ]]; }

contract(){ /bin/echo 'Phase 09 Gate 9 qualification harness contract v1
Gate 9 — 56.25% — complete CLI and Control API parity (#196).
Exactly one Gate 9 qualification may be active. Cells 1..6 run strictly serially.
The harness proves the 57-command inventory, exact text/JSON/exit/reason parity, revision 2.0
plan compatibility, revision 2.1 persistent unary and streaming routes, BootstrapControl API
isolation, no hidden mutation entry point, daemon-unavailable/restart recovery, and signed daemon/CLI/control
live behavior. Gate 9 uses a unique Phase 09 project and never inspects, stops, or removes
other-phase processes, sessions, evidence, or runtime resources. Only artifacts recorded in
the Gate 9 ownership ledger may be stopped or removed.'; }

qualification_parent(){ if testing; then : "${HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT:?test parent required}"; printf '%s\n' "$HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT"; else printf '%s\n' "$live_parent"; fi; }
validate_worktree(){ [[ "$(git branch --show-current)" == "$readonly_branch" ]] || die "Gate 9 requires branch $readonly_branch." 66; [[ "$(/bin/realpath "$(git rev-parse --show-toplevel)")" == /Users/dev/Documents/hostwright-phase09 ]] || die 'Gate 9 requires the isolated Phase 09 worktree.' 66; }
validate_root(){ : "${HOSTWRIGHT_PHASE09_GATE_ROOT:?HOSTWRIGHT_PHASE09_GATE_ROOT is required}"; root="$HOSTWRIGHT_PHASE09_GATE_ROOT"; parent="$(qualification_parent)"; local canonical; canonical="$(/bin/realpath "$parent")"; [[ -d "$parent" && ! -L "$parent" && "$canonical" == "$parent" ]] || die 'qualification parent must be canonical and non-symlinked.' 66; if testing; then [[ "$canonical" == /private/var/folders/*/T/hostwright-phase09-harness-* || "$canonical" == /var/folders/*/T/hostwright-phase09-harness-* ]] || die 'test parent must be isolated.' 66; else [[ "$canonical" == "$live_parent" ]] || die 'Gate 9 evidence must use the fixed qualification parent.' 66; fi; [[ "$root" == /* && -d "$root" && ! -L "$root" && "$(/bin/realpath "$root")" == "$root" && "$(/bin/realpath "$(dirname "$root")")" == "$canonical" ]] || die 'evidence root is unsafe.' 66; [[ "${root##*/}" =~ ^phase09-gate09-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || die 'evidence root name is not a Gate 9 lowercase UUID.' 66; [[ "$(stat -f '%u' "$root")" == "$(id -u)" && "$(stat -f '%Lp' "$root")" == 700 ]] || die 'evidence root must be current-user-owned and mode 0700.' 66; parent="$canonical"; live_project="phase09-gate09-$(printf '%s' "${root##*/}" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print substr($1,1,16)}')"; export HOSTWRIGHT_PHASE09_LIVE_PROJECT="$live_project"; }
empty_root(){ [[ -z "$(/usr/bin/find "$root" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die 'prepare requires an empty evidence root.' 73; }
source_digest(){ { git rev-parse HEAD; git diff --binary HEAD -- . ':(exclude)tmp'; while IFS= read -r -d '' p; do [[ "$p" == tmp/* || "$p" == .codex/* || "$p" == .claude/* ]] && continue; printf '%s\0' "$p"; /usr/bin/shasum -a 256 "$p"; done < <(git ls-files --others --exclude-standard -z | LC_ALL=C /usr/bin/sort -z); } | stream_sha; }
toolchain(){ { /usr/bin/sw_vers; xcodebuild -version; swift --version; container --version; xcrun --find codesign; security find-identity -p codesigning -v; } 2>&1; }
cell_command(){ case "$1" in
  1) printf '%s\n' "swift test --jobs 1 --filter 'HostwrightCommandTransportTests|CLIControlAuthorizationScopeTests'";;
  2) printf '%s\n' "swift test --jobs 1 --filter 'PersistentControlClientTests|PersistentControlServerTests|PersistentControlStreamIntegrationTests|PersistentControlAdmissionIntegrationTests|PersistentControlAuditIntegrationTests|DaemonControlStreamSourcesTests|HostwrightDaemonControlServiceTests|BootstrapControl'";;
  3) printf '%s\n' 'signed daemon/CLI/control plus one owned pinned Apple-container unary, mutation, stream, restart, and failure-path qualification';;
  4) printf '%s\n' "swift test --jobs 1 --filter 'ControlRequestTests|ControlPlaneContractTests|LocalControlAPIIntegrationTests|StateUpgradeTests|CLIControlRouteTests' # revision 2.0 and revision 2.1";;
  5) printf '%s\n' "swift test --jobs 1 --filter 'CLIControlAuthorizationScopeTests|CLIControlRouteTests|BootstrapControlAPITests|ControlIdentitySecurityAdapterTests|RBACAuthorizationEngineTests' # no hidden mutation entry point";;
  6) printf '%s\n' "swift test --jobs 1 --filter 'HostwrightCommandTransportTests|CLIControlAuthorizationScopeTests|PersistentControlStreamIntegrationTests|DaemonControlStreamSourcesTests|Phase09Gate09QualificationHarnessTests'; swift build --jobs 1 --product hostwright; swift build --jobs 1 --product hostwright-control; swift build --jobs 1 --product hostwrightd; scripts/lint.sh; git diff --check; scripts/check-docs.sh";;
  *) die 'unknown Gate 9 cell.';; esac; }
classes(){ case "$1" in 1) printf '%s\n' '["U"]';; 2) printf '%s\n' '["I"]';; 3) printf '%s\n' '["L","I"]';; 4) printf '%s\n' '["M"]';; 5) printf '%s\n' '["S"]';; 6) printf '%s\n' '["R","I"]';; *) die 'unknown evidence class.';; esac; }
config_digest(){ { sha "$0"; sha scripts/lint.sh; sha scripts/check-docs.sh; local n; for n in 1 2 3 4 5 6; do cell_command "$n"; classes "$n"; done; } | stream_sha; }
collect(){ source_commit="$(git rev-parse HEAD)"; source_digest_value="$(source_digest)"; config_digest_value="$(config_digest)"; toolchain_digest_value="$(toolchain | stream_sha)"; if ! testing; then [[ -z "$(git status --porcelain --untracked-files=all -- . ':(exclude)tmp')" ]] || die 'Gate 9 qualification requires a clean committed branch.' 73; fi; }
revalidate_dependencies(){ [[ "$(git rev-parse HEAD)" == "$source_commit" && "$(source_digest)" == "$source_digest_value" && "$(config_digest)" == "$config_digest_value" && "$(toolchain | stream_sha)" == "$toolchain_digest_value" ]] || die 'Gate 9 evidence dependencies changed during qualification; progress is frozen.' 73; }
cells_json(){ local n; for n in 1 2 3 4 5 6; do /usr/bin/jq -n --argjson cell "$n" --arg command "$(cell_command "$n")" --argjson evidenceClasses "$(classes "$n")" '{cell:$cell,command:$command,evidenceClasses:$evidenceClasses}'; done | /usr/bin/jq -s .; }
prepare(){ printf '%s\n' "$ownership_header" > "$root/ownership-v1.tsv"; printf '%s\n' "$state_header" > "$root/state-v1.tsv"; toolchain > "$root/toolchain-v1.txt"; /usr/bin/jq -n --arg schema "$schema" --argjson gate "$gate" --arg sourceCommit "$source_commit" --arg sourceDigest "$source_digest_value" --arg configDigest "$config_digest_value" --arg toolchainDigest "$toolchain_digest_value" --arg startedAt "$(now)" --argjson evidenceByCell "$(cells_json)" '{schema:$schema,gate:$gate,sourceCommit:$sourceCommit,sourceDigest:$sourceDigest,configDigest:$configDigest,toolchainDigest:$toolchainDigest,cellOrder:[1,2,3,4,5,6],evidenceByCell:$evidenceByCell,startedAt:$startedAt,completedAt:null,status:"prepared"}' > "$root/manifest-v1.json"; chmod 600 "$root"/*; }
prepared(){ local f; for f in manifest-v1.json ownership-v1.tsv state-v1.tsv toolchain-v1.txt; do [[ -f "$root/$f" && ! -L "$root/$f" ]] || die 'run requires a complete prepared evidence root.' 73; done; [[ "$(head -n 1 "$root/ownership-v1.tsv")" == "$ownership_header" && "$(head -n 1 "$root/state-v1.tsv")" == "$state_header" ]] || die 'prepared evidence headers are invalid.' 73; [[ "$(/usr/bin/jq -r .schema "$root/manifest-v1.json")" == "$schema" && "$(/usr/bin/jq -r .sourceDigest "$root/manifest-v1.json")" == "$source_digest_value" && "$(/usr/bin/jq -r .configDigest "$root/manifest-v1.json")" == "$config_digest_value" && "$(/usr/bin/jq -r .toolchainDigest "$root/manifest-v1.json")" == "$toolchain_digest_value" ]] || die 'prepared evidence dependencies changed; preserve this root.' 73; }

short_live_runtime(){ local suffix="${root##*/phase09-gate09-}"; printf '%s/.p09g9-%s\n' "$parent" "${suffix:0:17}"; }
record_root(){ local runtime="$1" expected; expected="$(short_live_runtime)"; [[ "$runtime" == "$expected" && "$(dirname "$runtime")" == "$parent" && -d "$runtime" && ! -L "$runtime" && "$(/bin/realpath "$runtime")" == "$runtime" && "$(stat -f '%u' "$runtime")" == "$(id -u)" && "$(stat -f '%Lp' "$runtime")" == 700 ]] || die 'live runtime root is unsafe.'; printf '%s\ttemporary-root\tgate09-live-runtime\t%s\t%s\t%s\tscope=gate09-live\n' "$(now)" "$runtime" "$(stat -f '%d' "$runtime")" "$(stat -f '%i' "$runtime")" >> "$root/ownership-v1.tsv"; }
record_artifact(){ local runtime="$1" path="$2" kind; [[ "$path" == "$runtime"/* && ! -L "$path" && "$(stat -f '%u' "$path")" == "$(id -u)" ]] || die 'live artifact is not owned.'; [[ -d "$path" ]] && kind=temporary-directory || kind=temporary-file; /usr/bin/awk -F $'\t' -v p="$path" -v k="$kind" '$2==k&&$4==p{f=1}END{exit f?0:1}' "$root/ownership-v1.tsv" && return; printf '%s\t%s\t%s\t%s\t%s\t%s\tscope=gate09-live\n' "$(now)" "$kind" "${path##*/}" "$path" "$(stat -f '%d' "$path")" "$(stat -f '%i' "$path")" >> "$root/ownership-v1.tsv"; }
record_process(){ local pid="$1" executable="$2" command start; kill -0 "$pid" 2>/dev/null || die 'owned daemon process is not alive.'; command="$(ps -p "$pid" -o command=)"; start="$(ps -p "$pid" -o lstart=)"; [[ "${command%% *}" == "$executable" && -n "$start" ]] || die 'owned daemon process identity is incomplete.'; printf '%s\tprocess\thostwrightd\t%s\t%s\t%s\tpid=%s;command_sha256=%s;start_sha256=%s;scope=gate09-live\n' "$(now)" "$executable" "$(stat -f '%d' "$executable")" "$(stat -f '%i' "$executable")" "$pid" "$(printf '%s' "$command"|stream_sha)" "$(printf '%s' "$start"|stream_sha)" >> "$root/ownership-v1.tsv"; }
container_identity_is_exact(){ local resource="$1"; container list --all --format json | /usr/bin/jq -e --arg resource "$resource" --arg digest "$pinned_image_digest" --arg project "$live_project" '[.[]|select(.id==$resource)] as $matches | ($matches|length)==1 and ($matches[0].id==$resource) and ($matches[0].configuration.image.descriptor.digest==$digest) and ($matches[0].configuration.labels["dev.hostwright.project"]==$project)' >/dev/null; }
record_container(){ local resource="$1"; [[ "$resource" =~ ^hostwright-v2-[a-z0-9-]+$ ]] || die 'Gate 9 live container identifier is unsafe.'; container_identity_is_exact "$resource" || die 'Gate 9 container identity is not exact.'; printf '%s\tcontainer-resource\t%s\t\t\t\timage=%s;project=%s;scope=gate09-live\n' "$(now)" "$resource" "$pinned_image_digest" "$live_project" >> "$root/ownership-v1.tsv"; }
record_pending_container_claim(){ /usr/bin/awk -F $'\t' -v project="$live_project" '$2=="container-pending"&&$3==project{f=1}END{exit f?0:1}' "$root/ownership-v1.tsv" && return 0; printf '%s\tcontainer-pending\t%s\t\t\t\timage=%s;project=%s;scope=gate09-live\n' "$(now)" "$live_project" "$pinned_image_digest" "$live_project" >> "$root/ownership-v1.tsv"; }
resolve_pending_container_claim(){ local matches resource; matches="$(container list --all --format json | /usr/bin/jq -r --arg digest "$pinned_image_digest" --arg project "$live_project" '[.[]|select(.configuration.image.descriptor.digest==$digest and .configuration.labels["dev.hostwright.project"]==$project)|.id]|sort|unique|.[]')" || die 'Gate 9 pending container recovery inventory failed.'; [[ "$matches" != *$'\n'* ]] || die 'Gate 9 pending container claim became ambiguous; cleanup is frozen.'; [[ -n "$matches" ]] || return 0; resource="$matches"; record_container "$resource"; printf '%s\n' "$resource"; }
stop_all_ledgered_processes(){ local path device inode identity; while IFS=$'\t' read -r path device inode identity; do stop_exact_process "$path" "$device" "$inode" "$identity"; done < <(/usr/bin/awk -F $'\t' '$2=="process"{print $4"\t"$5"\t"$6"\t"$7}' "$root/ownership-v1.tsv"); }
delete_exact_container(){ local resource="$1" present; [[ "$resource" =~ ^hostwright-v2-[a-z0-9-]+$ ]] || die 'ledgered Gate 9 container identifier is unsafe.'; stop_all_ledgered_processes; present="$(container list --all --format json | /usr/bin/jq -r --arg id "$resource" 'any(.[];.id==$id)')"; [[ "$present" == false ]] && return 0; container_identity_is_exact "$resource" || die 'ledgered Gate 9 container identity changed; cleanup is refused.'; container delete --force "$resource" >/dev/null; present="$(container list --all --format json | /usr/bin/jq -r --arg id "$resource" 'any(.[];.id==$id)')"; [[ "$present" == false ]] || die 'ledgered Gate 9 container remained after cleanup.'; }
keychain_namespace(){ printf '%s' "$1" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print substr($1,1,32)}'; }
record_keychain_item(){ local service="$1" account="$2" attributes status; [[ "$service" =~ ^dev\.hostwright\.(audit|stream-cursor)\.v1\.[a-f0-9]{32}$ ]] || die 'Gate 9 Keychain service is unsafe.'; [[ "$account" == active-key-id || "$account" == chain-head-v1 || "$account" =~ ^signing-key:p256:[a-f0-9]{64}$ ]] || die 'Gate 9 Keychain account is unsafe.'; if attributes="$(security find-generic-password -s "$service" -a "$account" 2>&1)"; then :; else status=$?; [[ "$status" == 44 ]] && return 0; die 'Gate 9 Keychain inventory failed.'; fi; printf '%s' "$attributes" | /usr/bin/grep -F '"gena"<blob>="hostwright-audit-owned-v1"' >/dev/null || die 'Gate 9 Keychain ownership marker changed.'; /usr/bin/awk -F $'\t' -v s="$service" -v a="$account" '$2=="keychain-item"&&$7=="service="s";account="a";marker=hostwright-audit-owned-v1;scope=gate09-live"{f=1}END{exit f?0:1}' "$root/ownership-v1.tsv" && return 0; printf '%s\tkeychain-item\t%s/%s\t\t\t\tservice=%s;account=%s;marker=hostwright-audit-owned-v1;scope=gate09-live\n' "$(now)" "$service" "$account" "$service" "$account" >> "$root/ownership-v1.tsv"; }
record_keychain_items(){ local state="$1" namespace audit_service cursor_service key_id runtime; runtime="$(short_live_runtime)"; [[ "$state" == "$runtime"/* && -f "$state" && ! -L "$state" && "$(stat -f '%u' "$state")" == "$(id -u)" ]] || die 'Gate 9 state database is unsafe for Keychain inventory.'; namespace="$(keychain_namespace "$state")"; audit_service="dev.hostwright.audit.v1.$namespace"; cursor_service="dev.hostwright.stream-cursor.v1.$namespace"; while IFS= read -r key_id; do [[ "$key_id" =~ ^p256:[a-f0-9]{64}$ ]] || die 'Gate 9 audit key identifier is unsafe.'; record_keychain_item "$audit_service" "signing-key:$key_id"; done < <(/usr/bin/sqlite3 "$state" 'SELECT key_id FROM audit_key_metadata ORDER BY generation;' 2>/dev/null || true); record_keychain_item "$audit_service" active-key-id; record_keychain_item "$audit_service" chain-head-v1; while IFS= read -r key_id; do [[ "$key_id" =~ ^p256:[a-f0-9]{64}$ ]] || die 'Gate 9 cursor key identifier is unsafe.'; record_keychain_item "$cursor_service" "signing-key:$key_id"; done < <(/usr/bin/sqlite3 "$state" 'SELECT DISTINCT signing_key_id FROM control_stream_cursors WHERE signing_key_id IS NOT NULL ORDER BY signing_key_id;' 2>/dev/null || true); record_keychain_item "$cursor_service" active-key-id; record_keychain_item "$cursor_service" chain-head-v1; record_keychain_items_for_service "$audit_service"; record_keychain_items_for_service "$cursor_service"; }
keychain_accounts_from_dump(){ local service="$1"; /usr/bin/awk -v service="$service" '
  function reset() { matched=0; account="" }
  function emit() { if (matched && account != "") print account; reset() }
  /^keychain:/ { emit(); reset() }
  /"svce"<blob>="/ {
    line=$0; sub(/^.*"svce"<blob>="/, "", line); sub(/".*$/, "", line); matched=(line == service)
  }
  /"acct"<blob>="/ {
    line=$0; sub(/^.*"acct"<blob>="/, "", line); sub(/".*$/, "", line); account=line
  }
  /^$/ { emit() }
  END { emit() }
  '
}
record_keychain_items_for_service(){ local service="$1"; security dump-keychain 2>/dev/null | keychain_accounts_from_dump "$service" | LC_ALL=C sort -u | while IFS= read -r account; do
    [[ "$account" == active-key-id || "$account" == chain-head-v1 || "$account" =~ ^signing-key:p256:[a-f0-9]{64}$ ]] || die 'Gate 9 Keychain account is unsafe.'
    record_keychain_item "$service" "$account"
  done; }
verify_keychain_absent(){ local identity service account status; while IFS=$'\t' read -r identity; do service="${identity#service=}"; service="${service%%;*}"; account="${identity#*account=}"; account="${account%%;*}"; if security find-generic-password -s "$service" -a "$account" >/dev/null 2>&1; then die 'A ledgered Gate 9 Keychain item remained after cleanup.'; else status=$?; fi; [[ "$status" == 44 ]] || die 'Gate 9 Keychain absence verification failed.'; done < <(/usr/bin/awk -F $'\t' '$2=="keychain-item"{print $7}' "$root/ownership-v1.tsv"); }
cleanup_keychain_items(){ local state="$1" namespace expected_audit expected_cursor identity service account attributes status; namespace="$(keychain_namespace "$state")"; expected_audit="dev.hostwright.audit.v1.$namespace"; expected_cursor="dev.hostwright.stream-cursor.v1.$namespace"; while IFS=$'\t' read -r identity; do service="${identity#service=}"; service="${service%%;*}"; account="${identity#*account=}"; account="${account%%;*}"; [[ "$service" == "$expected_audit" || "$service" == "$expected_cursor" ]] || die 'Gate 9 Keychain ledger service changed; cleanup is refused.'; [[ "$account" == active-key-id || "$account" == chain-head-v1 || "$account" =~ ^signing-key:p256:[a-f0-9]{64}$ ]] || die 'Gate 9 Keychain ledger account changed; cleanup is refused.'; attributes="$(security find-generic-password -s "$service" -a "$account" 2>&1)" || die 'A ledgered Gate 9 Keychain item disappeared before cleanup.'; printf '%s' "$attributes" | /usr/bin/grep -F '"gena"<blob>="hostwright-audit-owned-v1"' >/dev/null || die 'Gate 9 Keychain ownership marker changed; cleanup is refused.'; security delete-generic-password -s "$service" -a "$account" >/dev/null 2>&1 || die 'Gate 9 Keychain item cleanup failed.'; done < <(/usr/bin/awk -F $'\t' '$2=="keychain-item"{print $7}' "$root/ownership-v1.tsv"); verify_keychain_absent; for service in "$expected_audit" "$expected_cursor"; do if security find-generic-password -s "$service" >/dev/null 2>&1; then die 'An unledgered Gate 9 Keychain item remains; cleanup is frozen.'; else status=$?; fi; [[ "$status" == 44 ]] || die 'Gate 9 Keychain service absence verification failed.'; done; }
stop_exact_process(){ local path="$1" device="$2" inode="$3" identity="$4" pid command_sha start_sha command start n; pid="${identity#pid=}"; pid="${pid%%;*}"; command_sha="${identity#*command_sha256=}"; command_sha="${command_sha%%;*}"; start_sha="${identity#*start_sha256=}"; start_sha="${start_sha%%;*}"; [[ "$pid" =~ ^[1-9][0-9]*$ && -f "$path" && ! -L "$path" && "$(stat -f '%d' "$path")" == "$device" && "$(stat -f '%i' "$path")" == "$inode" ]] || die 'ledgered process executable identity changed; cleanup is refused.'; kill -0 "$pid" 2>/dev/null || return 0; command="$(ps -p "$pid" -o command=)"; start="$(ps -p "$pid" -o lstart=)"; [[ "${command%% *}" == "$path" && "$(printf '%s' "$command"|stream_sha)" == "$command_sha" && "$(printf '%s' "$start"|stream_sha)" == "$start_sha" ]] || die 'ledgered process identity changed; cleanup is refused.'; kill -TERM "$pid"; for n in {1..100}; do kill -0 "$pid" 2>/dev/null || return 0; /bin/sleep 0.1; done; die 'owned process did not stop; cleanup is frozen.' 124; }
cleanup_files(){ local runtime="$1" path device inode; while IFS=$'\t' read -r path device inode; do [[ "$path" == "$runtime"/* && ! -d "$path" && ! -L "$path" && "$(stat -f '%d' "$path")" == "$device" && "$(stat -f '%i' "$path")" == "$inode" ]] || die 'live artifact identity changed; cleanup is refused'; /bin/unlink "$path"; done < <(/usr/bin/awk -F $'\t' '$2=="temporary-file"{print $4"\t"$5"\t"$6}' "$root/ownership-v1.tsv"); while IFS=$'\t' read -r path device inode; do [[ "$path" == "$runtime"/* && -d "$path" && ! -L "$path" && "$(stat -f '%d' "$path")" == "$device" && "$(stat -f '%i' "$path")" == "$inode" ]] || die 'live artifact identity changed; cleanup is refused'; /bin/rmdir "$path"; done < <(/usr/bin/awk -F $'\t' '$2=="temporary-directory"{print length($4)"\t"$4"\t"$5"\t"$6}' "$root/ownership-v1.tsv" | /usr/bin/sort -rn | /usr/bin/cut -f2-); /bin/rmdir "$runtime"; }
preserve_live_diagnostics(){ local runtime="$1" diagnostics path copied=0; [[ "$run_succeeded" == 0 && "$runtime" == "$(short_live_runtime)" && -d "$runtime" && ! -L "$runtime" ]] || return 0; diagnostics="$root/live-failure-diagnostics-v1"; while IFS= read -r -d '' path; do [[ -f "$path" && ! -L "$path" && "$(stat -f '%u' "$path")" == "$(id -u)" ]] || die 'live diagnostic identity changed; preservation is refused.'; if [[ "$copied" == 0 ]]; then mkdir "$diagnostics"; chmod 700 "$diagnostics"; copied=1; fi; /bin/cp -p "$path" "$diagnostics/${path##*/}"; chmod 600 "$diagnostics/${path##*/}"; done < <(/usr/bin/find "$runtime" -maxdepth 1 -type f \( -name 'daemon.*.stdout.log' -o -name 'daemon.*.stderr.log' -o -name 'qualification.*.json' \) -print0); }
emergency_live_cleanup(){ [[ -n "$root" && -f "$root/ownership-v1.tsv" ]] || return 0; local runtime path device inode identity resource state; runtime="$(/usr/bin/awk -F $'\t' '$2=="temporary-root"&&$3=="gate09-live-runtime"{print $4}' "$root/ownership-v1.tsv")"; [[ -n "$runtime" && "$runtime" != *$'\n'* && "$runtime" == "$(short_live_runtime)" ]] || return 0; while IFS=$'\t' read -r path device inode identity; do stop_exact_process "$path" "$device" "$inode" "$identity"; done < <(/usr/bin/awk -F $'\t' '$2=="process"{print $4"\t"$5"\t"$6"\t"$7}' "$root/ownership-v1.tsv"); resource="$(/usr/bin/awk -F $'\t' '$2=="container-resource"{print $3}' "$root/ownership-v1.tsv" | /usr/bin/sort -u)"; if [[ -z "$resource" ]] && /usr/bin/awk -F $'\t' '$2=="container-pending"{f=1}END{exit f?0:1}' "$root/ownership-v1.tsv"; then resource="$(resolve_pending_container_claim)"; fi; [[ -z "$resource" ]] || { [[ "$resource" != *$'\n'* ]] || die 'multiple Gate 9 container resources were ledgered; cleanup is frozen.'; delete_exact_container "$resource"; }; [[ -d "$runtime" && ! -L "$runtime" ]] || return 0; preserve_live_diagnostics "$runtime"; state="$runtime/app-support/state/state.sqlite"; if [[ -f "$state" && ! -L "$state" ]]; then record_keychain_items "$state"; cleanup_keychain_items "$state"; fi; while IFS= read -r -d '' path; do record_artifact "$runtime" "$path"; done < <(/usr/bin/find "$runtime" -mindepth 1 -print0); cleanup_files "$runtime"; }

start_daemon(){ local runtime="$1" executable="$2" config="$3" state="$4" generation="$5" socket="$runtime/app-support/run/control-v2.sock" n; (( ${#socket} < 104 )) || die 'the Gate 9 control socket exceeds the macOS Unix-domain path limit.' 66; HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$runtime/app-support" HOSTWRIGHT_CACHE_DIR="$runtime/cache" HOSTWRIGHT_LOG_DIR="$runtime/logs" "$executable" --foreground --config "$config" --state-db "$state" --interval 5 --jitter 0 --parallelism 1 >"$runtime/daemon.$generation.stdout.log" 2>"$runtime/daemon.$generation.stderr.log" & local pid=$!; record_process "$pid" "$executable"; for n in {1..240}; do [[ -S "$socket" ]] && { printf '%s\n' "$pid"; return; }; if ! kill -0 "$pid" 2>/dev/null; then /bin/cat "$runtime/daemon.$generation.stdout.log" >&2; /bin/cat "$runtime/daemon.$generation.stderr.log" >&2; die 'owned daemon exited before publishing its socket.'; fi; /bin/sleep .25; done; die 'owned daemon did not publish its socket.' 124; }
forced_live_failure_for_testing(){ local runtime executable pid resource='hostwright-v2-p09-test-live'; runtime="$(short_live_runtime)"; mkdir "$runtime"; chmod 700 "$runtime"; record_root "$runtime"; executable="$runtime/signed-hostwrightd"; /bin/cp /bin/sleep "$executable"; chmod 700 "$executable"; printf '%s\n' 'forced Gate 9 live failure diagnostic' > "$runtime/daemon.forced.stderr.log"; "$executable" 300 & pid=$!; record_process "$pid" "$executable"; container phase09-test-create "$resource"; record_container "$resource"; return 47; }
wait_for_converged_status(){
  local runtime="$1" cli="$2" config="$3" state="$4" resource="$5" output deadline_epoch
  deadline_epoch=$(( $(/bin/date +%s) + 300 ))
  while [[ "$(/bin/date +%s)" -lt "$deadline_epoch" ]]; do
    output="$(HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$runtime/app-support" HOSTWRIGHT_CACHE_DIR="$runtime/cache" HOSTWRIGHT_LOG_DIR="$runtime/logs" "$cli" status "$config" --state-db "$state" --output json)"
    printf '%s' "$output" > "$runtime/qualification.status-plan-v1.json"
    chmod 600 "$runtime/qualification.status-plan-v1.json"
    if /usr/bin/jq -e --arg resource "$resource" '
      (.actions | length) == 0 and
      any(.services[];
        .name == "probe" and
        .observed.resourceIdentifier == $resource and
        .observed.lifecycle == "running" and
        .observed.health == "healthy"
      )
    ' "$runtime/qualification.status-plan-v1.json" >/dev/null; then
      return
    fi
    /bin/sleep 1
  done
  die 'owned Gate 9 probe did not converge to a healthy no-action state.' 124
}
live(){
  if testing && [[ "${HOSTWRIGHT_PHASE09_HARNESS_TEST_FORCE_LIVE_FAILURE:-}" == 1 ]]; then
    forced_live_failure_for_testing
    return
  fi
  swift build --jobs 1 --product hostwright
  swift build --jobs 1 --product hostwright-control
  swift build --jobs 1 --product hostwrightd
  swift build --jobs 1 --product hostwright-stream-qualification
  local bin runtime cli control daemon bootstrap config state socket pid resource output first_process_identity metrics_hash trace_id trace_hash n
  bin="$(swift build --show-bin-path)"
  runtime="$(short_live_runtime)"
  mkdir "$runtime"
  chmod 700 "$runtime"
  record_root "$runtime"
  mkdir "$runtime/app-support" "$runtime/cache" "$runtime/logs"
  chmod 700 "$runtime/app-support" "$runtime/cache" "$runtime/logs"
  cli="$runtime/hostwright"
  control="$runtime/hostwright-control"
  daemon="$runtime/signed-hostwrightd"
  bootstrap="$runtime/bootstrap-hostwright"
  /bin/cp "$bin/hostwright" "$cli"
  /bin/cp "$bin/hostwright-control" "$control"
  /bin/cp "$bin/hostwrightd" "$daemon"
  /bin/cp "$bin/hostwright-stream-qualification" "$bootstrap"
  codesign --force --sign "$signing_fingerprint" --identifier hostwright "$cli"
  codesign --force --sign "$signing_fingerprint" --identifier hostwright-control "$control"
  codesign --force --sign "$signing_fingerprint" --identifier hostwrightd "$daemon"
  codesign --force --sign "$signing_fingerprint" --identifier hostwright-control "$bootstrap"
  for output in "$cli" "$control" "$daemon" "$bootstrap"; do
    codesign --verify --strict "$output"
    [[ "$(codesign -d --verbose=4 "$output" 2>&1 | /usr/bin/awk -F= '$1=="TeamIdentifier"{print $2}')" == 993YC3JY4Q ]] || die 'a Gate 9 live artifact has the wrong signing team.'
  done
  config="$runtime/hostwright.yaml"
  printf '%s\n' 'version: 2' "project: $live_project" 'imagePolicy: require-digest' 'services:' '  probe:' "    image: $pinned_image" '    command: ["python3", "-c", "import time; print(\"gate09-log\", flush=True); time.sleep(600)"]' '    probes:' '      liveness:' '        exec: ["true"]' '        interval: 60s' '        timeout: 1s' > "$config"
  chmod 600 "$config"
  state="$runtime/app-support/state/state.sqlite"
  socket="$runtime/app-support/run/control-v2.sock"
  (( ${#socket} < 104 )) || die 'the Gate 9 control socket exceeds the macOS Unix-domain path limit.' 66
  "$bootstrap" --bootstrap --root "$runtime" --state "$state" --socket "$socket" --client "$cli"

  record_pending_container_claim
  pid="$(start_daemon "$runtime" "$daemon" "$config" "$state" initial)"
  resource=''
  for n in {1..1200}; do
    resource="$(resolve_pending_container_claim)"
    [[ -n "$resource" ]] && break
    /bin/sleep .25
  done
  [[ -n "$resource" ]] || die 'owned Gate 9 container was not observed.' 124

  output="$(HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$runtime/app-support" HOSTWRIGHT_CACHE_DIR="$runtime/cache" HOSTWRIGHT_LOG_DIR="$runtime/logs" "$cli" capabilities --json)"
  printf '%s' "$output" > "$runtime/qualification.capabilities-v1.json"
  chmod 600 "$runtime/qualification.capabilities-v1.json"
  /usr/bin/jq -e . "$runtime/qualification.capabilities-v1.json" >/dev/null
  output="$(HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$runtime/app-support" HOSTWRIGHT_CACHE_DIR="$runtime/cache" HOSTWRIGHT_LOG_DIR="$runtime/logs" "$cli" plan "$config" --output json)"
  printf '%s' "$output" > "$runtime/qualification.plan-v1.json"
  chmod 600 "$runtime/qualification.plan-v1.json"
  wait_for_converged_status "$runtime" "$cli" "$config" "$state" "$resource"
  /usr/bin/jq -e '.planHash | select(test("^[a-f0-9]{16}$"))' "$runtime/qualification.status-plan-v1.json" >/dev/null

  HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$runtime/app-support" HOSTWRIGHT_CACHE_DIR="$runtime/cache" HOSTWRIGHT_LOG_DIR="$runtime/logs" "$cli" logs probe "$config" --state-db "$state" --tail 20 >/dev/null
  HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$runtime/app-support" HOSTWRIGHT_CACHE_DIR="$runtime/cache" HOSTWRIGHT_LOG_DIR="$runtime/logs" "$cli" exec probe --manifest "$config" --state-db "$state" --no-stdin -- python3 -c 'print("gate09-exec")' >/dev/null
  HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$runtime/app-support" HOSTWRIGHT_CACHE_DIR="$runtime/cache" HOSTWRIGHT_LOG_DIR="$runtime/logs" "$cli" events --state-db "$state" --project "$live_project" --limit 20 --output json | /usr/bin/jq -e . >/dev/null
  HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$runtime/app-support" HOSTWRIGHT_CACHE_DIR="$runtime/cache" HOSTWRIGHT_LOG_DIR="$runtime/logs" "$bootstrap" --live --root "$runtime" --state "$state" --socket "$socket" > "$runtime/stream-live.json"

  metrics_hash="$(HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$runtime/app-support" "$cli" metrics snapshot --state-db "$state" --output json | /usr/bin/jq -er '.snapshotSHA256')"
  HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$runtime/app-support" "$cli" metrics export --state-db "$state" --output-path "$runtime/metrics.json" --confirm-snapshot "$metrics_hash" --output json | /usr/bin/jq -e . >/dev/null
  trace_id="$(/usr/bin/sqlite3 "$state" 'SELECT trace_id FROM trace_spans ORDER BY started_at DESC LIMIT 1;')"
  if [[ -n "$trace_id" ]]; then
    trace_hash="$(HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$runtime/app-support" "$cli" traces inspect --state-db "$state" --trace-id "$trace_id" --output json | /usr/bin/jq -er --arg id "$trace_id" '.traces[] | select(.traceID == $id) | .traceSHA256')"
    HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$runtime/app-support" "$cli" traces export --state-db "$state" --trace-id "$trace_id" --output-path "$runtime/trace.json" --confirm-trace "$trace_hash" --output json | /usr/bin/jq -e . >/dev/null
  fi

  record_keychain_items "$state"
  first_process_identity="$(/usr/bin/awk -F $'\t' -v p="$pid" '$2=="process"&&$7~("pid="p";"){print $7}' "$root/ownership-v1.tsv")"
  stop_exact_process "$daemon" "$(stat -f '%d' "$daemon")" "$(stat -f '%i' "$daemon")" "$first_process_identity"
  HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$runtime/app-support" "$cli" capabilities --json >/dev/null 2>&1 && die 'CLI unexpectedly bypassed the unavailable daemon.'
  pid="$(start_daemon "$runtime" "$daemon" "$config" "$state" restarted)"
  HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$runtime/app-support" "$cli" capabilities --json | /usr/bin/jq -e . >/dev/null
  HOSTWRIGHT_APPLICATION_SUPPORT_DIR="$runtime/app-support" "$bootstrap" --resume --root "$runtime" --state "$state" --socket "$socket" > "$runtime/stream-resume.json"

  delete_exact_container "$resource"
  record_keychain_items "$state"
  cleanup_keychain_items "$state"
  while IFS= read -r -d '' output; do
    record_artifact "$runtime" "$output"
  done < <(/usr/bin/find "$runtime" -mindepth 1 -print0)
  cleanup_files "$runtime"
}

run_cell(){ case "$1" in 1) swift test --jobs 1 --filter 'HostwrightCommandTransportTests|CLIControlAuthorizationScopeTests';; 2) swift test --jobs 1 --filter 'PersistentControlClientTests|PersistentControlServerTests|PersistentControlStreamIntegrationTests|PersistentControlAdmissionIntegrationTests|PersistentControlAuditIntegrationTests|DaemonControlStreamSourcesTests|HostwrightDaemonControlServiceTests|BootstrapControl';; 3) live;; 4) swift test --jobs 1 --filter 'ControlRequestTests|ControlPlaneContractTests|LocalControlAPIIntegrationTests|StateUpgradeTests|CLIControlRouteTests';; 5) swift test --jobs 1 --filter 'CLIControlAuthorizationScopeTests|CLIControlRouteTests|BootstrapControlAPITests|ControlIdentitySecurityAdapterTests|RBACAuthorizationEngineTests';; 6) swift test --jobs 1 --filter 'HostwrightCommandTransportTests|CLIControlAuthorizationScopeTests|PersistentControlStreamIntegrationTests|DaemonControlStreamSourcesTests|Phase09Gate09QualificationHarnessTests'; swift build --jobs 1 --product hostwright; swift build --jobs 1 --product hostwright-control; swift build --jobs 1 --product hostwrightd; scripts/lint.sh; git diff --check; scripts/check-docs.sh;; *) die 'unknown Gate 9 cell.';; esac; }
state(){ printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$gate" "$1" "$2" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" "$3" "$4" "$5" "$6" >> "$root/state-v1.tsv"; chmod 600 "$root/state-v1.tsv"; }
failure(){ [[ -f "$root/failure-v1.tsv" ]] || printf '%s\n' $'recorded_at\tgate\tcell\texit_status\tcommand\tstdout_sha256\tstderr_sha256' > "$root/failure-v1.tsv"; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$gate" "$1" "$2" "$3" "$4" "$5" >> "$root/failure-v1.tsv"; chmod 600 "$root/failure-v1.tsv"; }
manifest(){ local tmp="$root/.manifest.tmp"; /usr/bin/jq --arg s "$1" --arg t "$2" '.status=$s|.completedAt=(if $t==""then null else $t end)' "$root/manifest-v1.json" > "$tmp"; chmod 600 "$tmp"; /bin/mv "$tmp" "$root/manifest-v1.json"; }
reusable(){ local n o e os es; for n in 1 2 3 4 5 6; do /usr/bin/awk -F $'\t' -v g="$gate" -v n="$n" -v s="$source_digest_value" -v c="$config_digest_value" -v t="$toolchain_digest_value" '$1==g&&$2==n&&$3=="pass"&&$4==s&&$5==c&&$6==t{f=1}END{exit f?0:1}' "$root/state-v1.tsv" || return 1; o="$root/cell-$(printf '%02d' "$n").stdout.log"; e="$root/cell-$(printf '%02d' "$n").stderr.log"; [[ -f "$o" && -f "$e" ]] || return 1; os="$(/usr/bin/awk -F $'\t' -v n="$n" '$2==n&&$3=="pass"{x=$9}END{print x}' "$root/state-v1.tsv")"; es="$(/usr/bin/awk -F $'\t' -v n="$n" '$2==n&&$3=="pass"{x=$10}END{print x}' "$root/state-v1.tsv")"; [[ "$(sha "$o")" == "$os" && "$(sha "$e")" == "$es" ]] || return 1; done; }
verify(){ local tmp status=0; [[ -f "$root/evidence-v1.sha256" && ! -L "$root/evidence-v1.sha256" && -f "$root/evidence-v1.cms" && ! -L "$root/evidence-v1.cms" ]] || return 1; tmp="$(/usr/bin/mktemp /tmp/hostwright-phase09-gate09.XXXXXX)"; security cms -D -u 9 -i "$root/evidence-v1.cms" -o "$tmp" >/dev/null 2>&1 || status=1; /usr/bin/cmp -s "$root/evidence-v1.sha256" "$tmp" || status=1; (cd "$root" && /usr/bin/shasum -a 256 -c evidence-v1.sha256 >/dev/null) || status=1; /bin/unlink "$tmp"; [[ "$status" == 0 ]]; }
release(){ if [[ "$run_succeeded" == 1 && "$root_lock_created" == 1 && "$gate_lock_created" == 1 ]]; then /bin/rmdir "$root/active-run-v1"; /bin/rmdir "$parent/.phase09-gate09-active-v1"; root_lock_created=0; gate_lock_created=0; fi; }
write_digest(){ (cd "$root"; for f in manifest-v1.json state-v1.tsv ownership-v1.tsv toolchain-v1.txt gate-active-run-v1-info.tsv cell-*.stdout.log cell-*.stderr.log; do [[ -f "$f" ]] && /usr/bin/shasum -a 256 "$f"; done | LC_ALL=C sort) > "$root/evidence-v1.sha256"; chmod 600 "$root/evidence-v1.sha256"; security cms -S -N "$signing_identity" -H SHA256 -u 9 -i "$root/evidence-v1.sha256" -o "$root/evidence-v1.cms"; chmod 600 "$root/evidence-v1.cms"; }
on_exit(){ local status=$?; trap - EXIT; emergency_live_cleanup || true; release || true; exit "$status"; }
cell_timeout(){ case "$1" in 3) printf '%s\n' 1800;; 6) printf '%s\n' 2400;; *) printf '%s\n' 1200;; esac; }
terminate_cell_group(){ local pgid="$1" n; kill -TERM -- "-$pgid" 2>/dev/null || return 0; for n in {1..50}; do kill -0 -- "-$pgid" 2>/dev/null || return 0; /bin/sleep .1; done; kill -KILL -- "-$pgid" 2>/dev/null || true; }
run(){ prepared; if [[ -e "$root/evidence-v1.sha256" || -e "$root/evidence-v1.cms" ]]; then [[ "$(/usr/bin/jq -r .status "$root/manifest-v1.json")" == passed ]] && reusable && verify || die 'completed evidence is incomplete or changed; preserve this root and do not rerun.' 73; printf '%s\n' 'Gate 9 evidence is valid and reused; no cells were rerun.'; return; fi; local lock="$parent/.phase09-gate09-active-v1" n cmd out err start end status cell_pid watchdog; [[ ! -e "$root/active-run-v1" && ! -e "$lock" ]] || die 'An active Gate 9 qualification already exists; do not duplicate it.' 75; mkdir "$lock"; chmod 700 "$lock"; printf '%s\n' $'root\tpid\tstarted_at\tsource_digest\tconfig_digest\ttoolchain_digest' > "$lock/info-v1.tsv"; printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$root" "$$" "$(now)" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" >> "$lock/info-v1.tsv"; chmod 600 "$lock/info-v1.tsv"; gate_lock_created=1; mkdir "$root/active-run-v1"; chmod 700 "$root/active-run-v1"; root_lock_created=1; trap on_exit EXIT; for n in 1 2 3 4 5 6; do revalidate_dependencies; cmd="$(cell_command "$n")"; out="$root/cell-$(printf '%02d' "$n").stdout.log"; err="$root/cell-$(printf '%02d' "$n").stderr.log"; [[ ! -e "$out" && ! -e "$err" ]] || die 'Cell logs already exist; preserve this root and do not rerun.' 73; start="$(now)"; set +e; set -m; (set -e; run_cell "$n") > "$out" 2> "$err" & cell_pid=$!; set +m; /usr/bin/perl -e '$p=shift;$s=shift;sleep $s;kill 15,-$p;sleep 5;kill 9,-$p' "$cell_pid" "$(cell_timeout "$n")" & watchdog=$!; wait "$cell_pid"; status=$?; kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null; [[ "$status" == 0 ]] || terminate_cell_group "$cell_pid"; set -e; chmod 600 "$out" "$err"; end="$(now)"; if [[ "$status" != 0 ]]; then state "$n" failed "$start" "$end" "$(sha "$out")" "$(sha "$err")"; failure "$n" "$status" "$cmd" "$(sha "$out")" "$(sha "$err")"; manifest failed "$end"; die "Gate 9 cell $n failed; progress is frozen and locks are preserved." "$status"; fi; revalidate_dependencies; state "$n" pass "$start" "$end" "$(sha "$out")" "$(sha "$err")"; done; manifest passed "$(now)"; /bin/cp "$lock/info-v1.tsv" "$root/gate-active-run-v1-info.tsv"; chmod 600 "$root/gate-active-run-v1-info.tsv"; write_digest; /bin/unlink "$lock/info-v1.tsv"; run_succeeded=1; release; printf '%s\n' 'Gate 9 qualification passed.'; }
main(){ [[ "$#" -ge 1 ]] || die 'usage: phase09-gate09-qualification.sh <contract|prepare|run>.' 64; case "$1" in contract) [[ "$#" == 1 ]] || die 'contract accepts no arguments.' 64; contract;; prepare) [[ "$#" == 2 && "$2" == 9 ]] || die 'Gate 9 harness accepts only prepare 9.' 64; validate_worktree; validate_root; empty_root; collect; prepare; printf '%s\n' 'Gate 9 evidence root prepared.';; run) [[ "$#" == 2 && "$2" == 9 ]] || die 'Gate 9 harness accepts only run 9.' 64; validate_worktree; validate_root; collect; run;; *) die 'unknown qualification command.' 64;; esac; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
