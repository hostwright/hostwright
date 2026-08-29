#!/usr/bin/env bash
set -euo pipefail

readonly schema='hostwright.phase09.gate10.qualification.manifest.v1'
readonly gate=10
readonly readonly_branch='feat/v0.0.2-phase-09'
readonly live_parent='/Volumes/T9/hostwright/qualification'
readonly signing_identity='Developer ID Application: Dev Trivedi (993YC3JY4Q)'
readonly swift_executable='/Users/dev/.swiftly/bin/swift'
readonly swift_version='6.3.3'
readonly wasm_sdk='swift-6.3.3-RELEASE_wasm'
readonly wasm_sdk_checksum='cabfa08b73bb8ac783927ecd15fa386e99d0c139c5f232445067bcf58379cae7'
readonly wasm_sdk_bundle='/Users/dev/Library/org.swift.swiftpm/swift-sdks/swift-6.3.3-RELEASE_wasm.artifactbundle'
readonly wasm_sdk_bundle_digest='ef888f82c39bc4d1f9202842547252699321868fcc1751e6a33acbd4507d9f5a'
readonly wasm_scratch='/Users/dev/Documents/hostwright-phase09/.build/phase09-wasi'
readonly state_header=$'gate\tcell\tstatus\tsource_digest\tconfig_digest\ttoolchain_digest\tstarted_at\tfinished_at\tstdout_sha256\tstderr_sha256'
readonly ownership_header=$'recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity'

root='' parent='' source_commit='' source_digest_value='' config_digest_value=''
toolchain_digest_value='' process_identity_tool=''
root_lock_created=0 gate_lock_created=0 run_succeeded=0 cleanup_completed=0

die() { printf '%s\n' "$1" >&2; exit "${2:-70}"; }
now() { /bin/date -u +%Y-%m-%dT%H:%M:%SZ; }
sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
stream_sha() { /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'; }
testing() { [[ "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" == 1 ]]; }

contract() { /bin/echo 'Phase 09 Gate 10 qualification harness contract v1
Gate 10 — 62.50% — Swift WASI provider SDK (#203).
Exactly one Gate 10 qualification may be active. Cells 1..6 run strictly serially as
U, I, L+interop, M, S, and R evidence. The harness binds the official Swift 6.3.3 WASM
SDK and pinned WasmKit/WasmKitWASI runtime, a fresh-instance Preview1 command boundary,
no preopened directories, no inherited environment or ambient host access, deterministic
inputs, explicit grants, bounded resources, reference/adversarial guests, conformance,
deadline/revocation recovery, signed evidence, and owned-only provider-worker/guest cleanup.'; }

qualification_parent() {
  if testing; then
    : "${HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT:?test parent required}"
    printf '%s\n' "$HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT"
  else
    printf '%s\n' "$live_parent"
  fi
}

validate_worktree() {
  local top
  top="$(/bin/realpath "$(git rev-parse --show-toplevel)")"
  if testing; then
    [[ "$top" != /Users/dev/Documents/hostwright ]] || die "Gate 10 requires branch $readonly_branch." 66
    return
  fi
  [[ "$(git branch --show-current)" == "$readonly_branch" ]] || die "Gate 10 requires branch $readonly_branch." 66
  [[ "$top" == /Users/dev/Documents/hostwright-phase09 ]] || die 'Gate 10 requires the isolated Phase 09 worktree.' 66
}

validate_root() {
  : "${HOSTWRIGHT_PHASE09_GATE_ROOT:?HOSTWRIGHT_PHASE09_GATE_ROOT is required}"
  root="$HOSTWRIGHT_PHASE09_GATE_ROOT"
  parent="$(qualification_parent)"
  local canonical
  canonical="$(/bin/realpath "$parent")"
  [[ -d "$parent" && ! -L "$parent" && "$canonical" == "$parent" ]] || die 'qualification parent must be private canonical and non-symlinked.' 66
  if testing; then
    [[ "$canonical" == /private/var/folders/*/T/hostwright-phase09-gate10-harness-* || "$canonical" == /var/folders/*/T/hostwright-phase09-gate10-harness-* ]] || die 'test parent must be private canonical and isolated.' 66
  else
    [[ "$canonical" == "$live_parent" ]] || die 'Gate 10 evidence must use the fixed qualification parent.' 66
  fi
  [[ "$root" == /* && -d "$root" && ! -L "$root" && "$(/bin/realpath "$root")" == "$root" && "$(/bin/realpath "$(dirname "$root")")" == "$canonical" ]] || die 'evidence root must be private canonical and non-symlinked.' 66
  [[ "${root##*/}" =~ ^phase09-gate10-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || die 'Gate 10 evidence root has an invalid name.' 66
  [[ "$(stat -f '%Su' "$root")" == "$(id -un)" && "$(stat -f '%Lp' "$root")" == 700 ]] || die 'Gate 10 evidence root must be owned by the current user with mode 0700.' 66
}

empty_root() {
  [[ -z "$(/usr/bin/find "$root" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die 'Gate 10 evidence root must be empty.' 73
}

clean_source() {
  git diff --quiet || die 'Gate 10 source must be clean and committed.' 73
  git diff --cached --quiet || die 'Gate 10 source must be clean and committed.' 73
  local dirty
  dirty="$(git status --porcelain=v1 --untracked-files=all | /usr/bin/awk '$2 !~ /^tmp\// {print}')"
  [[ -z "$dirty" ]] || die 'Gate 10 source must be clean and committed.' 73
}

source_digest() {
  { git ls-files -s; git submodule status --recursive 2>/dev/null || true; } | stream_sha
}

config_digest() {
  local files=(
    Package.swift Package.resolved
    contracts/v0.0.2/phase09-plugin-invocation-v1.json
    contracts/v0.0.2/phase09-plugin-v1.json
    docs/architecture/phase09-control-plane-contracts.md
    scripts/phase09-gate10-qualification.sh
  )
  for file in "${files[@]}"; do printf '%s  %s\n' "$(sha "$file")" "$file"; done | stream_sha
}

toolchain_snapshot() {
  [[ -x "$swift_executable" ]] || die 'The pinned Swiftly Swift executable is unavailable.' 69
  "$swift_executable" --version
  "$swift_executable" sdk list
  local installed_digest
  installed_digest="$(expanded_sdk_digest)"
  [[ "$installed_digest" == "$wasm_sdk_bundle_digest" ]] || die 'The installed Swift WASM SDK bundle digest does not match the frozen official installation.' 69
  printf 'swift-executable=%s\nswift-version=%s\nwasm-sdk=%s\nwasm-sdk-archive-checksum=%s\nwasm-sdk-bundle=%s\nwasm-sdk-bundle-digest=%s\n' \
    "$swift_executable" "$swift_version" "$wasm_sdk" "$wasm_sdk_checksum" "$wasm_sdk_bundle" "$installed_digest"
}

expanded_sdk_digest() {
  [[ -d "$wasm_sdk_bundle" && ! -L "$wasm_sdk_bundle" ]] || die 'The pinned Swift WASM SDK bundle is unavailable or unsafe.' 69
  (cd "$wasm_sdk_bundle" && {
    /usr/bin/find . -type f -print0 | LC_ALL=C /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/shasum -a 256
    /usr/bin/find . -type l -print0 | LC_ALL=C /usr/bin/sort -z | while IFS= read -r -d '' item; do printf 'symlink:%s:%s\n' "$item" "$(/usr/bin/readlink "$item")"; done
  }) | stream_sha
}

toolchain_digest() { toolchain_snapshot | stream_sha; }

collect() {
  testing || clean_source
  source_commit="$(git rev-parse HEAD)"
  source_digest_value="$(source_digest)"
  config_digest_value="$(config_digest)"
  toolchain_digest_value="$(toolchain_digest)"
  [[ "$($swift_executable --version | /usr/bin/head -1)" == *"Swift version $swift_version"* ]] || die 'The pinned Swift toolchain version does not match.' 69
  "$swift_executable" sdk list | /usr/bin/grep -Fx "$wasm_sdk" >/dev/null || die 'The pinned Swift WASM SDK is unavailable.' 69
}

prepare() {
  toolchain_snapshot > "$root/toolchain-v1.txt"
  printf '%s\n' "$state_header" > "$root/state-v1.tsv"
  printf '%s\n' "$ownership_header" > "$root/ownership-v1.tsv"
  /usr/bin/jq -n \
    --arg schema "$schema" --arg commit "$source_commit" --arg source "$source_digest_value" \
    --arg config "$config_digest_value" --arg toolchain "$toolchain_digest_value" \
    --arg swiftExecutable "$swift_executable" --arg swiftVersion "$swift_version" \
    --arg wasmSDKIdentifier "$wasm_sdk" --arg wasmSDKChecksum "$wasm_sdk_checksum" \
    --arg wasmSDKBundleDigest "$wasm_sdk_bundle_digest" \
    '{schema:$schema,gate:10,status:"prepared",preparedAt:(now|todate),completedAt:null,
      sourceCommit:$commit,sourceDigest:$source,configDigest:$config,toolchainDigest:$toolchain,
      cellOrder:[1,2,3,4,5,6],externalPrerequisites:{swiftExecutable:$swiftExecutable,
      swiftVersion:$swiftVersion,wasmSDKIdentifier:$wasmSDKIdentifier,wasmSDKChecksum:$wasmSDKChecksum,
      wasmSDKBundleDigest:$wasmSDKBundleDigest}}' \
    > "$root/manifest-v1.json"
  chmod 600 "$root/manifest-v1.json" "$root/state-v1.tsv" "$root/ownership-v1.tsv" "$root/toolchain-v1.txt"
}

prepared() {
  [[ -f "$root/manifest-v1.json" && ! -L "$root/manifest-v1.json" ]] || die 'Gate 10 evidence root is not prepared.' 73
  [[ "$(/usr/bin/jq -r .schema "$root/manifest-v1.json")" == "$schema" ]] || die 'Gate 10 manifest schema mismatch.' 73
  [[ "$(/usr/bin/jq -r .status "$root/manifest-v1.json")" == prepared || "$(/usr/bin/jq -r .status "$root/manifest-v1.json")" == passed ]] || die 'Gate 10 evidence is frozen after failure.' 73
  [[ "$(/usr/bin/jq -r .sourceDigest "$root/manifest-v1.json")" == "$source_digest_value" && "$(/usr/bin/jq -r .configDigest "$root/manifest-v1.json")" == "$config_digest_value" && "$(/usr/bin/jq -r .toolchainDigest "$root/manifest-v1.json")" == "$toolchain_digest_value" ]] || die 'prepared evidence dependencies changed; preserve this root.' 73
}

revalidate_dependencies() {
  [[ "$(source_digest)" == "$source_digest_value" && "$(config_digest)" == "$config_digest_value" && "$(toolchain_digest)" == "$toolchain_digest_value" ]] || die 'prepared evidence dependencies changed; preserve this root.' 73
}

record_root() {
  local path="$1" identifier="${2:-gate10-live-runtime}"
  [[ -d "$path" && ! -L "$path" && "$path" == "$root"/* ]] || die 'temporary root is unsafe.'
  printf '%s\ttemporary-root\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$identifier" "$path" "$(stat -f '%d' "$path")" "$(stat -f '%i' "$path")" 'owned=gate10' >> "$root/ownership-v1.tsv"
}

record_artifact() {
  local kind="$1" identifier="$2" path="$3"
  [[ -e "$path" && ! -L "$path" && "$path" == "$root"/* ]] || die 'Gate 10 artifact is unsafe.'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$kind" "$identifier" "$path" "$(stat -f '%d' "$path")" "$(stat -f '%i' "$path")" 'owned=gate10' >> "$root/ownership-v1.tsv"
}

record_process() {
  local pid="$1" executable="$2" identifier="$3" identity
  [[ "$pid" =~ ^[1-9][0-9]*$ && -f "$executable" && ! -L "$executable" ]] || die 'provider-worker process identity is unsafe.'
  identity="$(revalidate_process_identity "$pid" "$executable")"
  printf '%s\tprocess\t%s\t%s\t%s\t%s\t%s\n' \
    "$(now)" "$identifier" "$executable" "$(stat -f '%d' "$executable")" "$(stat -f '%i' "$executable")" "$identity" >> "$root/ownership-v1.tsv"
}

revalidate_process_identity() {
  local pid="$1" executable="$2" identity
  [[ -n "$process_identity_tool" && -f "$process_identity_tool" && ! -L "$process_identity_tool" ]] \
    || die 'provider-worker identity revalidation tool is unavailable; cleanup is refused.'
  identity="$("$process_identity_tool" --process-identity "$pid" --expected-executable "$executable")" \
    || die 'provider-worker identity revalidation failed; cleanup is refused.'
  [[ "$identity" =~ ^pid=[1-9][0-9]*\;command_sha256=[a-f0-9]{64}\;start_sha256=[a-f0-9]{64}$ ]] \
    || die 'provider-worker identity revalidation returned an invalid token; cleanup is refused.'
  printf '%s\n' "$identity"
}

stop_exact_process() {
  local path="$1" device="$2" inode="$3" identity="$4" pid command_sha start_sha current_identity n
  pid="${identity#pid=}"; pid="${pid%%;*}"
  command_sha="${identity#*command_sha256=}"; command_sha="${command_sha%%;*}"
  start_sha="${identity#*start_sha256=}"; start_sha="${start_sha%%;*}"
  [[ "$pid" =~ ^[1-9][0-9]*$ && -f "$path" && ! -L "$path" && "$(stat -f '%d' "$path")" == "$device" && "$(stat -f '%i' "$path")" == "$inode" ]] || die 'provider-worker identity changed; cleanup is refused.'
  kill -0 "$pid" 2>/dev/null || return 0
  current_identity="$(revalidate_process_identity "$pid" "$path")"
  [[ "$current_identity" == "$identity" && "$command_sha" =~ ^[a-f0-9]{64}$ && "$start_sha" =~ ^[a-f0-9]{64}$ ]] \
    || die 'provider-worker identity changed; cleanup is refused.'
  kill -TERM "$pid"
  for n in {1..50}; do kill -0 "$pid" 2>/dev/null || return 0; /bin/sleep .1; done
  die 'owned provider-worker did not stop; cleanup is frozen.' 124
}

cleanup() {
  [[ "$cleanup_completed" == 0 ]] || return 0
  if [[ -z "$root" || ! -f "$root/ownership-v1.tsv" ]]; then cleanup_completed=1; return 0; fi
  local path device inode identity
  while IFS=$'\t' read -r path device inode identity; do
    stop_exact_process "$path" "$device" "$inode" "$identity"
  done < <(/usr/bin/awk -F $'\t' '$2=="process"{print $4"\t"$5"\t"$6"\t"$7}' "$root/ownership-v1.tsv")
  while IFS=$'\t' read -r path device inode; do
    [[ -f "$path" && ! -L "$path" && "$(stat -f '%d' "$path")" == "$device" && "$(stat -f '%i' "$path")" == "$inode" ]] || die 'guest artifact identity changed; cleanup is refused.'
    /bin/unlink "$path"
  done < <(/usr/bin/awk -F $'\t' '$2=="temporary-file"{print $4"\t"$5"\t"$6}' "$root/ownership-v1.tsv")
  while IFS=$'\t' read -r path device inode; do
    [[ -d "$path" && ! -L "$path" && "$(stat -f '%d' "$path")" == "$device" && "$(stat -f '%i' "$path")" == "$inode" ]] || die 'temporary root identity changed; cleanup is refused.'
    /bin/rmdir "$path"
  done < <(/usr/bin/awk -F $'\t' '$2=="temporary-root"{print length($4)"\t"$4"\t"$5"\t"$6}' "$root/ownership-v1.tsv" | /usr/bin/sort -rn | /usr/bin/cut -f2-)
  cleanup_completed=1
}

live() {
  swift build --jobs 1 --product hostwright-wasi-provider-worker
  swift build --jobs 1 --product hostwright-wasi-provider-qualification
  "$swift_executable" build --jobs 1 --scratch-path "$wasm_scratch" -c release --swift-sdk "$wasm_sdk" -Xlinker --max-memory=67108864 -Xlinker --strip-all --product hostwright-wasi-reference-provider
  "$swift_executable" build --jobs 1 --scratch-path "$wasm_scratch" -c release --swift-sdk "$wasm_sdk" -Xlinker --max-memory=67108864 -Xlinker --strip-all --product hostwright-wasi-adversarial-provider
  local host_bin guest_bin runtime reference adversarial qualification
  host_bin="$(swift build --show-bin-path)"
  guest_bin="$($swift_executable build --show-bin-path --scratch-path "$wasm_scratch" -c release --swift-sdk "$wasm_sdk")"
  runtime="$root/live-runtime-v1"; mkdir "$runtime"; chmod 700 "$runtime"; record_root "$runtime"
  reference="$runtime/reference-provider.wasm"; adversarial="$runtime/adversarial-provider.wasm"
  /bin/cp "$guest_bin/hostwright-wasi-reference-provider.wasm" "$reference"
  /bin/cp "$guest_bin/hostwright-wasi-adversarial-provider.wasm" "$adversarial"
  chmod 600 "$reference" "$adversarial"
  [[ "$(stat -f '%z' "$reference")" -le 16777216 && "$(stat -f '%z' "$adversarial")" -le 16777216 ]] || die 'a Gate 10 guest exceeds the frozen 16 MiB module limit.'
  printf 'reference_guest_bytes=%s reference_guest_sha256=%s\n' "$(stat -f '%z' "$reference")" "$(sha "$reference")"
  printf 'adversarial_guest_bytes=%s adversarial_guest_sha256=%s\n' "$(stat -f '%z' "$adversarial")" "$(sha "$adversarial")"
  record_artifact temporary-file guest-reference "$reference"
  record_artifact temporary-file guest-adversarial "$adversarial"
  qualification="$host_bin/hostwright-wasi-provider-qualification"
  process_identity_tool="$qualification"
  HOSTWRIGHT_WASI_PROVIDER_WORKER="$host_bin/hostwright-wasi-provider-worker" \
    HOSTWRIGHT_WASI_OWNERSHIP_LEDGER="$root/ownership-v1.tsv" \
    "$qualification" --reference "$reference" --adversarial "$adversarial"
}

cell_command() {
  case "$1" in
    1) printf '%s\n' 'swift test --jobs 1 --filter HostwrightWASIProviderSDKTests' ;;
    2) printf '%s\n' 'swift test --jobs 1 --filter HostwrightWASIProviderRuntimeTests' ;;
    3) printf '%s\n' 'official Swift WASM SDK build plus live reference/adversarial WasmKitWASI interop' ;;
    4) printf '%s\n' 'swift test --jobs 1 --filter HostwrightWASIProviderCompatibilityTests|ControlPlaneContractTests|HostwrightNetworkProvidersTests' ;;
    5) printf '%s\n' 'swift test --jobs 1 --filter HostwrightWASIProviderSecurityTests' ;;
    6) printf '%s\n' 'swift test --jobs 1 --filter HostwrightWASIProviderResilienceTests|Phase09Gate10QualificationHarnessTests; builds; lint; docs' ;;
    *) die 'unknown Gate 10 cell.' ;;
  esac
}

run_cell() {
  case "$1" in
    1) swift test --jobs 1 --filter 'HostwrightWASIProviderSDKTests' ;;
    2) swift test --jobs 1 --filter 'HostwrightWASIProviderRuntimeTests' ;;
    3) live ;;
    4) swift test --jobs 1 --filter 'HostwrightWASIProviderCompatibilityTests|ControlPlaneContractTests|HostwrightNetworkProvidersTests' ;;
    5) swift test --jobs 1 --filter 'HostwrightWASIProviderSecurityTests' ;;
    6) swift test --jobs 1 --filter 'HostwrightWASIProviderResilienceTests|Phase09Gate10QualificationHarnessTests'; swift build --jobs 1 --product hostwright-wasi-provider-worker; swift build --jobs 1 --product hostwright-wasi-provider-qualification; scripts/lint.sh; git diff --check; scripts/check-docs.sh ;;
    *) die 'unknown Gate 10 cell.' ;;
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
  decoded="$(/usr/bin/mktemp /tmp/hostwright-phase09-gate10.XXXXXX)"
  security cms -D -u 9 -i "$root/evidence-v1.cms" -o "$decoded" >/dev/null 2>&1 || status=1
  /usr/bin/cmp -s "$root/evidence-v1.sha256" "$decoded" || status=1
  (cd "$root" && /usr/bin/shasum -a 256 -c evidence-v1.sha256 >/dev/null) || status=1
  /bin/unlink "$decoded"
  [[ "$status" == 0 ]]
}

release() {
  if [[ "$run_succeeded" == 1 && "$root_lock_created" == 1 && "$gate_lock_created" == 1 ]]; then
    /bin/rmdir "$root/active-run-v1"; /bin/rmdir "$parent/.phase09-gate10-active-v1"
    root_lock_created=0; gate_lock_created=0
  fi
}

write_digest() {
  (cd "$root"; for file in manifest-v1.json state-v1.tsv ownership-v1.tsv toolchain-v1.txt gate-active-run-v1-info.tsv cell-*.stdout.log cell-*.stderr.log; do [[ -f "$file" ]] && /usr/bin/shasum -a 256 "$file"; done | LC_ALL=C /usr/bin/sort) > "$root/evidence-v1.sha256"
  chmod 600 "$root/evidence-v1.sha256"
  security cms -S -N "$signing_identity" -H SHA256 -u 9 -i "$root/evidence-v1.sha256" -o "$root/evidence-v1.cms"
  chmod 600 "$root/evidence-v1.cms"
}

on_exit() { local status=$?; trap - EXIT; cleanup || status=$?; release || status=$?; exit "$status"; }
cell_timeout() { case "$1" in 3) printf '%s\n' 1800 ;; 6) printf '%s\n' 2400 ;; *) printf '%s\n' 1200 ;; esac; }
terminate_cell_group() { local pgid="$1" n; kill -TERM -- "-$pgid" 2>/dev/null || return 0; for n in {1..50}; do kill -0 -- "-$pgid" 2>/dev/null || return 0; /bin/sleep .1; done; kill -KILL -- "-$pgid" 2>/dev/null || true; }

run() {
  prepared
  if [[ -e "$root/evidence-v1.sha256" || -e "$root/evidence-v1.cms" ]]; then
    [[ "$(/usr/bin/jq -r .status "$root/manifest-v1.json")" == passed ]] && reusable && verify || die 'completed evidence is incomplete or changed; preserve this root and do not rerun.' 73
    printf '%s\n' 'Gate 10 evidence is valid and reused; no cells were rerun.'; return
  fi
  local lock="$parent/.phase09-gate10-active-v1" n cmd out err start end status cell_pid watchdog
  [[ ! -e "$root/active-run-v1" && ! -e "$lock" ]] || die 'An active Gate 10 qualification already exists; do not duplicate it.' 75
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
      die "Gate 10 cell $n failed; progress is frozen and locks are preserved." "$status"
    fi
    revalidate_dependencies
    state "$n" pass "$start" "$end" "$(sha "$out")" "$(sha "$err")"
  done
  cleanup
  manifest passed "$(now)"
  /bin/cp "$lock/info-v1.tsv" "$root/gate-active-run-v1-info.tsv"; chmod 600 "$root/gate-active-run-v1-info.tsv"
  write_digest; /bin/unlink "$lock/info-v1.tsv"; run_succeeded=1; release
  printf '%s\n' 'Gate 10 qualification passed.'
}

main() {
  [[ "$#" -ge 1 ]] || die 'usage: phase09-gate10-qualification.sh <contract|prepare|run>.' 64
  case "$1" in
    contract) [[ "$#" == 1 ]] || die 'contract accepts no arguments.' 64; contract ;;
    prepare) [[ "$#" == 2 && "$2" == 10 ]] || die 'Gate 10 harness accepts only prepare 10.' 64; validate_worktree; validate_root; empty_root; collect; prepare; printf '%s\n' 'Gate 10 evidence root prepared.' ;;
    run) [[ "$#" == 2 && "$2" == 10 ]] || die 'Gate 10 harness accepts only run 10.' 64; validate_worktree; validate_root; collect; run ;;
    *) die 'unknown qualification command.' 64 ;;
  esac
}
main "$@"
