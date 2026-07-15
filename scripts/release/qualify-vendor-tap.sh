#!/usr/bin/env bash
set -euo pipefail

readonly baseline_version="0.0.2-dev.1"
readonly candidate_version="0.0.2-dev.2"
readonly baseline_tag="v$baseline_version"
readonly candidate_tag="v$candidate_version"
readonly tap_name="hostwright/tap"
readonly formula_reference="$tap_name/hostwright"
readonly hostwright_repository="https://github.com/hostwright/hostwright.git"
readonly tap_repository_url="https://github.com/hostwright/homebrew-tap.git"

die() {
  printf '%s\n' "$1" >&2
  exit "${2:-64}"
}

require_sha() {
  local name="$1"
  local value="${!name:-}"
  [[ "$value" =~ ^[a-f0-9]{40}$ ]] || die "$name must be one exact lowercase commit SHA."
}

validate_contract() {
  require_sha HOSTWRIGHT_BASELINE_RELEASE_COMMIT
  require_sha HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT
  require_sha HOSTWRIGHT_BASELINE_TAP_COMMIT
  require_sha HOSTWRIGHT_CANDIDATE_TAP_COMMIT
  [[ "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT" != "$HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT" ]] \
    || die "The two release commits must be distinct."
  [[ "$HOSTWRIGHT_BASELINE_TAP_COMMIT" != "$HOSTWRIGHT_CANDIDATE_TAP_COMMIT" ]] \
    || die "The two tap commits must be distinct."
}

validate_host() {
  [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] \
    || die "Vendor-tap qualification requires macOS on Apple silicon." 69
  local macos_major
  macos_major="$(sw_vers -productVersion | cut -d. -f1)"
  [[ "$macos_major" =~ ^[0-9]+$ && "$macos_major" -ge 26 ]] \
    || die "Vendor-tap qualification requires macOS 26 or newer." 69
  command -v brew >/dev/null || die "Homebrew is required." 69
  command -v gh >/dev/null || die "GitHub CLI is required for attestation verification." 69
}

validate_qualification_root() {
  : "${HOSTWRIGHT_QUALIFICATION_ROOT:?HOSTWRIGHT_QUALIFICATION_ROOT is required}"
  [[ "$HOSTWRIGHT_QUALIFICATION_ROOT" == /* && "$HOSTWRIGHT_QUALIFICATION_ROOT" != / \
      && "$HOSTWRIGHT_QUALIFICATION_ROOT" != *$'\n'* \
      && "$HOSTWRIGHT_QUALIFICATION_ROOT" != *"/../"* \
      && "$HOSTWRIGHT_QUALIFICATION_ROOT" != */.. ]] \
    || die "HOSTWRIGHT_QUALIFICATION_ROOT must be one safe absolute directory."
  [[ -d "$HOSTWRIGHT_QUALIFICATION_ROOT" && ! -L "$HOSTWRIGHT_QUALIFICATION_ROOT" ]] \
    || die "The qualification root must be pre-created as a non-symlink directory." 66
  [[ "$(stat -f '%u' "$HOSTWRIGHT_QUALIFICATION_ROOT")" == "$(id -u)" ]] \
    || die "The qualification root must be owned by the qualification user." 77
  [[ "$(stat -f '%Lp' "$HOSTWRIGHT_QUALIFICATION_ROOT")" == 700 ]] \
    || die "The qualification root must have mode 0700." 77
}

state_file=""
evidence_file=""

bind_paths() {
  state_file="$HOSTWRIGHT_QUALIFICATION_ROOT/state"
  evidence_file="$HOSTWRIGHT_QUALIFICATION_ROOT/evidence.log"
  if [[ -e "$state_file" ]]; then
    [[ -f "$state_file" && ! -L "$state_file" ]] || die "Qualification state is unsafe." 70
    [[ "$(stat -f '%u' "$state_file")" == "$(id -u)" \
        && "$(stat -f '%Lp' "$state_file")" == 600 ]] \
      || die "Qualification state ownership or mode changed." 70
  fi
  if [[ -e "$evidence_file" ]]; then
    [[ -f "$evidence_file" && ! -L "$evidence_file" ]] || die "Qualification evidence is unsafe." 70
    [[ "$(stat -f '%u' "$evidence_file")" == "$(id -u)" \
        && "$(stat -f '%Lp' "$evidence_file")" == 600 ]] \
      || die "Qualification evidence ownership or mode changed." 70
  fi
}

record() {
  umask 077
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$evidence_file"
  chmod 600 "$evidence_file"
}

boot_epoch() {
  sysctl -n kern.boottime | sed -E 's/.*sec = ([0-9]+).*/\1/'
}

write_state() {
  local phase="$1"
  local boot="$2"
  local config_path="${3:-none}"
  local config_digest="${4:-none}"
  local next="$state_file.next"
  [[ "$phase" =~ ^(preparing|reboot-required)$ ]] || die "Invalid qualification phase."
  [[ "$boot" =~ ^[0-9]+$ ]] || die "Invalid boot epoch."
  [[ ! -e "$next" ]] || die "A stale qualification state write exists." 70
  if [[ "$config_path" == none || "$config_digest" == none ]]; then
    [[ "$config_path" == none && "$config_digest" == none ]] \
      || die "Recorded config path and digest must be present together."
  else
    [[ "$config_path" == /* && "$config_path" != *$'\n'* \
        && "$config_digest" =~ ^[a-f0-9]{64}$ ]] \
      || die "Invalid recorded config ownership."
  fi
  umask 077
  {
    printf 'phase=%s\n' "$phase"
    printf 'bootEpoch=%s\n' "$boot"
    printf 'baselineReleaseCommit=%s\n' "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT"
    printf 'candidateReleaseCommit=%s\n' "$HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT"
    printf 'baselineTapCommit=%s\n' "$HOSTWRIGHT_BASELINE_TAP_COMMIT"
    printf 'candidateTapCommit=%s\n' "$HOSTWRIGHT_CANDIDATE_TAP_COMMIT"
    printf 'configPath=%s\n' "$config_path"
    printf 'configDigest=%s\n' "$config_digest"
  } > "$next"
  chmod 600 "$next"
  mv -f "$next" "$state_file"
}

state_value() {
  local key="$1"
  local value
  value="$(awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2) }' "$state_file")"
  [[ -n "$value" && "$(grep -c "^${key}=" "$state_file")" == 1 ]] \
    || die "Qualification state is missing $key." 70
  printf '%s\n' "$value"
}

load_and_verify_state() {
  [[ -f "$state_file" && ! -L "$state_file" ]] || die "No resumable qualification state exists." 66
  [[ "$(wc -l < "$state_file" | tr -d ' ')" == 8 ]] || die "Qualification state is malformed." 70
  [[ "$(state_value baselineReleaseCommit)" == "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT" \
      && "$(state_value candidateReleaseCommit)" == "$HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT" \
      && "$(state_value baselineTapCommit)" == "$HOSTWRIGHT_BASELINE_TAP_COMMIT" \
      && "$(state_value candidateTapCommit)" == "$HOSTWRIGHT_CANDIDATE_TAP_COMMIT" ]] \
    || die "Qualification inputs do not match the durable state." 70
}

verify_release_ref() {
  local tag="$1"
  local expected_commit="$2"
  local refs peeled compare_status
  refs="$(git ls-remote "$hostwright_repository" "refs/tags/$tag" "refs/tags/$tag^{}")"
  peeled="$(printf '%s\n' "$refs" | awk '$2 ~ /\^\{\}$/ { print $1 }')"
  [[ "$peeled" == "$expected_commit" ]] || die "$tag does not resolve to its exact reviewed commit." 70
  compare_status="$(gh api "repos/hostwright/hostwright/compare/${expected_commit}...main" --jq .status)"
  [[ "$compare_status" == ahead || "$compare_status" == identical ]] \
    || die "$tag is not preserved as an ancestor of main." 70
}

ensure_tap_checkout() {
  local brew_binary tap_repository remote
  brew_binary="$(command -v brew)"
  if ! "$brew_binary" tap | grep -Fxq "$tap_name"; then
    "$brew_binary" tap "$tap_name" "$tap_repository_url" >&2
  fi
  tap_repository="$("$brew_binary" --repository "$tap_name")"
  [[ -d "$tap_repository/.git" && ! -L "$tap_repository" ]] \
    || die "Homebrew tap checkout is unsafe." 70
  remote="$(git -C "$tap_repository" remote get-url origin)"
  [[ "$remote" == "$tap_repository_url" || "$remote" == "${tap_repository_url%.git}" ]] \
    || die "Homebrew tap remote is not the official repository." 70
  [[ -z "$(git -C "$tap_repository" status --porcelain=v1 --untracked-files=all)" ]] \
    || die "Homebrew tap checkout is dirty." 70
  if [[ "$(git -C "$tap_repository" rev-parse --is-shallow-repository)" == true ]]; then
    git -C "$tap_repository" fetch --unshallow --no-tags origin main
  else
    git -C "$tap_repository" fetch --no-tags origin main
  fi
  git -C "$tap_repository" cat-file -e "$HOSTWRIGHT_BASELINE_TAP_COMMIT^{commit}"
  git -C "$tap_repository" cat-file -e "$HOSTWRIGHT_CANDIDATE_TAP_COMMIT^{commit}"
  git -C "$tap_repository" merge-base --is-ancestor \
    "$HOSTWRIGHT_BASELINE_TAP_COMMIT" "$HOSTWRIGHT_CANDIDATE_TAP_COMMIT"
  git -C "$tap_repository" merge-base --is-ancestor "$HOSTWRIGHT_CANDIDATE_TAP_COMMIT" origin/main
  printf '%s\n' "$tap_repository"
}

checkout_formula() {
  local tap_repository="$1"
  local commit="$2"
  local version="$3"
  local tag="$4"
  local release_commit="$5"
  local formula="$tap_repository/Formula/hostwright.rb"
  git -C "$tap_repository" checkout --detach "$commit"
  [[ -f "$formula" && ! -L "$formula" ]] || die "The reviewed tap commit has no safe formula." 70
  grep -Fqx "  version \"$version\"" "$formula" \
    || die "The formula version does not match $version." 70
  grep -Fq "/releases/download/$tag/hostwright-$version-macos-arm64-${release_commit:0:12}.zip\"" "$formula" \
    || die "The formula URL is not bound to the exact release commit and tag." 70
  if grep -Eq '^[[:space:]]*bottle do' "$formula"; then
    die "Qualification formulas must not add a bottle around the signed upstream archive." 70
  fi
  gh attestation verify "$formula" --repo hostwright/hostwright >/dev/null
}

verify_installed() {
  local version="$1"
  local label="$2"
  local prefix executable doctor_status readiness cache
  prefix="$(brew --prefix "$formula_reference")"
  for executable in hostwright hostwright-control hostwright-dist hostwrightd; do
    [[ "$("$prefix/bin/$executable" --version)" == "$version" ]] \
      || die "$executable does not report $version." 70
    /usr/bin/codesign --verify --strict --verbose=2 "$prefix/bin/$executable"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$prefix/bin/$executable"
  done
  "$prefix/bin/hostwright" capabilities --json > "$HOSTWRIGHT_QUALIFICATION_ROOT/$label-capabilities.json"
  [[ "$(plutil -extract productVersion raw "$HOSTWRIGHT_QUALIFICATION_ROOT/$label-capabilities.json")" == "$version" ]] \
    || die "Capability output does not match $version." 70
  doctor_status=0
  "$prefix/bin/hostwright" doctor --output json > "$HOSTWRIGHT_QUALIFICATION_ROOT/$label-doctor.json" \
    || doctor_status=$?
  case "$doctor_status" in 0|65|66|69) ;; *) die "Doctor returned an invalid exit status." 70 ;; esac
  readiness="$(plutil -extract readiness raw "$HOSTWRIGHT_QUALIFICATION_ROOT/$label-doctor.json")"
  [[ "$readiness" =~ ^(ready|degraded|blocked|unsupported|externally-constrained)$ ]] \
    || die "Doctor returned an unknown readiness state." 70
  cache="$(brew --cache "$formula_reference")"
  [[ -f "$cache" && ! -L "$cache" ]] || die "The exact Homebrew archive cache is unavailable." 70
  gh attestation verify "$cache" --repo hostwright/hostwright >/dev/null
}

wait_for_service() {
  local output="$HOSTWRIGHT_QUALIFICATION_ROOT/service.json"
  local attempt running
  for attempt in {1..30}; do
    if brew services info --json "$formula_reference" > "$output" 2>/dev/null; then
      running="$(plutil -extract 0.running raw "$output" 2>/dev/null || true)"
      if [[ "$running" == true || "$running" == 1 ]]; then
        return 0
      fi
    fi
    sleep 1
  done
  die "The exact Homebrew service did not become running." 70
}

remove_owned_file() {
  local path="$1"
  [[ ! -e "$path" ]] && return 0
  [[ -f "$path" && ! -L "$path" && "$(stat -f '%u' "$path")" == "$(id -u)" ]] \
    || die "Refusing to remove an ambiguous qualification-owned file: $path" 70
  rm -f "$path"
}

validate_qualification_install() {
  local inventory formula version
  inventory="$(brew list --versions hostwright 2>/dev/null)" \
    || die "Homebrew reports an ambiguous Hostwright installation." 70
  read -r formula version _ <<< "$inventory"
  [[ "$formula" == hostwright && -n "$version" ]] \
    || die "Homebrew reports an ambiguous Hostwright installation." 70
  for version in ${inventory#hostwright }; do
    [[ "$version" == "$baseline_version" || "$version" == "$candidate_version" ]] \
      || die "Refusing to remove a Hostwright version not installed by this qualification." 70
  done
}

validate_existing_tap() {
  local tap_repository remote
  brew tap | grep -Fxq "$tap_name" || die "The qualification tap is missing." 70
  tap_repository="$(brew --repository "$tap_name")"
  [[ -d "$tap_repository/.git" && ! -L "$tap_repository" ]] \
    || die "Homebrew tap checkout is unsafe." 70
  remote="$(git -C "$tap_repository" remote get-url origin)"
  [[ "$remote" == "$tap_repository_url" || "$remote" == "${tap_repository_url%.git}" ]] \
    || die "Homebrew tap remote is not the official repository." 70
  [[ -z "$(git -C "$tap_repository" status --porcelain=v1 --untracked-files=all)" ]] \
    || die "Homebrew tap checkout is dirty; refusing ambiguous cleanup." 70
}

prepare() {
  [[ ! -e "$state_file" ]] || die "Qualification state already exists; resume or clean it first." 70
  if brew list --formula hostwright >/dev/null 2>&1 || command -v hostwright >/dev/null 2>&1; then
    die "The clean-host cell already contains Hostwright." 70
  fi
  local tap_repository brew_prefix config_dir config_path config_source config_digest log_path error_log_path boot
  brew_prefix="$(brew --prefix)"
  config_dir="$brew_prefix/etc/hostwright"
  config_path="$config_dir/hostwright.yaml"
  log_path="$brew_prefix/var/log/hostwrightd.log"
  error_log_path="$brew_prefix/var/log/hostwrightd.error.log"
  [[ ! -e "$config_dir" && ! -e "$log_path" && ! -e "$error_log_path" ]] \
    || die "The clean-host cell contains pre-existing Hostwright config or logs." 70
  verify_release_ref "$baseline_tag" "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT"
  verify_release_ref "$candidate_tag" "$HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT"
  boot="$(boot_epoch)"
  write_state preparing "$boot"
  record "prepare-intent"
  tap_repository="$(ensure_tap_checkout)"
  checkout_formula "$tap_repository" "$HOSTWRIGHT_BASELINE_TAP_COMMIT" \
    "$baseline_version" "$baseline_tag" "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT"
  brew install "$formula_reference"
  verify_installed "$baseline_version" baseline
  [[ ! -e "$config_dir" && ! -e "$log_path" && ! -e "$error_log_path" ]] \
    || die "The formula changed config or logs before service configuration." 70
  config_source="$(brew --prefix "$formula_reference")/share/hostwright/hostwright.yaml"
  [[ -f "$config_source" && ! -L "$config_source" ]] || die "The formula example config is unavailable." 70
  config_digest="$(shasum -a 256 "$config_source" | awk '{ print $1 }')"
  write_state preparing "$boot" "$config_path" "$config_digest"
  install -d -m 700 "$config_dir"
  install -m 600 "$config_source" "$config_path"
  [[ "$(shasum -a 256 "$config_path" | awk '{ print $1 }')" == "$config_digest" ]] \
    || die "Qualification config copy did not preserve the intended bytes." 70
  brew services start "$formula_reference"
  wait_for_service
  write_state reboot-required "$boot" "$config_path" "$config_digest"
  record "baseline-installed-service-running-reboot-required"
  printf 'Baseline qualification passed. Reboot the disposable Mac, then dispatch resume.\n'
}

resume() {
  load_and_verify_state
  [[ "$(state_value phase)" == reboot-required ]] || die "Qualification is not waiting for reboot." 70
  local prior_boot current_boot tap_repository config_path config_digest brew_prefix log_path error_log_path
  prior_boot="$(state_value bootEpoch)"
  current_boot="$(boot_epoch)"
  [[ "$current_boot" =~ ^[0-9]+$ && "$current_boot" != "$prior_boot" ]] \
    || die "A real reboot has not occurred since prepare." 70
  config_path="$(state_value configPath)"
  config_digest="$(state_value configDigest)"
  brew_prefix="$(brew --prefix)"
  [[ "$config_path" == "$brew_prefix/etc/hostwright/hostwright.yaml" ]] \
    || die "Qualification state does not own the expected config path." 70
  [[ -f "$config_path" && ! -L "$config_path" \
      && "$(shasum -a 256 "$config_path" | awk '{ print $1 }')" == "$config_digest" ]] \
    || die "Qualification config changed across reboot." 70
  tap_repository="$(ensure_tap_checkout)"
  checkout_formula "$tap_repository" "$HOSTWRIGHT_BASELINE_TAP_COMMIT" \
    "$baseline_version" "$baseline_tag" "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT"
  verify_installed "$baseline_version" post-reboot-baseline
  wait_for_service
  brew services restart "$formula_reference"
  wait_for_service
  record "reboot-and-baseline-service-restart-passed"

  checkout_formula "$tap_repository" "$HOSTWRIGHT_CANDIDATE_TAP_COMMIT" \
    "$candidate_version" "$candidate_tag" "$HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT"
  brew upgrade "$formula_reference"
  verify_installed "$candidate_version" candidate
  brew services restart "$formula_reference"
  wait_for_service
  record "dev1-to-dev2-brew-upgrade-and-service-restart-passed"

  brew services stop "$formula_reference"
  brew uninstall "$formula_reference"
  hash -r
  if brew list --formula hostwright >/dev/null 2>&1 || command -v hostwright >/dev/null 2>&1; then
    die "Hostwright remains installed after Homebrew uninstall." 70
  fi
  [[ -f "$config_path" && ! -L "$config_path" \
      && "$(shasum -a 256 "$config_path" | awk '{ print $1 }')" == "$config_digest" ]] \
    || die "Homebrew removed or changed user configuration during uninstall." 70
  log_path="$brew_prefix/var/log/hostwrightd.log"
  error_log_path="$brew_prefix/var/log/hostwrightd.error.log"
  remove_owned_file "$config_path"
  remove_owned_file "$log_path"
  remove_owned_file "$error_log_path"
  rmdir "$(dirname "$config_path")" 2>/dev/null || true
  brew untap "$tap_name"
  record "uninstall-preservation-and-exact-qualification-cleanup-passed"
  rm -f "$state_file"
  printf 'Vendor-tap clean-host qualification passed.\n'
}

cleanup_failed_run() {
  load_and_verify_state
  local config_path config_digest brew_prefix expected_config
  config_path="$(state_value configPath)"
  config_digest="$(state_value configDigest)"
  brew_prefix="$(brew --prefix)"
  expected_config="$brew_prefix/etc/hostwright/hostwright.yaml"
  if [[ "$config_path" != none ]]; then
    [[ "$config_path" == "$expected_config" && "$config_digest" =~ ^[a-f0-9]{64}$ ]] \
      || die "Refusing cleanup for an unexpected config ownership record." 70
    if [[ -e "$config_path" ]]; then
      [[ -f "$config_path" && ! -L "$config_path" \
          && "$(shasum -a 256 "$config_path" | awk '{ print $1 }')" == "$config_digest" ]] \
        || die "Qualification config changed; preserving it and refusing ambiguous cleanup." 70
    fi
  fi
  if brew list --formula hostwright >/dev/null 2>&1; then
    validate_qualification_install
    validate_existing_tap
    brew services stop "$formula_reference"
    brew uninstall --force "$formula_reference"
    hash -r
    if brew list --formula hostwright >/dev/null 2>&1; then
      die "Homebrew still reports Hostwright installed after cleanup." 70
    fi
  fi
  if brew tap | grep -Fxq "$tap_name"; then
    validate_existing_tap
    brew untap --force "$tap_name"
  fi
  if [[ "$config_path" != none ]]; then
    if [[ -e "$config_path" ]]; then
      remove_owned_file "$config_path"
    fi
    rmdir "$(dirname "$config_path")" 2>/dev/null || true
  fi
  remove_owned_file "$brew_prefix/var/log/hostwrightd.log"
  remove_owned_file "$brew_prefix/var/log/hostwrightd.error.log"
  record "failed-run-owned-cleanup-completed"
  rm -f "$state_file"
}

command="${1:-}"
validate_contract
if [[ "$command" == validate-contract ]]; then
  printf 'Phase 02 vendor-tap qualification contract is valid.\n'
  exit 0
fi
validate_host
validate_qualification_root
bind_paths
export HOMEBREW_NO_AUTO_UPDATE=1
case "$command" in
  prepare|resume|cleanup) ;;
  *) die "Usage: qualify-vendor-tap.sh validate-contract|prepare|resume|cleanup" ;;
esac
record_stage_failure() {
  local status=$?
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    set +e
    record "stage-$command-failed-exit-$status"
  fi
  exit "$status"
}
trap record_stage_failure EXIT
record "inputs baselineReleaseCommit=$HOSTWRIGHT_BASELINE_RELEASE_COMMIT candidateReleaseCommit=$HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT baselineTapCommit=$HOSTWRIGHT_BASELINE_TAP_COMMIT candidateTapCommit=$HOSTWRIGHT_CANDIDATE_TAP_COMMIT"
record "host productVersion=$(sw_vers -productVersion) buildVersion=$(sw_vers -buildVersion) architecture=$(uname -m) model=$(sysctl -n hw.model)"
record "stage-$command-started"
case "$command" in
  prepare) prepare ;;
  resume) resume ;;
  cleanup) cleanup_failed_run ;;
esac
