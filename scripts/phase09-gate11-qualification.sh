#!/usr/bin/env bash
set -euo pipefail

readonly schema='hostwright.phase09.gate11.qualification.manifest.v1'
readonly gate=11
readonly readonly_branch='feat/v0.0.2-phase-09'
readonly live_parent='/Volumes/T9/hostwright/qualification'
readonly signing_identity='Developer ID Application: Dev Trivedi (993YC3JY4Q)'
readonly signing_fingerprint='A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB'
readonly service_identifier='dev.hostwright.xpc-provider'
readonly entitlement_source='/Users/dev/Documents/hostwright-phase09/scripts/phase09-xpc-provider.entitlements'
readonly entitlement_digest='46db84bf46218f3cc65bc5e5daaf5c900028b537c64718bb5738b6392d2e31fc'
readonly state_header=$'gate\tcell\tstatus\tsource_digest\tconfig_digest\ttoolchain_digest\tstarted_at\tfinished_at\tstdout_sha256\tstderr_sha256'
readonly ownership_header=$'recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity'

root='' parent='' source_commit='' source_digest_value='' config_digest_value=''
toolchain_digest_value='' root_lock_created=0 gate_lock_created=0 run_succeeded=0 cleanup_completed=0

die() { printf '%s\n' "$1" >&2; exit "${2:-70}"; }
now() { /bin/date -u +%Y-%m-%dT%H:%M:%SZ; }
sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
stream_sha() { /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'; }
testing() { [[ "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" == 1 ]]; }

contract() {
  /bin/echo 'Phase 09 Gate 11 qualification harness contract v1
Gate 11 — 68.75% — signed XPC provider boundary (#204).
Exactly one Gate 11 qualification may be active. Cells 1..6 run strictly serially as
U, I, L, M, S, and R evidence. The harness binds the exact sandbox-only entitlement,
Developer ID identity, configured notarization profile, notarization and stapling evidence,
reciprocal XPC code requirements, bounded v1 messages, crash/cancel/revoke behavior, signed
evidence, and owned-only temporary XPC cleanup.'
}

qualification_parent() {
  if testing; then
    : "${HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT:?test parent required}"
    printf '%s\n' "$HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT"
  else
    printf '%s\n' "$live_parent"
  fi
}

validate_worktree() {
  [[ "$(git branch --show-current)" == "$readonly_branch" ]] || die "Gate 11 requires branch $readonly_branch." 66
  [[ "$(/bin/realpath "$(git rev-parse --show-toplevel)")" == /Users/dev/Documents/hostwright-phase09 ]] || die 'Gate 11 requires the isolated Phase 09 worktree.' 66
}

validate_root() {
  : "${HOSTWRIGHT_PHASE09_GATE_ROOT:?HOSTWRIGHT_PHASE09_GATE_ROOT is required}"
  root="$HOSTWRIGHT_PHASE09_GATE_ROOT"; parent="$(qualification_parent)"
  local canonical
  canonical="$(/bin/realpath "$parent")"
  [[ -d "$parent" && ! -L "$parent" && "$canonical" == "$parent" ]] || die 'qualification parent must be private canonical and non-symlinked.' 66
  if testing; then
    [[ "$canonical" == /private/var/folders/*/T/hostwright-phase09-gate11-harness-* || "$canonical" == /var/folders/*/T/hostwright-phase09-gate11-harness-* ]] || die 'test parent must be private canonical and isolated.' 66
  else
    [[ "$canonical" == "$live_parent" ]] || die 'Gate 11 evidence must use the fixed qualification parent.' 66
  fi
  [[ "$root" == /* && -d "$root" && ! -L "$root" && "$(/bin/realpath "$root")" == "$root" && "$(/bin/realpath "$(dirname "$root")")" == "$canonical" ]] || die 'evidence root must be private canonical and non-symlinked.' 66
  [[ "${root##*/}" =~ ^phase09-gate11-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || die 'Gate 11 evidence root has an invalid name.' 66
  [[ "$(stat -f '%Su' "$root")" == "$(id -un)" && "$(stat -f '%Lp' "$root")" == 700 ]] || die 'Gate 11 evidence root must be owned by the current user with mode 0700.' 66
}

empty_root() {
  [[ -z "$(/usr/bin/find "$root" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die 'Gate 11 evidence root must be empty.' 73
}

clean_source() {
  git diff --quiet || die 'Gate 11 source must be clean and committed.' 73
  git diff --cached --quiet || die 'Gate 11 source must be clean and committed.' 73
  local dirty
  dirty="$(git status --porcelain=v1 --untracked-files=all | /usr/bin/awk '$2 !~ /^tmp\// {print}')"
  [[ -z "$dirty" ]] || die 'Gate 11 source must be clean and committed.' 73
}

source_digest() { { git ls-files -s; git submodule status --recursive 2>/dev/null || true; } | stream_sha; }

config_digest() {
  local files=(
    Package.swift Package.resolved contracts/v0.0.2/phase09-xpc-v1.json
    contracts/v0.0.2/phase09-xpc-response-completed-v1.json
    contracts/v0.0.2/phase09-xpc-response-cancelled-v1.json
    contracts/v0.0.2/phase09-xpc-response-error-v1.json
    scripts/phase09-xpc-provider.entitlements scripts/phase09-gate11-live.sh
    scripts/phase09-gate11-qualification.sh docs/architecture/phase09-control-plane-contracts.md
  ) file
  for file in "${files[@]}"; do printf '%s  %s\n' "$(sha "$file")" "$file"; done | stream_sha
}

validate_entitlements() {
  [[ -f "$entitlement_source" && ! -L "$entitlement_source" ]] || die 'The frozen XPC entitlement file is unavailable or unsafe.' 69
  [[ "$(sha "$entitlement_source")" == "$entitlement_digest" ]] || die 'The XPC entitlement content no longer matches the frozen sandbox-only contract.' 69
  /usr/bin/plutil -lint "$entitlement_source" >/dev/null
  [[ "$(/usr/bin/plutil -convert json -o - "$entitlement_source" | /usr/bin/jq -cS .)" == '{"com.apple.security.app-sandbox":true}' ]] || die 'The XPC entitlement set is not sandbox-only.' 69
}

notary_profile_snapshot() {
  if testing; then
    printf 'notary-profile-configured=testing\n'
    return
  fi
  : "${HOSTWRIGHT_NOTARY_PROFILE:?HOSTWRIGHT_NOTARY_PROFILE is required for Gate 11 notarization}"
  printf 'notary-profile-configured=true\nnotary-profile-name-sha256=%s\n' \
    "$(printf '%s' "$HOSTWRIGHT_NOTARY_PROFILE" | stream_sha)"
}

toolchain_snapshot() {
  validate_entitlements
  /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F "$signing_fingerprint" | /usr/bin/grep -F "$signing_identity" >/dev/null || die 'The pinned Developer ID signing identity is unavailable.' 69
  /usr/bin/xcrun --find notarytool >/dev/null
  /usr/bin/xcrun --find stapler >/dev/null
  /usr/bin/xcrun --find codesign >/dev/null
  /usr/bin/xcodebuild -version
  /usr/bin/swift --version
  /usr/bin/sw_vers
  /usr/bin/xcrun notarytool --version
  printf 'signing-identity=%s\nsigning-fingerprint=%s\nservice-identifier=%s\nentitlement-sha256=%s\n' \
    "$signing_identity" "$signing_fingerprint" "$service_identifier" "$entitlement_digest"
  notary_profile_snapshot
}

toolchain_digest() { toolchain_snapshot | stream_sha; }

collect() {
  testing || clean_source
  source_commit="$(git rev-parse HEAD)"; source_digest_value="$(source_digest)"
  config_digest_value="$(config_digest)"; toolchain_digest_value="$(toolchain_digest)"
}

prepare() {
  toolchain_snapshot > "$root/toolchain-v1.txt"
  printf '%s\n' "$state_header" > "$root/state-v1.tsv"
  printf '%s\n' "$ownership_header" > "$root/ownership-v1.tsv"
  /usr/bin/jq -n \
    --arg schema "$schema" --arg commit "$source_commit" --arg source "$source_digest_value" \
    --arg config "$config_digest_value" --arg toolchain "$toolchain_digest_value" \
    --arg signingIdentity "$signing_identity" --arg signingFingerprint "$signing_fingerprint" \
    --arg serviceIdentifier "$service_identifier" --arg entitlementDigest "$entitlement_digest" \
    '{schema:$schema,gate:11,status:"prepared",preparedAt:(now|todate),completedAt:null,
      sourceCommit:$commit,sourceDigest:$source,configDigest:$config,toolchainDigest:$toolchain,
      cellOrder:[1,2,3,4,5,6],externalPrerequisites:{signingIdentity:$signingIdentity,
      signingFingerprint:$signingFingerprint,serviceIdentifier:$serviceIdentifier,
      entitlementDigest:$entitlementDigest,notaryProfileConfigured:true}}' > "$root/manifest-v1.json"
  chmod 600 "$root/manifest-v1.json" "$root/state-v1.tsv" "$root/ownership-v1.tsv" "$root/toolchain-v1.txt"
}

prepared() {
  [[ -f "$root/manifest-v1.json" && ! -L "$root/manifest-v1.json" ]] || die 'Gate 11 evidence root is not prepared.' 73
  [[ "$(/usr/bin/jq -r .schema "$root/manifest-v1.json")" == "$schema" ]] || die 'Gate 11 manifest schema mismatch.' 73
  [[ "$(/usr/bin/jq -r .status "$root/manifest-v1.json")" == prepared || "$(/usr/bin/jq -r .status "$root/manifest-v1.json")" == passed ]] || die 'Gate 11 evidence is frozen after failure.' 73
  [[ "$(/usr/bin/jq -r .sourceDigest "$root/manifest-v1.json")" == "$source_digest_value" && "$(/usr/bin/jq -r .configDigest "$root/manifest-v1.json")" == "$config_digest_value" && "$(/usr/bin/jq -r .toolchainDigest "$root/manifest-v1.json")" == "$toolchain_digest_value" ]] || die 'prepared evidence dependencies changed; preserve this root.' 73
}

revalidate_dependencies() {
  [[ "$(source_digest)" == "$source_digest_value" && "$(config_digest)" == "$config_digest_value" && "$(toolchain_digest)" == "$toolchain_digest_value" ]] || die 'prepared evidence dependencies changed; preserve this root.' 73
}

record_root() {
  local path="$1" identifier="${2:-gate11-xpc-live}"
  [[ -d "$path" && ! -L "$path" && "$path" == "$root"/* ]] || die 'temporary XPC root is unsafe.'
  printf '%s\ttemporary-root\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$identifier" "$path" "$(stat -f '%d' "$path")" "$(stat -f '%i' "$path")" 'owned=gate11' >> "$root/ownership-v1.tsv"
}

record_artifact() {
  local kind="$1" identifier="$2" path="$3"
  [[ -e "$path" && ! -L "$path" && "$path" == "$root"/* ]] || die 'Gate 11 artifact is unsafe.'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$kind" "$identifier" "$path" "$(stat -f '%d' "$path")" "$(stat -f '%i' "$path")" 'owned=gate11' >> "$root/ownership-v1.tsv"
}

cleanup() {
  [[ "$cleanup_completed" == 0 ]] || return 0
  if [[ -z "$root" || ! -f "$root/ownership-v1.tsv" ]]; then cleanup_completed=1; return 0; fi
  local path device inode
  while IFS=$'\t' read -r path device inode; do
    [[ -e "$path" ]] || continue
    [[ -d "$path" && ! -L "$path" && "$(stat -f '%d' "$path")" == "$device" && "$(stat -f '%i' "$path")" == "$inode" ]] || die 'temporary XPC root identity changed; cleanup is refused.' 124
    [[ -z "$(/usr/bin/find "$path" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die 'temporary XPC root is not empty; cleanup is frozen.' 124
    /bin/rmdir "$path"
  done < <(/usr/bin/awk -F $'\t' '$2=="temporary-root"{print length($4)"\t"$4"\t"$5"\t"$6}' "$root/ownership-v1.tsv" | /usr/bin/sort -rn | /usr/bin/cut -f2-)
  cleanup_completed=1
}

live() {
  : "${HOSTWRIGHT_NOTARY_PROFILE:?HOSTWRIGHT_NOTARY_PROFILE is required for Gate 11 notarization}"
  swift build --jobs 1 --product hostwright-xpc-provider-service
  swift build --jobs 1 --product hostwright-xpc-provider-qualification
  local host_bin live_root
  host_bin="$(swift build --show-bin-path)"
  live_root="$root/live-xpc-v1"; mkdir "$live_root"; chmod 700 "$live_root"; record_root "$live_root"
  HOSTWRIGHT_XPC_REQUIRE_NOTARY=1 \
    HOSTWRIGHT_NOTARY_PROFILE="$HOSTWRIGHT_NOTARY_PROFILE" \
    HOSTWRIGHT_XPC_LIVE_ROOT="$live_root" \
    HOSTWRIGHT_XPC_OWNERSHIP_LEDGER="$root/ownership-v1.tsv" \
    HOSTWRIGHT_XPC_HOST_BIN="$host_bin" \
    scripts/phase09-gate11-live.sh
}

cell_command() {
  case "$1" in
    1) printf '%s\n' 'swift test --jobs 1 --filter XPC contract and codec unit methods' ;;
    2) printf '%s\n' 'swift build --jobs 1 for XPC service and qualification client' ;;
    3) printf '%s\n' 'signed, sandboxed, notarized and stapled XPC live boundary qualification' ;;
    4) printf '%s\n' 'swift test --jobs 1 --filter frozen XPC response/request fixtures and ControlPlaneContractTests' ;;
    5) printf '%s\n' 'swift test --jobs 1 --filter malformed, oversized, requirement, and entitlement security methods' ;;
    6) printf '%s\n' 'swift test --jobs 1 --filter Phase09Gate11QualificationHarnessTests; builds; lint; docs' ;;
    *) die 'unknown Gate 11 cell.' ;;
  esac
}

run_cell() {
  case "$1" in
    1) swift test --jobs 1 --filter 'XPCProviderCodecTests/testRequestAndCancelRoundTripThroughExactDictionary|XPCProviderCodecTests/testEveryResponseShapeRoundTripsAndCannotOverlap|Phase09XPCContractTests/testRequestAndCancellationCombinationsAreExclusiveAndBounded|Phase09XPCContractTests/testResponseStatusPayloadsAreMutuallyExclusive|Phase09XPCContractTests/testCodeIdentityProofAcceptsOnlyLowercaseFortyOrSixtyFourCharacterCDHashes' ;;
    2) swift build --jobs 1 --product hostwright-xpc-provider-service; swift build --jobs 1 --product hostwright-xpc-provider-qualification ;;
    3) live ;;
    4) swift test --jobs 1 --filter 'Phase09XPCContractTests/testFrozenRequestFixtureRoundTrips|Phase09XPCContractTests/testFrozenResponseFixturesRoundTripExactShapes|ControlPlaneContractTests/testXPCProtocolAndExactEntitlement|ControlPlaneContractTests/testEveryGoldenStrictlyDecodesAndRejectsUnknownFields' ;;
    5) swift test --jobs 1 --filter 'XPCProviderCodecTests/testUnknownOversizedAndWrongTypedFieldsFailClosed|XPCProviderCodecTests/testFrozenRequirementsAndServiceNameValidation|Phase09XPCContractTests/testFrozenServiceIdentityAndSandboxEntitlementAreExact' ;;
    6) swift test --jobs 1 --filter 'Phase09Gate11QualificationHarnessTests'; swift build --jobs 1 --product hostwright-xpc-provider-service; swift build --jobs 1 --product hostwright-xpc-provider-qualification; scripts/lint.sh; git diff --check; scripts/check-docs.sh ;;
    *) die 'unknown Gate 11 cell.' ;;
  esac
}

state() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$gate" "$1" "$2" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" "$3" "$4" "$5" "$6" >> "$root/state-v1.tsv"; chmod 600 "$root/state-v1.tsv"; }
failure() { [[ -f "$root/failure-v1.tsv" ]] || printf '%s\n' $'recorded_at\tgate\tcell\texit_status\tcommand\tstdout_sha256\tstderr_sha256' > "$root/failure-v1.tsv"; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$gate" "$1" "$2" "$3" "$4" "$5" >> "$root/failure-v1.tsv"; chmod 600 "$root/failure-v1.tsv"; }
manifest() { local tmp="$root/.manifest.tmp"; /usr/bin/jq --arg s "$1" --arg t "$2" '.status=$s|.completedAt=(if $t=="" then null else $t end)' "$root/manifest-v1.json" > "$tmp"; chmod 600 "$tmp"; /bin/mv "$tmp" "$root/manifest-v1.json"; }

reusable() {
  local n out err expected_out expected_err
  for n in 1 2 3 4 5 6; do
    /usr/bin/awk -F $'\t' -v g="$gate" -v n="$n" -v s="$source_digest_value" -v c="$config_digest_value" -v t="$toolchain_digest_value" '$1==g&&$2==n&&$3=="pass"&&$4==s&&$5==c&&$6==t{f=1}END{exit f?0:1}' "$root/state-v1.tsv" || return 1
    out="$root/cell-$(printf '%02d' "$n").stdout.log"; err="$root/cell-$(printf '%02d' "$n").stderr.log"
    [[ -f "$out" && -f "$err" ]] || return 1
    expected_out="$(/usr/bin/awk -F $'\t' -v n="$n" '$2==n&&$3=="pass"{x=$9}END{print x}' "$root/state-v1.tsv")"
    expected_err="$(/usr/bin/awk -F $'\t' -v n="$n" '$2==n&&$3=="pass"{x=$10}END{print x}' "$root/state-v1.tsv")"
    [[ "$(sha "$out")" == "$expected_out" && "$(sha "$err")" == "$expected_err" ]] || return 1
  done
}

verify() {
  local decoded status=0
  [[ -f "$root/evidence-v1.sha256" && ! -L "$root/evidence-v1.sha256" && -f "$root/evidence-v1.cms" && ! -L "$root/evidence-v1.cms" ]] || return 1
  decoded="$(/usr/bin/mktemp /tmp/hostwright-phase09-gate11.XXXXXX)"
  security cms -D -u 9 -i "$root/evidence-v1.cms" -o "$decoded" >/dev/null 2>&1 || status=1
  /usr/bin/cmp -s "$root/evidence-v1.sha256" "$decoded" || status=1
  (cd "$root" && /usr/bin/shasum -a 256 -c evidence-v1.sha256 >/dev/null) || status=1
  /bin/unlink "$decoded"
  [[ "$status" == 0 ]]
}

release() {
  if [[ "$run_succeeded" == 1 && "$root_lock_created" == 1 && "$gate_lock_created" == 1 ]]; then
    /bin/rmdir "$root/active-run-v1"; /bin/rmdir "$parent/.phase09-gate11-active-v1"
    root_lock_created=0; gate_lock_created=0
  fi
}

write_digest() {
  local completed_at="$1" manifest_tmp="$root/.manifest-passed.tmp"
  local digest_tmp="$root/.evidence-v1.sha256.tmp" cms_tmp="$root/.evidence-v1.cms.tmp"
  local decoded_tmp="$root/.evidence-v1.decoded.tmp" file expected actual
  [[ ! -e "$manifest_tmp" && ! -e "$digest_tmp" && ! -e "$cms_tmp" && ! -e "$decoded_tmp" ]] \
    || die 'Gate 11 evidence sealing temporaries already exist; preserve this root.' 73
  /usr/bin/jq --arg t "$completed_at" '.status="passed"|.completedAt=$t' \
    "$root/manifest-v1.json" > "$manifest_tmp"
  chmod 600 "$manifest_tmp"
  {
    printf '%s  manifest-v1.json\n' "$(sha "$manifest_tmp")"
    (cd "$root"; for file in state-v1.tsv ownership-v1.tsv toolchain-v1.txt gate-active-run-v1-info.tsv cell-*.stdout.log cell-*.stderr.log; do [[ -f "$file" ]] && /usr/bin/shasum -a 256 "$file"; done)
  } | LC_ALL=C /usr/bin/sort > "$digest_tmp"
  chmod 600 "$digest_tmp"
  security cms -S -N "$signing_identity" -H SHA256 -u 9 -i "$digest_tmp" -o "$cms_tmp"
  chmod 600 "$cms_tmp"
  security cms -D -u 9 -i "$cms_tmp" -o "$decoded_tmp" >/dev/null 2>&1
  /usr/bin/cmp -s "$digest_tmp" "$decoded_tmp" || die 'Gate 11 staged CMS evidence did not round-trip.' 74
  while read -r expected file; do
    if [[ "$file" == manifest-v1.json ]]; then actual="$(sha "$manifest_tmp")"; else actual="$(sha "$root/$file")"; fi
    [[ "$actual" == "$expected" ]] || die 'Gate 11 staged evidence digest verification failed.' 74
  done < "$digest_tmp"
  /bin/unlink "$decoded_tmp"
  /bin/mv "$digest_tmp" "$root/evidence-v1.sha256"
  /bin/mv "$cms_tmp" "$root/evidence-v1.cms"
}

on_exit() { local status=$?; trap - EXIT; cleanup || status=$?; release || status=$?; exit "$status"; }
cell_timeout() { case "$1" in 3) printf '%s\n' 7200 ;; 6) printf '%s\n' 2400 ;; *) printf '%s\n' 1200 ;; esac; }
terminate_cell_group() { local pgid="$1" n; kill -TERM -- "-$pgid" 2>/dev/null || return 0; for n in {1..50}; do kill -0 -- "-$pgid" 2>/dev/null || return 0; /bin/sleep .1; done; kill -KILL -- "-$pgid" 2>/dev/null || true; }

run() {
  prepared
  if [[ -e "$root/evidence-v1.sha256" || -e "$root/evidence-v1.cms" ]]; then
    [[ "$(/usr/bin/jq -r .status "$root/manifest-v1.json")" == passed ]] && reusable && verify || die 'completed evidence is incomplete or changed; preserve this root and do not rerun.' 73
    printf '%s\n' 'Gate 11 evidence is valid and reused; no cells were rerun.'; return
  fi
  local lock="$parent/.phase09-gate11-active-v1" n cmd out err start end status cell_pid watchdog
  [[ ! -e "$root/active-run-v1" && ! -e "$lock" ]] || die 'An active Gate 11 qualification already exists; do not duplicate it.' 75
  mkdir "$lock"; chmod 700 "$lock"
  printf '%s\n' $'root\tpid\tstarted_at\tsource_digest\tconfig_digest\ttoolchain_digest' > "$lock/info-v1.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$root" "$$" "$(now)" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" >> "$lock/info-v1.tsv"
  chmod 600 "$lock/info-v1.tsv"; gate_lock_created=1
  mkdir "$root/active-run-v1"; chmod 700 "$root/active-run-v1"; root_lock_created=1
  trap on_exit EXIT
  for n in 1 2 3 4 5 6; do
    revalidate_dependencies; cmd="$(cell_command "$n")"
    out="$root/cell-$(printf '%02d' "$n").stdout.log"; err="$root/cell-$(printf '%02d' "$n").stderr.log"
    [[ ! -e "$out" && ! -e "$err" ]] || die 'Cell logs already exist; preserve this root and do not rerun.' 73
    start="$(now)"; set +e; set -m
    (set -e; run_cell "$n") > "$out" 2> "$err" & cell_pid=$!
    set +m
    /usr/bin/perl -e '$p=shift;$s=shift;sleep $s;kill 15,-$p;sleep 5;kill 9,-$p' "$cell_pid" "$(cell_timeout "$n")" & watchdog=$!
    wait "$cell_pid"; status=$?
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
    [[ "$status" == 0 ]] || terminate_cell_group "$cell_pid"
    set -e; chmod 600 "$out" "$err"; end="$(now)"
    if [[ "$status" != 0 ]]; then
      state "$n" failed "$start" "$end" "$(sha "$out")" "$(sha "$err")"
      failure "$n" "$status" "$cmd" "$(sha "$out")" "$(sha "$err")"
      manifest failed "$end"
      die "Gate 11 cell $n failed; progress is frozen and locks are preserved." "$status"
    fi
    revalidate_dependencies
    state "$n" pass "$start" "$end" "$(sha "$out")" "$(sha "$err")"
  done
  cleanup
  local completed_at="$(now)"
  /bin/cp "$lock/info-v1.tsv" "$root/gate-active-run-v1-info.tsv"; chmod 600 "$root/gate-active-run-v1-info.tsv"
  write_digest "$completed_at"
  /bin/unlink "$lock/info-v1.tsv"
  run_succeeded=1
  release
  /bin/mv "$root/.manifest-passed.tmp" "$root/manifest-v1.json"
  printf '%s\n' 'Gate 11 qualification passed.'
}

main() {
  [[ "$#" -ge 1 ]] || die 'usage: phase09-gate11-qualification.sh <contract|prepare|run>.' 64
  case "$1" in
    contract) [[ "$#" == 1 ]] || die 'contract accepts no arguments.' 64; contract ;;
    prepare) [[ "$#" == 2 && "$2" == 11 ]] || die 'Gate 11 harness accepts only prepare 11.' 64; validate_worktree; validate_root; empty_root; collect; prepare; printf '%s\n' 'Gate 11 evidence root prepared.' ;;
    run) [[ "$#" == 2 && "$2" == 11 ]] || die 'Gate 11 harness accepts only run 11.' 64; validate_worktree; validate_root; collect; run ;;
    *) die 'unknown qualification command.' 64 ;;
  esac
}
main "$@"
