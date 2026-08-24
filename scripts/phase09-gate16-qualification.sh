#!/usr/bin/env bash
set -euo pipefail

readonly gate=16
readonly issue_number=206
readonly source_branch='feat/v0.0.2-phase-09'
readonly repository_path='/Users/dev/Documents/hostwright-phase09'
readonly protected_repository_path='/Users/dev/Documents/hostwright'
readonly qualification_parent_default='/Volumes/T9/hostwright/qualification'
readonly harness_schema='hostwright.phase09.gate16.qualification.manifest.v1'
readonly receipts_schema='hostwright.phase09.gate16.receipts.v1'
readonly evidence_marker='<!-- hostwright-evidence-gate:v1 -->'
readonly ownership_header=$'recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity'
readonly state_header=$'gate\tstage\tstatus\tsource_digest\tconfig_digest\ttoolchain_digest\tstarted_at\tfinished_at'
readonly expected_gate15_root_pattern='^phase09-gate15-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
readonly expected_gate16_root_pattern='^phase09-gate16-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
readonly expected_cms_identity='Developer ID Application: Dev Trivedi (993YC3JY4Q)'
readonly expected_cms_fingerprint='A6CFABEC0AA50ABE00A745BAFA83BC24783AA5DB'
readonly expected_cms_team='993YC3JY4Q'
readonly test_cms_identity='testing-cms-signer'
readonly test_cms_fingerprint='testing-cms-fingerprint'
readonly test_cms_certificate_fingerprint='testing-cms-certificate'
readonly test_cms_team='testing'
readonly required_checks_json='["CI / test","Roadmap governance / pull-request-closure-gate","Documentation and website / core-documentation"]'

script_invocation="${BASH_SOURCE[0]}"
script_absolute=''
script_directory=''
repo_root=''
root=''
gate15_root=''
gate15_manifest=''
source_commit=''
source_digest_value=''
config_digest_value=''
toolchain_digest_value=''
dirty_state=''
expected_cms_certificate_fingerprint=''
cms_signer_identity=''
cms_signer_fingerprint=''
cms_signer_certificate_fingerprint=''
cms_signer_team=''
gate15_signer_identity=''
gate15_signer_fingerprint=''
gate15_signer_certificate_fingerprint=''
gate15_signer_team=''
receipts_file=''
receipt_merge_commit=''
ledger_json_value='[]'
finalization_started=0
finalization_completed=0
finalization_reason=''
finalization_frozen=0
freeze_in_progress=0
prepare_started=0
staged_root=''

testing() {
  [[ "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" == '1' ]]
}

die() {
  printf '%s\n' "$1" >&2
  exit "${2:-70}"
}

timestamp() {
  /bin/date -u +%Y-%m-%dT%H:%M:%SZ
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

sha256_stream() {
  /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
}

is_sha256() {
  [[ "${1:-}" =~ ^[a-f0-9]{64}$ ]]
}

is_git_sha() {
  [[ "${1:-}" =~ ^[a-f0-9]{40}$ ]]
}

is_timestamp() {
  local value="${1:-}" normalized
  [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || return 1
  normalized="$(/bin/date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" \
    || return 1
  [[ "$normalized" == "$value" ]]
}

is_object_id() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._:/-]{1,200}$ ]]
}

test_parent_is_private() {
  local parent="$1"
  [[ "$parent" == /private/var/folders/*/T/hostwright-phase09-* \
    || "$parent" == /var/folders/*/T/hostwright-phase09-* ]]
}

validate_script_boundary() {
  local invocation canonical parent
  if [[ "$script_invocation" == /* ]]; then
    invocation="$script_invocation"
  else
    invocation="$PWD/$script_invocation"
  fi
  [[ -f "$invocation" && ! -L "$invocation" ]] \
    || die 'Gate 16 script invocation must not cross a symlink boundary.' 66
  canonical="$(/bin/realpath "$invocation")" \
    || die 'Gate 16 script path cannot be canonicalized.' 66
  parent="$(dirname "$canonical")"
  [[ ! -L "$parent" && "$(/bin/realpath "$parent")" == "$parent" ]] \
    || die 'Gate 16 script directory must be canonical and non-symlinked.' 66
  [[ "$canonical" == "$repository_path/scripts/phase09-gate16-qualification.sh" ]] \
    || die 'Gate 16 script is outside the canonical Phase 09 repository.' 66
  script_absolute="$canonical"
  script_directory="$parent"
  repo_root="$(/bin/realpath "$script_directory/..")" \
    || die 'Gate 16 repository path cannot be canonicalized.' 66
  [[ "$repo_root" == "$repository_path" && "$repo_root" != "$protected_repository_path" ]] \
    || die 'Gate 16 refuses a protected or unexpected repository path.' 66
}

validate_worktree() {
  local branch top
  validate_script_boundary
  branch="$(git -C "$repo_root" branch --show-current 2>/dev/null)" \
    || die 'Gate 16 could not read the current branch.' 66
  top="$(/bin/realpath "$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)")" \
    || die 'Gate 16 could not resolve the repository root.' 66
  [[ "$branch" == "$source_branch" ]] \
    || die "Gate 16 requires branch $source_branch." 66
  [[ "$top" == "$repo_root" && "$top" != "$protected_repository_path" ]] \
    || die 'Gate 16 requires the canonical isolated Phase 09 worktree.' 66
  cd "$repo_root"
}

qualification_parent() {
  if testing; then
    : "${HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT:?test parent is required in harness test mode}"
    printf '%s\n' "$HOSTWRIGHT_PHASE09_HARNESS_TEST_PARENT"
    return
  fi
  [[ -z "${HOSTWRIGHT_PHASE09_HARNESS_TESTING:-}" ]] \
    || die 'HOSTWRIGHT_PHASE09_HARNESS_TESTING must be exactly 1 when set.' 66
  printf '%s\n' "$qualification_parent_default"
}

validate_private_parent() {
  local parent canonical owner mode
  parent="$(qualification_parent)"
  [[ "$parent" == /* && "$parent" != *$'\n'* && -d "$parent" && ! -L "$parent" ]] \
    || die 'Gate 16 qualification parent must be an existing absolute non-symlink directory.' 66
  canonical="$(/bin/realpath "$parent")" \
    || die 'Gate 16 qualification parent cannot be resolved.' 66
  [[ "$canonical" == "$parent" ]] \
    || die 'Gate 16 qualification parent must already be canonical.' 66
  if testing; then
    test_parent_is_private "$parent" \
      || die 'test parent is outside the private Gate 16 harness boundary.' 66
  else
    [[ "$parent" == "$qualification_parent_default" ]] \
      || die 'Gate 16 evidence must use the fixed qualification parent.' 66
  fi
  owner="$(stat -f '%u' "$parent")"
  mode="$(stat -f '%Lp' "$parent")"
  [[ "$owner" == "$(id -u)" && "$mode" == 700 ]] \
    || die 'Gate 16 qualification parent must be current-user-owned and mode 0700.' 66
}

validate_root_path() {
  local parent root_parent canonical_parent owner mode
  : "${HOSTWRIGHT_PHASE09_GATE_ROOT:?HOSTWRIGHT_PHASE09_GATE_ROOT is required}"
  root="$HOSTWRIGHT_PHASE09_GATE_ROOT"
  [[ "$root" == /* && "$root" != *$'\n'* && "$root" != */ ]] \
    || die 'HOSTWRIGHT_PHASE09_GATE_ROOT must be an absolute path without newlines.' 66
  validate_private_parent
  parent="$(qualification_parent)"
  canonical_parent="$(/bin/realpath "$parent")"
  root_parent="$(dirname "$root")"
  [[ "$root_parent" == "$canonical_parent" ]] \
    || die 'Gate 16 evidence root must be directly under the canonical qualification parent.' 66
  [[ "${root##*/}" =~ $expected_gate16_root_pattern ]] \
    || die 'Gate 16 evidence root name must contain an exact lowercase UUID.' 66
  [[ -d "$root" && ! -L "$root" && "$(/bin/realpath "$root")" == "$root" ]] \
    || die 'Gate 16 evidence root must be a canonical non-symlink directory.' 66
  owner="$(stat -f '%u' "$root")"
  mode="$(stat -f '%Lp' "$root")"
  [[ "$owner" == "$(id -u)" && "$mode" == 700 ]] \
    || die 'Gate 16 evidence root must be current-user-owned and mode 0700.' 66
}

require_empty_root() {
  [[ -z "$(/usr/bin/find "$root" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || die 'Gate 16 prepare requires an empty private evidence root.' 73
}

validate_private_file() {
  local path="$1" owner mode parent
  [[ "$path" == /* && -f "$path" && ! -L "$path" && "$(/bin/realpath "$path")" == "$path" ]] \
    || die 'Gate 16 receipt and dependency inputs must be canonical regular files.' 66
  owner="$(stat -f '%u' "$path")"
  mode="$(stat -f '%Lp' "$path")"
  [[ "$owner" == "$(id -u)" && "$mode" == 600 ]] \
    || die 'Gate 16 receipt and dependency files must be current-user-owned and mode 0600.' 66
  parent="$(dirname "$path")"
  [[ -d "$parent" && ! -L "$parent" && "$(/bin/realpath "$parent")" == "$parent" \
    && "$(stat -f '%u' "$parent")" == "$(id -u)" && "$(stat -f '%Lp' "$parent")" == 700 ]] \
    || die 'Gate 16 receipt and dependency files must reside in a private mode-0700 directory.' 66
}

validate_private_directory() {
  local path="$1" owner mode
  [[ "$path" == /* && -d "$path" && ! -L "$path" && "$(/bin/realpath "$path")" == "$path" ]] \
    || die 'Gate 16 dependency evidence must be a canonical non-symlink directory.' 66
  owner="$(stat -f '%u' "$path")"
  mode="$(stat -f '%Lp' "$path")"
  [[ "$owner" == "$(id -u)" && "$mode" == 700 ]] \
    || die 'Gate 16 dependency evidence must be current-user-owned and mode 0700.' 66
}

source_is_clean() {
  [[ -z "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all -- . \
    ':(exclude)tmp' ':(exclude).codex' ':(exclude).claude')" ]]
}

require_clean_source() {
  testing && return 0
  source_is_clean \
    || die 'Gate 16 requires clean committed feat/v0.0.2-phase-09 source.' 73
}

source_digest() {
  if testing; then
    (
      cd "$repo_root"
      {
        git rev-parse HEAD
        git diff --binary HEAD -- . ':(exclude)tmp' ':(exclude).codex' ':(exclude).claude'
      } | sha256_stream
    )
    return
  fi
  (
    cd "$repo_root"
    {
      git rev-parse HEAD
      git diff --binary HEAD -- . ':(exclude)tmp' ':(exclude).codex' ':(exclude).claude'
      while IFS= read -r -d '' path; do
        [[ "$path" == tmp || "$path" == tmp/* || "$path" == .codex || "$path" == .codex/* \
          || "$path" == .claude || "$path" == .claude/* ]] && continue
        printf '%s\0' "$path"
        /usr/bin/shasum -a 256 "$path"
      done < <(git ls-files --others --exclude-standard -z | LC_ALL=C /usr/bin/sort -z)
    } | sha256_stream
  )
}

config_digest() {
  {
    sha256_file "$script_absolute"
    sha256_file "$repo_root/scripts/phase09-gate-qualification.sh"
    sha256_file "$repo_root/scripts/roadmap-governance.py"
    sha256_file "$repo_root/docs/architecture/phase09-control-plane-contracts.md"
    printf '%s\n' 'python3 scripts/roadmap-governance.py validate'
    printf '%s\n' 'python3 scripts/roadmap-governance.py self-test'
    printf '%s\n' 'python3 scripts/roadmap-governance.py check-pr --event <local-export>'
    printf '%s\n' 'git rev-list --parents -n 1 <merge-commit>'
    printf '%s\n' 'swift test --jobs 1 --filter HostwrightControlPlaneTests'
    printf '%s\n' 'swift build --jobs 1 --target HostwrightControlPlane'
    printf '%s\n' 'scripts/lint.sh'
    printf '%s\n' 'scripts/check-docs.sh'
    printf '%s\n' 'git diff --check'
  } | sha256_stream
}

probe_command() {
  local label="$1"
  shift
  printf '\n[%s]\n' "$label"
  if [[ "$1" == /* ]]; then
    [[ -x "$1" ]] || { printf '%s\n' "unavailable: $1"; return 0; }
  else
    command -v "$1" >/dev/null 2>&1 || { printf '%s\n' "unavailable: $1"; return 0; }
  fi
  set +e
  "$@"
  local status=$?
  set -e
  printf 'exit_status=%s\n' "$status"
}

toolchain_report() {
  if testing; then
    printf '%s\n' 'Gate16 test-only deterministic toolchain v1'
    return
  fi
  {
    probe_command 'macOS' /usr/bin/sw_vers
    probe_command 'architecture' /usr/bin/uname -m
    probe_command 'Xcode' xcodebuild -version
    probe_command 'Swift' swift --version
    probe_command 'Bash' /bin/bash --version
    probe_command 'jq' /usr/bin/jq --version
    probe_command 'Python' python3 --version
    printf '%s\n' 'CMS signer identity is pinned by Gate16 constants and certificate fingerprint.'
  } 2>&1
}

collect_digests() {
  source_commit="$(git -C "$repo_root" rev-parse HEAD)"
  source_digest_value="$(source_digest)"
  config_digest_value="$(config_digest)"
  toolchain_digest_value="$(toolchain_report | sha256_stream)"
  if source_is_clean; then
    dirty_state='clean'
  else
    dirty_state='dirty'
  fi
}

run_governance_check() {
  local label="$1" output
  shift
  if output="$("$@" 2>&1)"; then
    printf '%s\n' "$label=pass"
    return 0
  fi
  printf '%s=fail\n%s\n' "$label" "$output" >&2
  return 1
}

run_local_governance_checks() {
  local status=0
  run_governance_check roadmap_validate env PYTHONDONTWRITEBYTECODE=1 python3 scripts/roadmap-governance.py validate || status=1
  run_governance_check roadmap_self_test env PYTHONDONTWRITEBYTECODE=1 python3 scripts/roadmap-governance.py self-test || status=1
  [[ "$status" == 0 ]]
}

gate15_parent() {
  printf '%s\n' "$(qualification_parent)"
}

validate_gate15_root_path() {
  local parent="$1" candidate="$2" canonical_parent owner mode
  validate_private_directory "$candidate"
  canonical_parent="$(/bin/realpath "$parent")"
  [[ "$(dirname "$candidate")" == "$canonical_parent" ]] \
    || die 'Gate 16 Gate15 evidence must be a direct child of the fixed qualification parent.' 73
  [[ "$(basename "$candidate")" =~ $expected_gate15_root_pattern ]] \
    || die 'Gate 16 Gate15 evidence root must use an exact lowercase UUID basename.' 73
  owner="$(stat -f '%u' "$candidate")"
  mode="$(stat -f '%Lp' "$candidate")"
  [[ "$owner" == "$(id -u)" && "$mode" == 700 ]] \
    || die 'Gate 16 Gate15 evidence root must be current-user-owned and mode 0700.' 73
}

validate_signer_values() {
  local identity fingerprint certificate team
  identity="$1"
  fingerprint="$2"
  certificate="$3"
  team="$4"
  if testing; then
    [[ "$identity" == "$test_cms_identity" && "$fingerprint" == "$test_cms_fingerprint" \
      && "$certificate" == "$test_cms_certificate_fingerprint" && "$team" == "$test_cms_team" ]] \
      || die 'Gate 16 test CMS signer metadata is not the fixed deterministic signer.' 73
    return
  fi
  [[ "$identity" == "$expected_cms_identity" \
    && "$fingerprint" == "$expected_cms_fingerprint" \
    && "$certificate" == "$expected_cms_certificate_fingerprint" \
    && "$team" == "$expected_cms_team" ]] \
    || die 'Gate 16 CMS certificate, fingerprint, Team ID, and identity are not pinned.' 73
}

load_signer_pins() {
  if testing; then
    expected_cms_certificate_fingerprint="$test_cms_certificate_fingerprint"
    return 0
  fi
  expected_cms_certificate_fingerprint="${HOSTWRIGHT_PHASE09_CMS_CERTIFICATE_SHA256:-}"
  [[ "$expected_cms_certificate_fingerprint" =~ ^[A-Fa-f0-9]{64}$ ]] \
    || die 'Gate 16 formal CMS sealing requires the exact pinned certificate SHA-256.' 73
  expected_cms_certificate_fingerprint="${expected_cms_certificate_fingerprint,,}"
}

validate_pinned_cms_environment() {
  load_signer_pins
  testing && return 0
  [[ "${HOSTWRIGHT_PHASE09_GATE16_SIGNING_IDENTITY:-}" == "$expected_cms_identity" ]] \
    || die 'Gate 16 sealing requires the exact pinned CMS signing identity.' 73
  [[ "$expected_cms_certificate_fingerprint" =~ ^[a-f0-9]{64}$ ]] \
    || die 'Gate 16 pinned CMS certificate SHA-256 is unavailable.' 73
  command -v openssl >/dev/null 2>&1 \
    || die 'Gate 16 requires OpenSSL to extract the certificate embedded in CMS.' 73
}

openssl_executable() {
  if [[ -x /usr/bin/openssl ]]; then
    printf '%s\n' /usr/bin/openssl
    return 0
  fi
  command -v openssl || die 'Gate 16 requires OpenSSL to extract CMS signer certificates.' 73
}

write_signer_metadata() {
  local destination="$1" schema
  testing && schema='hostwright.phase09.test.cms-signer.v1' \
    || schema='hostwright.phase09.gate16.cms-signer.v1'
  if [[ -n "$receipt_merge_commit" ]]; then
    /usr/bin/jq -n -S \
      --arg schema "$schema" --arg identity "$cms_signer_identity" \
      --arg fingerprint "$cms_signer_fingerprint" \
      --arg certificate "$cms_signer_certificate_fingerprint" --arg team "$cms_signer_team" \
      --arg source "$source_commit" --arg head "$source_commit" \
      --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
      '{schema:$schema,identity:$identity,fingerprint:$fingerprint,
        certificateFingerprint:$certificate,teamID:$team,sourceCommit:$source,
        headCommit:$head,mergeCommit:$merge,prNumber:$pr}' > "$destination"
  else
    /usr/bin/jq -n -S \
      --arg schema "$schema" --arg identity "$cms_signer_identity" \
      --arg fingerprint "$cms_signer_fingerprint" \
      --arg certificate "$cms_signer_certificate_fingerprint" --arg team "$cms_signer_team" \
      '{schema:$schema,identity:$identity,fingerprint:$fingerprint,
        certificateFingerprint:$certificate,teamID:$team}' > "$destination"
  fi
  chmod 600 "$destination"
  validate_private_file "$destination"
}

extract_cms_signer() {
  local cms="$1" cert_dir certs candidate_count candidate subject cert_identity cert_team
  local cert_der actual_certificate actual_fingerprint openssl_bin
  cms_signer_identity=''
  cms_signer_fingerprint=''
  cms_signer_certificate_fingerprint=''
  cms_signer_team=''
  if testing; then
    /usr/bin/jq -e \
      '(.schema == "hostwright.phase09.test.cms.v1"
        and (.signer | type == "object")
        and ((.signer | keys | sort) == ["certificateFingerprint","fingerprint","identity","teamID"]))' \
      "$cms" >/dev/null \
      || die 'Gate 16 test CMS signer certificate metadata is missing.' 73
    cms_signer_identity="$(/usr/bin/jq -r '.signer.identity' "$cms")"
    cms_signer_fingerprint="$(/usr/bin/jq -r '.signer.fingerprint' "$cms")"
    cms_signer_certificate_fingerprint="$(/usr/bin/jq -r '.signer.certificateFingerprint' "$cms")"
    cms_signer_team="$(/usr/bin/jq -r '.signer.teamID' "$cms")"
    validate_signer_values "$cms_signer_identity" "$cms_signer_fingerprint" \
      "$cms_signer_certificate_fingerprint" "$cms_signer_team"
    return 0
  fi

  openssl_bin="$(openssl_executable)"
  cert_dir="$(/usr/bin/mktemp -d -t hostwright-phase09-gate16-cms)" \
    || die 'Gate 16 could not create a private CMS certificate extraction directory.' 73
  chmod 700 "$cert_dir"
  certs="$cert_dir/certificates.pem"
  "$openssl_bin" pkcs7 -inform DER -in "$cms" -print_certs -out "$certs" >/dev/null 2>&1 \
    || die 'Gate 16 could not extract certificates from the verified CMS object.' 73
  candidate_count="$(/usr/bin/awk -v directory="$cert_dir" '
    /-----BEGIN CERTIFICATE-----/ { number++; path=sprintf("%s/cert-%d.pem", directory, number) }
    number > 0 { print > path }
    /-----END CERTIFICATE-----/ { close(path) }
    END { print number + 0 }
  ' "$certs" | /usr/bin/tail -n 1)"
  [[ "$candidate_count" =~ ^[1-9][0-9]*$ ]] \
    || die 'Gate 16 verified CMS did not contain a signer certificate.' 73
  local matches=0
  for candidate in "$cert_dir"/cert-*.pem; do
    [[ -f "$candidate" ]] || continue
    subject="$("$openssl_bin" x509 -in "$candidate" -noout -subject -nameopt RFC2253 2>/dev/null)" \
      || die 'Gate 16 embedded CMS certificate could not be parsed.' 73
    [[ "$subject" == *"CN=$expected_cms_identity"* ]] || continue
    matches=$((matches + 1))
    [[ "$matches" == 1 ]] || die 'Gate 16 CMS contains ambiguous pinned signer certificates.' 73
    cms_signer_identity="$expected_cms_identity"
    if [[ "$cms_signer_identity" =~ \(([A-Za-z0-9]{1,32})\)$ ]]; then
      cms_signer_team="${BASH_REMATCH[1]}"
    else
      die 'Gate 16 CMS signer identity does not carry a Team ID.' 73
    fi
    cert_der="$cert_dir/signer.der"
    "$openssl_bin" x509 -in "$candidate" -outform DER -out "$cert_der" >/dev/null 2>&1 \
      || die 'Gate 16 embedded CMS signer certificate could not be converted to DER.' 73
    actual_certificate="$(sha256_file "$cert_der")"
    actual_fingerprint="$("$openssl_bin" x509 -in "$candidate" -noout -fingerprint -sha1 \
      | /usr/bin/awk -F= '{print toupper($2)}' | /usr/bin/tr -d ':')"
    cms_signer_certificate_fingerprint="$actual_certificate"
    cms_signer_fingerprint="$actual_fingerprint"
  done
  [[ "$matches" == 1 ]] \
    || die 'Gate 16 verified CMS signer certificate does not match the exact pinned identity.' 73
  validate_signer_values "$cms_signer_identity" "$cms_signer_fingerprint" \
    "$cms_signer_certificate_fingerprint" "$cms_signer_team"
  for candidate in "$cert_dir"/*; do
    [[ -e "$candidate" ]] || continue
    /bin/unlink "$candidate"
  done
  /bin/rmdir "$cert_dir"
}

validate_private_json_keys() {
  local file="$1" expected="$2"
  /usr/bin/jq -e --argjson expected "$expected" \
    '((keys | sort) == ($expected | sort))' "$file" >/dev/null \
    || die "Gate 16 JSON schema keys are invalid: $file" 73
}

checksum_entry_exists() {
  local checksum="$1" name="$2"
  /usr/bin/awk -v target="$name" 'NF == 2 && $2 == target {found=1} END {exit(found ? 0 : 1)}' "$checksum"
}

validate_checksum_manifest() {
  local bundle="$1" checksum="$2" names name verify_output
  validate_private_file "$checksum"
  /usr/bin/awk 'NF == 2 && $1 ~ /^[a-f0-9]{64}$/ && $2 !~ /^\// && $2 !~ /(^|\/)\.\.($|\/)/ \
    && index($2,"*") == 0 && index($2,"?") == 0 && index($2,"[") == 0 && !seen[$2]++ {ok=1} NF != 2 || $1 !~ /^[a-f0-9]{64}$/ || $2 ~ /^\// \
    || $2 ~ /(^|\/)\.\.($|\/)/ || index($2,"*") != 0 || index($2,"?") != 0 || index($2,"[") != 0 || seen[$2] > 1 {bad=1} END {exit(ok && !bad ? 0 : 1)}' "$checksum" \
    || die 'Gate 16 checksum manifest has an invalid, duplicate, or unsafe entry.' 73
  if ! verify_output="$(cd "$bundle" && /usr/bin/shasum -a 256 -c "$checksum" 2>&1)"; then
    printf '%s\n' "$verify_output" >&2
    die 'Gate 16 checksum manifest verification failed.' 73
  fi
  checksum_entry_exists "$checksum" manifest-v1.json \
    || die 'Gate 16 checksum manifest does not bind manifest-v1.json.' 73
  names="$(/usr/bin/awk '{print $2}' "$checksum")"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ -f "$bundle/$name" && ! -L "$bundle/$name" ]] \
      || die 'Gate 16 checksum manifest references a missing or symlinked artifact.' 73
    validate_private_file "$bundle/$name"
  done <<< "$names"
}

verify_cms_bundle() {
  local bundle="$1" checksum_name="$2" cms_name="$3" signer_output="${4:-}"
  local decoded payload_digest expected_payload
  validate_private_file "$bundle/$checksum_name"
  validate_private_file "$bundle/$cms_name"
  if testing; then
    /usr/bin/jq -e \
      '(.schema == "hostwright.phase09.test.cms.v1" and (.payload | type == "string")
        and (.payloadDigest | test("^[a-f0-9]{64}$"))
        and (.signer | type == "object"))' "$bundle/$cms_name" >/dev/null \
      || die 'Gate 16 test CMS envelope is malformed.' 73
    expected_payload="$(/usr/bin/jq -Rs . < "$bundle/$checksum_name")"
    payload_digest="$(sha256_file "$bundle/$checksum_name")"
    /usr/bin/jq -e --arg digest "$payload_digest" --argjson payload "$expected_payload" \
      --arg identity "$test_cms_identity" --arg fingerprint "$test_cms_fingerprint" \
      --arg certificate "$test_cms_certificate_fingerprint" --arg team "$test_cms_team" \
      '(.payloadDigest == $digest and .payload == $payload
        and .signer.identity == $identity and .signer.fingerprint == $fingerprint
        and .signer.certificateFingerprint == $certificate and .signer.teamID == $team)' \
      "$bundle/$cms_name" >/dev/null \
      || die 'Gate 16 test CMS envelope did not round-trip with the pinned signer.' 73
  else
    validate_pinned_cms_environment
    decoded="$bundle/.gate16-cms-decoded-v1"
    [[ ! -e "$decoded" ]] \
      || die 'Gate 16 CMS verification temporary already exists; preserve the root.' 73
    /usr/bin/security cms -D -u 9 -i "$bundle/$cms_name" -o "$decoded" >/dev/null 2>&1 \
      || die 'Gate 16 CMS decode failed.' 73
    chmod 600 "$decoded"
    /usr/bin/cmp -s "$bundle/$checksum_name" "$decoded" \
      || { /bin/unlink "$decoded"; die 'Gate 16 CMS payload did not round-trip.' 73; }
    /bin/unlink "$decoded"
  fi
  extract_cms_signer "$bundle/$cms_name"
  if testing; then
    [[ "$cms_signer_identity" == "$test_cms_identity" ]] \
      || die 'Gate 16 verified CMS signer identity does not match the pinned signer.' 73
  else
    [[ "$cms_signer_identity" == "$expected_cms_identity" ]] \
      || die 'Gate 16 verified CMS signer identity does not match the pinned signer.' 73
  fi
  if [[ -n "$signer_output" ]]; then
    write_signer_metadata "$signer_output"
  fi
}

validate_signed_executables() {
  local file="$gate15_root/signed-executables-v1.tsv" expected_team
  validate_private_file "$file"
  if testing; then expected_team="$test_cms_team"; else expected_team="$expected_cms_team"; fi
  [[ "$(head -n 1 "$file")" == $'path\tsha256\tcdhash\tteamID\tidentifier' ]] \
    || die 'Gate 16 Gate15 signed executable pinset header is invalid.' 73
  /usr/bin/awk -F $'\t' -v team="$expected_team" \
    'NR == 1 {next} NF == 5 && $2 != "" && $3 != "" && $4 == team && $5 != "" {count++} END {exit(count > 0 ? 0 : 1)}' "$file" \
    || die 'Gate 16 Gate15 signed executable Team ID pinset is invalid.' 73
}

validate_ownership_ledger() {
  local ledger="$gate15_root/ownership-v1.tsv" line recorded type identifier path device inode identity
  validate_private_file "$ledger"
  [[ "$(head -n 1 "$ledger")" == "$ownership_header" ]] \
    || die 'Gate 16 Gate15 ownership-v1.tsv header is invalid.' 73
  /usr/bin/awk -F $'\t' \
    'NR == 1 {next} NF != 7 || $1 == "" || $2 == "" || $3 == "" || $4 == "" || $5 == "" || $6 == "" || $7 == "" || seen[$2 FS $3 FS $4]++ {bad=1} END {exit(bad ? 1 : 0)}' "$ledger" \
    || die 'Gate 16 Gate15 ownership-v1.tsv contains a malformed or duplicate row.' 73
  while IFS=$'\t' read -r recorded type identifier path device inode identity; do
    [[ -n "$recorded" ]] || continue
    is_timestamp "$recorded" || die 'Gate 16 Gate15 ownership timestamps are invalid.' 73
    case "$type" in
      temporary-root|temporary-file|socket|xpc)
        [[ "$path" == /* && "$path" != *$'\n'* && "$device" =~ ^[0-9]+$ && "$inode" =~ ^[0-9]+$ ]] \
          || die 'Gate 16 Gate15 path-backed ownership row is invalid.' 73
        ;;
      pid|process|container|launchd|keychain)
        [[ "$path" == '-' && "$device" == '-' && "$inode" == '-' ]] \
          || die 'Gate 16 Gate15 identity-only ownership row is invalid.' 73
        ;;
      *)
        die 'Gate 16 Gate15 ownership ledger contains an ignored or unknown resource kind.' 73
        ;;
    esac
    [[ "$identifier" =~ ^[A-Za-z0-9._:/-]{1,200}$ ]] \
      || die 'Gate 16 Gate15 ownership identifier is invalid.' 73
    [[ "$identity" != *$'\n'* && "$identity" != *$'\t'* && "$identity" != *secret* \
      && "$identity" != *password* && "$identity" != *token* && "$identity" != *credential* ]] \
      || die 'Gate 16 Gate15 ownership identity contains secret material or delimiters.' 73
  done < <(/usr/bin/awk 'NR > 1' "$ledger")
  ledger_json_value="$(/usr/bin/awk 'NR > 1' "$ledger" | /usr/bin/jq -Rn \
    '[inputs | split("\t") | {recordedAt: .[0], type: .[1], identifier: .[2], path: .[3], device: .[4], inode: .[5], identity: .[6]}]')"
}

validate_gate15_dependency_document() {
  local dependency="$gate15_root/dependency-evidence-v1.json" expected_gates
  validate_private_file "$dependency"
  expected_gates='[1,2,3,4,5,6,7,8,9,10,11,12,13,14]'
  /usr/bin/jq -e --argjson expected "$expected_gates" \
    '(.schema == "hostwright.phase09.gate15.dependencies.v1" and .status == "passed"
      and (.gates | type == "array" and length == 14)
      and ((.gates | map(.gate) | sort) == $expected)
      and all(.gates[]; (.status == "passed")
        and (.rootBasename | type == "string")
        and (.sourceCommit | type == "string" and test("^[a-f0-9]{40}$"))
        and (.sourceDigest | type == "string" and test("^[a-f0-9]{64}$"))
        and (.configDigest | type == "string" and test("^[a-f0-9]{64}$"))
        and (.toolchainDigest | type == "string" and test("^[a-f0-9]{64}$"))
        and (.dependencyEvidenceDigest | type == "string" and test("^[a-f0-9]{64}$"))
        and (.manifestDigest | type == "string" and test("^[a-f0-9]{64}$"))
        and (.checksumDigest | type == "string" and test("^[a-f0-9]{64}$"))
        and (.cmsDigest | type == "string" and test("^[a-f0-9]{64}$"))
        and (.signingIdentity | type == "string" and length > 0)
        and (.signingFingerprint | type == "string" and length > 0)
      and (.certificateFingerprint | type == "string" and length > 0)
      and (.teamID | type == "string" and length > 0)))' "$dependency" >/dev/null \
    || die 'Gate 16 Gate15 dependency evidence has an incomplete or invalid transitive set; cmsVerified is advisory and never trusted.' 73
  validate_receipt_formality "$(/usr/bin/jq -c . "$dependency")" 'Gate 15 dependency evidence'
  while IFS= read -r entry; do
    validate_receipt_formality "$entry" 'Gate 15 transitive dependency receipt'
  done < <(/usr/bin/jq -c '.gates[]' "$dependency")
}

validate_receipt_formality() {
  local value="$1" label="$2" expected_test=false
  testing && expected_test=true
  /usr/bin/jq -e --argjson expectedTest "$expected_test" '
    def bool_marker($key; $expected):
      has($key) and (.[ $key ] | type) == "boolean" and .[ $key ] == $expected;
    def string_marker($key; $expected):
      has($key) and (.[ $key ] | type) == "string" and .[ $key ] == $expected;
    def marker_key:
      . as $key
      | ($key == "claim" or $key == "status"
         or ($key | test("^(formal|test|qualif|seal)[A-Za-z0-9_-]*$"))
         or ($key | test("^is(Formal|Test|Qualifying|Sealed)$"))
         or ($key == "diagnostic" or $key == "nonFormal" or $key == "nonTest" or $key == "nonQualifying"));
    def allowed_marker_key:
      . == "claim" or . == "formal" or . == "formalClaim" or . == "qualifying"
      or . == "sealed" or . == "status" or . == "testMode" or . == "testOnly";
    def no_unknown_marker_keys:
      ([keys_unsorted[] | select(marker_key) | select(allowed_marker_key | not)] | length) == 0;
    def marker_node:
      any(keys_unsorted[]; marker_key);
    def exact_marker_profile:
      (type == "object"
       and bool_marker("formal"; ($expectedTest | not))
       and bool_marker("formalClaim"; ($expectedTest | not))
       and bool_marker("testMode"; $expectedTest)
       and bool_marker("qualifying"; ($expectedTest | not))
       and string_marker("status"; "passed")
       and bool_marker("sealed"; true)
       and ((has("testOnly") | not) or bool_marker("testOnly"; $expectedTest))
       and ((has("claim") | not) or string_marker("claim"; (if $expectedTest then "none" else "formal" end)))
       and no_unknown_marker_keys);
    ([.. | objects | select(marker_node)] as $nodes
      | ($nodes | length > 0) and ($nodes | all(.[]; exact_marker_profile)))' \
    <<< "$value" >/dev/null \
    || die "Gate 16 $label does not carry the exact $(if [[ "$expected_test" == true ]]; then printf 'non-formal test'; else printf 'formal'; fi) marker profile; all markers are mandatory." 73
}

validate_transitive_manifest_formality() {
  local manifest="$1"
  validate_receipt_formality "$(/usr/bin/jq -c . "$manifest")" 'Gate 16 transitive manifest'
}

validate_transitive_gate_root() {
  local entry="$1" parent="$2" number basename candidate manifest checksum cms
  local expected_manifest expected_checksum expected_cms expected_source expected_source_digest
  local expected_config expected_toolchain expected_dependency
  local expected_identity expected_fingerprint expected_certificate expected_team
  number="$(/usr/bin/jq -r '.gate' <<< "$entry")"
  basename="$(/usr/bin/jq -r '.rootBasename' <<< "$entry")"
  candidate="$parent/$basename"
  [[ "$number" =~ ^([1-9]|1[0-4])$ && "$basename" =~ ^phase09-gate(0[1-9]|1[0-4])-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] \
    || die 'Gate 16 transitive dependency root namespace is invalid.' 73
  validate_private_directory "$candidate"
  [[ "$(dirname "$candidate")" == "$parent" ]] || die 'Gate 16 transitive dependency root escaped its fixed parent.' 73
  manifest="$candidate/manifest-v1.json"
  checksum="$candidate/evidence-v1.sha256"
  cms="$candidate/evidence-v1.cms"
  validate_private_file "$manifest"
  validate_private_file "$checksum"
  validate_private_file "$cms"
  expected_source="$(/usr/bin/jq -r '.sourceCommit' <<< "$entry")"
  expected_source_digest="$(/usr/bin/jq -r '.sourceDigest' <<< "$entry")"
  expected_config="$(/usr/bin/jq -r '.configDigest' <<< "$entry")"
  expected_toolchain="$(/usr/bin/jq -r '.toolchainDigest' <<< "$entry")"
  expected_dependency="$(/usr/bin/jq -r '.dependencyEvidenceDigest' <<< "$entry")"
  expected_identity="$(/usr/bin/jq -r '.signingIdentity' <<< "$entry")"
  expected_fingerprint="$(/usr/bin/jq -r '.signingFingerprint' <<< "$entry")"
  expected_certificate="$(/usr/bin/jq -r '.certificateFingerprint' <<< "$entry")"
  expected_team="$(/usr/bin/jq -r '.teamID' <<< "$entry")"
  [[ "$expected_source" == "$source_commit" && "$expected_source_digest" == "$source_digest_value" \
    && "$expected_config" == "$config_digest_value" && "$expected_toolchain" == "$toolchain_digest_value" \
    && "$expected_dependency" =~ ^[a-f0-9]{64}$ ]] \
    || die 'Gate 16 transitive dependency digests are not current and complete.' 73
  validate_signer_values "$expected_identity" "$expected_fingerprint" "$expected_certificate" "$expected_team"
  /usr/bin/jq -e --argjson number "$number" --arg expectedSource "$expected_source" \
    --arg sourceDigest "$expected_source_digest" --arg configDigest "$expected_config" \
    --arg toolchainDigest "$expected_toolchain" --arg dependencyDigest "$expected_dependency" \
    --arg identity "$expected_identity" --arg fingerprint "$expected_fingerprint" \
    --arg certificate "$expected_certificate" --arg team "$expected_team" \
    '(.gate == $number and .status == "passed" and (.sourceCommit == $expectedSource)
      and .sourceDigest == $sourceDigest and .configDigest == $configDigest
      and .toolchainDigest == $toolchainDigest and .dependencyEvidenceDigest == $dependencyDigest
      and .signingIdentity == $identity and .signingFingerprint == $fingerprint
      and .certificateFingerprint == $certificate and .teamID == $team)' "$manifest" >/dev/null \
    || die 'Gate 16 transitive manifest is not bound to its dependency receipt.' 73
  validate_transitive_manifest_formality "$manifest"
  expected_manifest="$(/usr/bin/jq -r '.manifestDigest' <<< "$entry")"
  expected_checksum="$(/usr/bin/jq -r '.checksumDigest' <<< "$entry")"
  expected_cms="$(/usr/bin/jq -r '.cmsDigest' <<< "$entry")"
  [[ "$(sha256_file "$manifest")" == "$expected_manifest" \
    && "$(sha256_file "$checksum")" == "$expected_checksum" \
    && "$(sha256_file "$cms")" == "$expected_cms" ]] \
    || die 'Gate 16 transitive manifest/checksum/CMS digest binding failed.' 73
  validate_checksum_manifest "$candidate" "$checksum"
  verify_cms_bundle "$candidate" evidence-v1.sha256 evidence-v1.cms
  [[ "$cms_signer_identity" == "$expected_identity" \
    && "$cms_signer_fingerprint" == "$expected_fingerprint" \
    && "$cms_signer_certificate_fingerprint" == "$expected_certificate" \
    && "$cms_signer_team" == "$expected_team" ]] \
    || die 'Gate 16 transitive CMS signer does not match its manifest and dependency receipt.' 73
}

validate_gate15_dependency() {
  : "${HOSTWRIGHT_PHASE09_GATE15_EVIDENCE_ROOT:?HOSTWRIGHT_PHASE09_GATE15_EVIDENCE_ROOT is required}"
  gate15_root="$HOSTWRIGHT_PHASE09_GATE15_EVIDENCE_ROOT"
  gate15_manifest="$gate15_root/manifest-v1.json"
  validate_gate15_root_path "$(gate15_parent)" "$gate15_root"
  [[ ! -e "$gate15_root/active-run-v1" && ! -e "$(dirname "$gate15_root")/.phase09-gate15-active-v1" ]] \
    || die 'Gate 16 refuses an active Gate15 qualification marker.' 75
  for file in manifest-v1.json dependency-evidence-v1.json evidence-v1.sha256 evidence-v1.cms ownership-v1.tsv signed-executables-v1.tsv; do
    validate_private_file "$gate15_root/$file"
  done
  validate_receipt_formality "$(/usr/bin/jq -c . "$gate15_manifest")" 'Gate 15 manifest'
  local manifest_source manifest_source_digest manifest_config manifest_toolchain
  /usr/bin/jq -e \
    '(.schema == "hostwright.phase09.gate15.qualification.manifest.v1" and .gate == 15 and .status == "passed"
      and (.sourceCommit | test("^[a-f0-9]{40}$")) and (.sourceDigest | test("^[a-f0-9]{64}$"))
      and (.configDigest | test("^[a-f0-9]{64}$")) and (.toolchainDigest | test("^[a-f0-9]{64}$"))
      and (.dependencyEvidenceDigest | test("^[a-f0-9]{64}$"))
      and (.signingIdentity | type == "string" and length > 0)
      and (.signingFingerprint | type == "string" and length > 0)
      and (.certificateFingerprint | type == "string" and length > 0)
      and (.teamID | type == "string" and length > 0))' "$gate15_manifest" >/dev/null \
    || die 'Gate 16 requires a structurally complete Gate15 manifest.' 73
  manifest_source="$(/usr/bin/jq -r '.sourceCommit' "$gate15_manifest")"
  manifest_source_digest="$(/usr/bin/jq -r '.sourceDigest' "$gate15_manifest")"
  manifest_config="$(/usr/bin/jq -r '.configDigest' "$gate15_manifest")"
  manifest_toolchain="$(/usr/bin/jq -r '.toolchainDigest' "$gate15_manifest")"
  [[ "$manifest_source" == "$source_commit" && "$manifest_source_digest" == "$source_digest_value" ]] \
    || die 'Gate 16 Gate15 evidence is stale for the current HEAD/source digest.' 73
  [[ "$manifest_config" == "$config_digest_value" && "$manifest_toolchain" == "$toolchain_digest_value" ]] \
    || die 'Gate 16 Gate15 config/toolchain digests are stale or invalid.' 73
  validate_gate15_dependency_document
  [[ "$(sha256_file "$gate15_root/dependency-evidence-v1.json")" == "$(/usr/bin/jq -r '.dependencyEvidenceDigest' "$gate15_manifest")" ]] \
    || die 'Gate 16 Gate15 dependency digest does not match its immutable document.' 73
  validate_signed_executables
  validate_ownership_ledger
  validate_checksum_manifest "$gate15_root" "$gate15_root/evidence-v1.sha256"
  checksum_entry_exists "$gate15_root/evidence-v1.sha256" dependency-evidence-v1.json \
    || die 'Gate 16 Gate15 checksum evidence omits dependency-evidence-v1.json.' 73
  checksum_entry_exists "$gate15_root/evidence-v1.sha256" ownership-v1.tsv \
    || die 'Gate 16 Gate15 checksum evidence omits ownership-v1.tsv; every ledger-pinned resource to be absent must remain receipt-bound.' 73
  checksum_entry_exists "$gate15_root/evidence-v1.sha256" signed-executables-v1.tsv \
    || die 'Gate 16 Gate15 checksum evidence omits signed-executables-v1.tsv.' 73
  verify_cms_bundle "$gate15_root" evidence-v1.sha256 evidence-v1.cms
  gate15_signer_identity="$cms_signer_identity"
  gate15_signer_fingerprint="$cms_signer_fingerprint"
  gate15_signer_certificate_fingerprint="$cms_signer_certificate_fingerprint"
  gate15_signer_team="$cms_signer_team"
  /usr/bin/jq -e --arg identity "$gate15_signer_identity" --arg fingerprint "$gate15_signer_fingerprint" \
    --arg certificate "$gate15_signer_certificate_fingerprint" --arg team "$gate15_signer_team" \
    '(.signingIdentity == $identity and .signingFingerprint == $fingerprint
      and .certificateFingerprint == $certificate and .teamID == $team)' "$gate15_manifest" >/dev/null \
    || die 'Gate 16 Gate15 manifest signer metadata does not match the verified CMS certificate.' 73
  local parent entry
  parent="$(gate15_parent)"
  while IFS= read -r entry; do
    validate_transitive_gate_root "$entry" "$parent"
  done < <(/usr/bin/jq -c '.gates[]' "$gate15_root/dependency-evidence-v1.json")
}

write_manifest() {
  local status="$1" claim="$2" completed_at="${3:-}" test_value=false
  testing && test_value=true
  /usr/bin/jq -n \
    --arg schema "$harness_schema" --argjson gate "$gate" --arg status "$status" --arg claim "$claim" \
    --arg sourceCommit "$source_commit" --arg sourceDigest "$source_digest_value" \
    --arg configDigest "$config_digest_value" --arg toolchainDigest "$toolchain_digest_value" \
    --arg signingIdentity "$gate15_signer_identity" --arg signingFingerprint "$gate15_signer_fingerprint" \
    --arg certificateFingerprint "$gate15_signer_certificate_fingerprint" --arg teamID "$gate15_signer_team" \
    --arg dirtyState "$dirty_state" --arg startedAt "$(timestamp)" --arg completedAt "$completed_at" \
    --arg gate15RootBasename "$(basename "$gate15_root")" \
    --arg gate15ManifestDigest "$(sha256_file "$gate15_root/manifest-v1.json")" \
    --arg gate15DependencyDigest "$(sha256_file "$gate15_root/dependency-evidence-v1.json")" \
    --arg gate15ChecksumDigest "$(sha256_file "$gate15_root/evidence-v1.sha256")" \
    --arg gate15CMSDigest "$(sha256_file "$gate15_root/evidence-v1.cms")" \
    --argjson testOnly "$test_value" \
    '{schema:$schema,gate:$gate,status:$status,claim:$claim,formal:($status=="passed"),formalClaim:($status=="passed"),
      testMode:$testOnly,testOnly:$testOnly,qualifying:($status=="passed"),sealed:($status=="passed" or $status=="test-passed"),terminal:($status != "prepared"),
      sourceCommit:$sourceCommit,sourceDigest:$sourceDigest,configDigest:$configDigest,toolchainDigest:$toolchainDigest,dirtyState:$dirtyState,
      signingIdentity:$signingIdentity,signingFingerprint:$signingFingerprint,certificateFingerprint:$certificateFingerprint,teamID:$teamID,
      prerequisite:{gate:15,rootBasename:$gate15RootBasename,manifestDigest:$gate15ManifestDigest,dependencyEvidenceDigest:$gate15DependencyDigest,
        checksumDigest:$gate15ChecksumDigest,cmsDigest:$gate15CMSDigest},
      commands:["python3 scripts/roadmap-governance.py validate","python3 scripts/roadmap-governance.py self-test",
        "python3 scripts/roadmap-governance.py check-pr --event <local-export>","swift test --jobs 1 --filter HostwrightControlPlaneTests",
        "swift build --jobs 1 --target HostwrightControlPlane","scripts/lint.sh","scripts/check-docs.sh","git diff --check"],
      cellOrder:[],evidenceByCell:[],startedAt:$startedAt,completedAt:(if $completedAt=="" then null else $completedAt end)}' \
    > "$root/manifest-v1.json"
  chmod 600 "$root/manifest-v1.json"
}

write_dependency_evidence() {
  local test_value=false
  testing && test_value=true
  /usr/bin/jq -n \
    --arg rootBasename "$(basename "$gate15_root")" \
    --arg sourceCommit "$(/usr/bin/jq -r '.sourceCommit' "$gate15_root/manifest-v1.json")" \
    --arg sourceDigest "$(/usr/bin/jq -r '.sourceDigest' "$gate15_root/manifest-v1.json")" \
    --arg configDigest "$(/usr/bin/jq -r '.configDigest' "$gate15_root/manifest-v1.json")" \
    --arg toolchainDigest "$(/usr/bin/jq -r '.toolchainDigest' "$gate15_root/manifest-v1.json")" \
    --arg manifestDigest "$(sha256_file "$gate15_root/manifest-v1.json")" \
    --arg dependencyDigest "$(sha256_file "$gate15_root/dependency-evidence-v1.json")" \
    --arg checksumDigest "$(sha256_file "$gate15_root/evidence-v1.sha256")" \
    --arg cmsDigest "$(sha256_file "$gate15_root/evidence-v1.cms")" \
    --arg identity "$(/usr/bin/jq -r '.signingIdentity' "$gate15_root/manifest-v1.json")" \
    --arg fingerprint "$(/usr/bin/jq -r '.signingFingerprint' "$gate15_root/manifest-v1.json")" \
    --arg certificate "$(/usr/bin/jq -r '.certificateFingerprint' "$gate15_root/manifest-v1.json")" \
    --arg team "$(/usr/bin/jq -r '.teamID' "$gate15_root/manifest-v1.json")" \
    --argjson testOnly "$test_value" \
    '{schema:"hostwright.phase09.gate16.dependency-evidence.v1",gate:16,status:"verified",testOnly:$testOnly,
      gate15:{rootBasename:$rootBasename,sourceCommit:$sourceCommit,sourceDigest:$sourceDigest,configDigest:$configDigest,toolchainDigest:$toolchainDigest,
        manifestDigest:$manifestDigest,dependencyEvidenceDigest:$dependencyDigest,checksumDigest:$checksumDigest,cmsDigest:$cmsDigest,
        cmsSigner:{identity:$identity,fingerprint:$fingerprint,certificateFingerprint:$certificate,teamID:$team}}}' \
    > "$root/dependency-evidence-v1.json"
  chmod 600 "$root/dependency-evidence-v1.json"
}

write_closure_plan() {
  /usr/bin/jq -n \
    --arg sourceCommit "$source_commit" --arg sourceDigest "$source_digest_value" \
    --arg configDigest "$config_digest_value" --arg toolchainDigest "$toolchain_digest_value" \
    --arg dependencyDigest "$(sha256_file "$root/dependency-evidence-v1.json")" \
    --arg manifestDigest "$(sha256_file "$root/manifest-v1.json")" \
    --arg gate15RootBasename "$(basename "$gate15_root")" \
    --arg signingIdentity "$gate15_signer_identity" --arg signingFingerprint "$gate15_signer_fingerprint" \
    --arg certificateFingerprint "$gate15_signer_certificate_fingerprint" --arg teamID "$gate15_signer_team" \
    '{schema:"hostwright.phase09.gate16.closure-plan.v1",gate:16,claim:"none",sourceCommit:$sourceCommit,sourceDigest:$sourceDigest,
      configDigest:$configDigest,toolchainDigest:$toolchainDigest,preparedManifestDigest:$manifestDigest,
      dependencyEvidenceDigest:$dependencyDigest,gate15RootBasename:$gate15RootBasename,
      signingIdentity:$signingIdentity,signingFingerprint:$signingFingerprint,certificateFingerprint:$certificateFingerprint,teamID:$teamID,
      exactlyOnePullRequest:true,
      requiredLocalReceipts:["pullRequests","mergeProof","checks","reviews","phase09Issues","evidenceComment","cleanup","hardStop"],
      approvalRequiredFor:["publication","review","remote state changes"],
      generatedArtifacts:["closure-plan-v1.json","proposed-pr-body.md","proposed-evidence-comment.md"],
      terminalRules:{sealOnlyAfterReceipts:true,noLaterPhase:true,noReleaseArtifact:true,testModeNonFormal:true}}' \
    > "$root/closure-plan-v1.json"
  chmod 600 "$root/closure-plan-v1.json"
  cat > "$root/proposed-pr-body.md" <<EOF
## Final Evidence Gate

This file is a local draft generated by the Gate 16 harness. No remote action was performed.

Closes #206

${evidence_marker}

- Commit: ${source_commit}
- CMS signer: ${gate15_signer_identity}; fingerprint ${gate15_signer_fingerprint}; certificate ${gate15_signer_certificate_fingerprint}; Team ID ${gate15_signer_team}
- Source/config/toolchain/dependency digests: ${source_digest_value} / ${config_digest_value} / ${toolchain_digest_value} / $(sha256_file "$gate15_root/dependency-evidence-v1.json")
- Dirty: false
- OS/build/architecture/hardware: recorded by the final local receipt
- Runtime/framework/tool versions: recorded in toolchain-v1.txt
- Commands and raw outcomes: local governance, tests, build, lint, docs, and diff checks are receipt-bound
- Failures: none
- Blockers: none
- Cleanup and exact resource identifiers: receipt-bound and owned-resource-free
- Required evidence classes: unit-contract, local-integration, live-runtime, migration-upgrade, security-assessment, resilience-chaos, multi-host, interop-conformance, ux-accessibility
- Required evidence artifacts: sealed Gate 16 evidence bundle
- Documentation and compatibility matrix updates: Gate 13–16 architecture and dispatch integration

Public completion remains approval-gated and is not executed by this repository script.
EOF
  chmod 600 "$root/proposed-pr-body.md"
  cat > "$root/proposed-evidence-comment.md" <<EOF
${evidence_marker}

## Final Evidence Gate

Closes #206

- Commit: ${source_commit}
- CMS signer: ${gate15_signer_identity}; fingerprint ${gate15_signer_fingerprint}; certificate ${gate15_signer_certificate_fingerprint}; Team ID ${gate15_signer_team}
- Source/config/toolchain/dependency digests: ${source_digest_value} / ${config_digest_value} / ${toolchain_digest_value} / $(sha256_file "$gate15_root/dependency-evidence-v1.json")
- Dirty: false
- OS/build/architecture/hardware: receipt-bound
- Runtime/framework/tool versions: receipt-bound
- Commands and raw outcomes: receipt-bound local verification
- Failures: none
- Blockers: none
- Cleanup and exact resource identifiers: receipt-bound; no active locks or owned resources
- Required evidence classes: unit-contract, local-integration, live-runtime, migration-upgrade, security-assessment, resilience-chaos, multi-host, interop-conformance, ux-accessibility
- Required evidence artifacts: sealed Gate 16 evidence bundle
- Documentation and compatibility matrix updates: current
EOF
  chmod 600 "$root/proposed-evidence-comment.md"
}

write_prepared_binding() {
  local test_value=false
  testing && test_value=true
  /usr/bin/jq -n \
    --arg manifestDigest "$(sha256_file "$root/manifest-v1.json")" \
    --arg dependencyDigest "$(sha256_file "$root/dependency-evidence-v1.json")" \
    --arg closureDigest "$(sha256_file "$root/closure-plan-v1.json")" \
    --arg bodyDigest "$(sha256_file "$root/proposed-pr-body.md")" \
    --arg commentDigest "$(sha256_file "$root/proposed-evidence-comment.md")" \
    --arg sourceCommit "$source_commit" --arg sourceDigest "$source_digest_value" \
    --arg configDigest "$config_digest_value" --arg toolchainDigest "$toolchain_digest_value" \
    --arg signingIdentity "$gate15_signer_identity" --arg signingFingerprint "$gate15_signer_fingerprint" \
    --arg certificateFingerprint "$gate15_signer_certificate_fingerprint" --arg teamID "$gate15_signer_team" \
    --argjson testOnly "$test_value" \
    '{schema:"hostwright.phase09.gate16.prepared-binding.v1",gate:16,testOnly:$testOnly,manifestDigest:$manifestDigest,
      dependencyEvidenceDigest:$dependencyDigest,closurePlanDigest:$closureDigest,proposedPRBodyDigest:$bodyDigest,
      proposedEvidenceCommentDigest:$commentDigest,sourceCommit:$sourceCommit,sourceDigest:$sourceDigest,
      configDigest:$configDigest,toolchainDigest:$toolchainDigest,signingIdentity:$signingIdentity,
      signingFingerprint:$signingFingerprint,certificateFingerprint:$certificateFingerprint,teamID:$teamID}' > "$root/prepared-binding-v1.json"
  chmod 600 "$root/prepared-binding-v1.json"
}

write_checksum_manifest() {
  local bundle="$1" destination="$2" name
  shift 2
  [[ "$bundle" == /* && "$destination" == "$bundle"/* ]] \
    || die 'Gate 16 checksum destination escaped its private bundle.' 73
  : > "$destination"
  for name in "$@"; do
    [[ "$name" != /* && "$name" != *$'\n'* && "$name" != *$'\t'* \
      && -f "$bundle/$name" && ! -L "$bundle/$name" ]] \
      || die "Gate 16 checksum artifact is missing or unsafe: $name" 73
    printf '%s  %s\n' "$(sha256_file "$bundle/$name")" "$name"
  done | LC_ALL=C /usr/bin/sort > "$destination"
  chmod 600 "$destination"
  validate_private_file "$destination"
}

sign_cms_payload() {
  local checksum="$1" cms="$2"
  validate_pinned_cms_environment
  if testing; then
    /usr/bin/jq -n -S \
      --rawfile payload "$checksum" --arg digest "$(sha256_file "$checksum")" \
      --arg identity "$test_cms_identity" --arg fingerprint "$test_cms_fingerprint" \
      --arg certificate "$test_cms_certificate_fingerprint" --arg team "$test_cms_team" \
      '{schema:"hostwright.phase09.test.cms.v1",payload:$payload,payloadDigest:$digest,
        signer:{identity:$identity,fingerprint:$fingerprint,certificateFingerprint:$certificate,teamID:$team},testOnly:true}' \
      > "$cms"
  else
    /usr/bin/security cms -S -N "$expected_cms_identity" -H SHA256 -u 9 \
      -i "$checksum" -o "$cms" \
      || die 'Gate 16 CMS sealing failed; the root remains non-passed.' 73
  fi
  chmod 600 "$cms"
  validate_private_file "$cms"
}

write_prepared_seal() {
  local names name artifacts='[]'
  names='closure-plan-v1.json dependency-evidence-v1.json manifest-v1.json ownership-v1.tsv prepared-binding-v1.json proposed-evidence-comment.md proposed-pr-body.md state-v1.tsv toolchain-v1.txt'
  for name in $names; do
    [[ -f "$root/$name" ]] || die "Gate 16 prepared seal artifact is missing: $name" 73
    artifacts="$(/usr/bin/jq -c --arg name "$name" --arg digest "$(sha256_file "$root/$name")" \
      '. + [{name:$name,sha256:$digest}]' <<< "$artifacts")"
  done
  /usr/bin/jq -n -S \
    --arg schema 'hostwright.phase09.gate16.prepared-seal-index.v1' \
    --arg source "$source_commit" --arg sourceDigest "$source_digest_value" \
    --arg identity "$gate15_signer_identity" --arg fingerprint "$gate15_signer_fingerprint" \
    --arg certificate "$gate15_signer_certificate_fingerprint" --arg team "$gate15_signer_team" \
    --argjson artifacts "$artifacts" \
    '{schema:$schema,gate:16,sourceCommit:$source,sourceDigest:$sourceDigest,
      signer:{identity:$identity,fingerprint:$fingerprint,certificateFingerprint:$certificate,teamID:$team},
      artifacts:$artifacts,excludes:["prepared-evidence-v1.sha256","prepared-evidence-v1.cms","prepared-cms-signer-v1.json"]}' \
    > "$root/prepared-seal-index-v1.json"
  chmod 600 "$root/prepared-seal-index-v1.json"
  write_checksum_manifest "$root" "$root/prepared-evidence-v1.sha256" \
    $names prepared-seal-index-v1.json
  sign_cms_payload "$root/prepared-evidence-v1.sha256" "$root/prepared-evidence-v1.cms"
  verify_cms_bundle "$root" prepared-evidence-v1.sha256 prepared-evidence-v1.cms
  write_signer_metadata "$root/prepared-cms-signer-v1.json"
  [[ "$cms_signer_identity" == "$gate15_signer_identity" \
    && "$cms_signer_fingerprint" == "$gate15_signer_fingerprint" \
    && "$cms_signer_certificate_fingerprint" == "$gate15_signer_certificate_fingerprint" \
    && "$cms_signer_team" == "$gate15_signer_team" ]] \
    || die 'Gate 16 prepared CMS signer does not match the verified Gate15 signer.' 73
}

write_skeleton() {
  printf '%s\n' "$ownership_header" > "$root/ownership-v1.tsv"
  printf '%s\n' "$state_header" > "$root/state-v1.tsv"
  toolchain_report > "$root/toolchain-v1.txt"
  chmod 600 "$root/ownership-v1.tsv" "$root/state-v1.tsv" "$root/toolchain-v1.txt"
  write_manifest prepared none
  write_dependency_evidence
  write_closure_plan
  write_prepared_binding
  printf '%s\tprepare\tpass\t%s\t%s\t%s\t%s\t%s\n' \
    "$gate" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" \
    "$(timestamp)" "$(timestamp)" >> "$root/state-v1.tsv"
  chmod 600 "$root/state-v1.tsv"
  write_prepared_seal
}

write_failure() {
  local reason="$1" failure="$root/failure-v1.tsv" staged="$root/.failure-v1.next"
  [[ -d "$root" ]] || return 75
  [[ ! -e "$staged" && ! -L "$staged" ]] || return 75
  if [[ ! -f "$failure" ]]; then
    printf '%s\n' $'recorded_at\tgate\tstage\treason\tsource_digest\tconfig_digest\ttoolchain_digest' > "$staged" \
      || return 75
  else
    validate_private_file "$failure" || return 75
    /bin/cp "$failure" "$staged" || return 75
  fi
  printf '%s\t%s\tfinalize\t%s\t%s\t%s\t%s\n' \
    "$(timestamp)" "$gate" "$reason" "$source_digest_value" "$config_digest_value" "$toolchain_digest_value" >> "$staged" \
    || return 75
  /bin/mv "$staged" "$failure" || return 75
  chmod 600 "$failure" || return 75
  validate_private_file "$failure" || return 75
}

freeze_root() {
  local reason="$1" marker="$root/finalization-frozen-v1" staged="$root/.manifest-v1.failed"
  local freeze_status=0 manifest_status
  [[ "$freeze_in_progress" == 0 ]] || return 75
  freeze_in_progress=1
  if [[ ! -d "$root" || -L "$root" ]]; then
    freeze_status=75
  fi
  if [[ "$freeze_status" == 0 && -e "$root/final-v1" ]]; then
    printf '%s\n' 'Gate 16 cannot freeze a root after final-v1 publication.' >&2
    freeze_status=75
  fi
  if [[ "$freeze_status" == 0 && ! -e "$marker" ]]; then
    if ! mkdir "$marker"; then freeze_status=75; fi
  fi
  if [[ "$freeze_status" == 0 ]]; then
    [[ -d "$marker" && ! -L "$marker" ]] || freeze_status=75
  fi
  if [[ "$freeze_status" == 0 ]] && ! chmod 700 "$marker"; then freeze_status=75; fi
  if [[ "$freeze_status" == 0 && ! -f "$marker/reason-v1.txt" ]]; then
    if ! printf '%s\n' "$reason" > "$marker/reason-v1.txt"; then freeze_status=75; fi
    if [[ "$freeze_status" == 0 ]] && ! chmod 600 "$marker/reason-v1.txt"; then freeze_status=75; fi
  fi
  if [[ "$freeze_status" == 0 && -f "$root/manifest-v1.json" ]]; then
    manifest_status="$(/usr/bin/jq -r '.status // "invalid"' "$root/manifest-v1.json")" \
      || freeze_status=75
    if [[ "$freeze_status" == 0 && "$manifest_status" == prepared ]]; then
      [[ ! -e "$staged" && ! -L "$staged" ]] || freeze_status=75
      if [[ "$freeze_status" == 0 ]] && ! /usr/bin/jq --arg reason "$reason" --arg failedAt "$(timestamp)" \
        '.status="failed"|.claim="none"|.formal=false|.formalClaim=false|.qualifying=false|.sealed=false|.terminal=true|.failureFrozen=true|.failureReason=$reason|.failedAt=$failedAt' \
        "$root/manifest-v1.json" > "$staged"; then
        freeze_status=75
      fi
      if [[ "$freeze_status" == 0 ]] && ! chmod 600 "$staged"; then freeze_status=75; fi
      if [[ "$freeze_status" == 0 ]] && ! validate_private_file "$staged"; then freeze_status=75; fi
      if [[ "$freeze_status" == 0 ]] && ! /bin/mv "$staged" "$root/manifest-v1.json"; then freeze_status=75; fi
    fi
  fi
  if [[ "$freeze_status" == 0 ]]; then
    if ! write_failure "$reason"; then freeze_status=75; fi
  fi
  if [[ "$freeze_status" == 0 && "${HOSTWRIGHT_PHASE09_TEST_FREEZE_FAILURE:-0}" == 1 ]] && testing; then
    printf '%s\n' 'Gate 16 deterministic freeze verification failure requested.' >&2
    freeze_status=75
  fi
  if [[ "$freeze_status" == 0 ]]; then
    if ! /usr/bin/jq -e \
      '(.status == "failed" and .formal == false and .terminal == true and .failureFrozen == true)' \
      "$root/manifest-v1.json" >/dev/null; then
      freeze_status=75
    fi
  fi
  if [[ "$freeze_status" != 0 ]]; then
    printf '%s\n' 'Gate 16 failure freeze could not be completed or verified; retry remains blocked.' >&2
    freeze_in_progress=0
    return 75
  fi
  finalization_frozen=1
  freeze_in_progress=0
  return 0
}

write_finalization_terminal_lock() {
  local marker="$root/finalization-committed-v1" info="$root/finalization-committed-v1/info-v1.tsv"
  [[ ! -e "$marker" && ! -L "$marker" ]] \
    || finalize_die 'Gate 16 terminal finalization lock already exists; retry is forbidden.' 75
  mkdir "$marker" || finalize_die 'Gate 16 terminal finalization lock could not be created.' 75
  chmod 700 "$marker" || finalize_die 'Gate 16 terminal finalization lock could not be made private.' 75
  printf '%s\n' $'source_commit\thead_commit\tmerge_commit\tpr_number\tfinal_path\tstatus' > "$info" \
    || finalize_die 'Gate 16 terminal finalization lock record could not be created.' 75
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$source_commit" "$source_commit" "$receipt_merge_commit" "$issue_number" 'final-v1' 'committed' >> "$info" \
    || finalize_die 'Gate 16 terminal finalization lock record could not be written.' 75
  chmod 600 "$info" || finalize_die 'Gate 16 terminal finalization lock record could not be made private.' 75
  validate_private_file "$info" || finalize_die 'Gate 16 terminal finalization lock record failed validation.' 75
  /usr/bin/awk -F $'\t' -v source="$source_commit" -v merge="$receipt_merge_commit" -v pr="$issue_number" \
    'NR == 1 && $0 == "source_commit\thead_commit\tmerge_commit\tpr_number\tfinal_path\tstatus" {header=1}
     NR == 2 && NF == 6 && $1 == source && $2 == source && $3 == merge && $4 == pr && $5 == "final-v1" && $6 == "committed" {record=1}
     END {exit(header && record ? 0 : 1)}' "$info" \
    || finalize_die 'Gate 16 terminal finalization lock record is inconsistent.' 75
}

cleanup_finalization_marker_before_publication() {
  [[ -d "$root/finalization-active-v1" && ! -L "$root/finalization-active-v1" ]] \
    || finalize_die 'Gate 16 finalization marker is missing before publication.' 75
  [[ -f "$root/finalization-active-v1/info-v1.tsv" && ! -L "$root/finalization-active-v1/info-v1.tsv" ]] \
    || finalize_die 'Gate 16 finalization marker record is missing before publication.' 75
  validate_private_file "$root/finalization-active-v1/info-v1.tsv" \
    || finalize_die 'Gate 16 finalization marker record failed pre-publication validation.' 75
  /bin/unlink "$root/finalization-active-v1/info-v1.tsv" \
    || finalize_die 'Gate 16 finalization marker record could not be cleaned before publication.' 75
  [[ ! -e "$root/finalization-active-v1/info-v1.tsv" && ! -L "$root/finalization-active-v1/info-v1.tsv" ]] \
    || finalize_die 'Gate 16 finalization marker record cleanup could not be verified.' 75
  if testing && [[ "${HOSTWRIGHT_PHASE09_TEST_CLEANUP_FAILURE:-0}" == 1 ]]; then
    finalize_die 'Gate 16 deterministic pre-publication cleanup failure requested; no final-v1 was published and the root is frozen.' 75
  fi
  /bin/rmdir "$root/finalization-active-v1" \
    || finalize_die 'Gate 16 finalization lock could not be cleaned before publication.' 75
  [[ ! -e "$root/finalization-active-v1" && ! -L "$root/finalization-active-v1" ]] \
    || finalize_die 'Gate 16 finalization lock cleanup could not be verified.' 75
}

on_finalize_exit() {
  local status=$?
  trap - EXIT
  if [[ "$finalization_started" == 1 && "$finalization_completed" == 0 \
    && "$finalization_frozen" == 0 && "$status" != 0 ]]; then
    printf 'Gate 16 unexpected finalization exit %s; root frozen.\n' "$status" >&2
    if [[ ! -d "$root/final-v1" ]] && ! freeze_root "unexpected finalization exit $status"; then
      status=75
    fi
  fi
  exit "$status"
}

on_prepare_exit() {
  local status=$?
  trap - EXIT
  if [[ "$prepare_started" == 1 && "$status" != 0 && "$finalization_frozen" == 0 ]]; then
    if ! freeze_root "unexpected prepare exit $status"; then
      status=75
    fi
  fi
  exit "$status"
}

finalize_die() {
  local reason="$1" status="${2:-73}"
  finalization_reason="$reason"
  if [[ -d "$root/final-v1" ]]; then
    printf '%s\n' 'Gate 16 final-v1 is already atomically published; no further mutation is permitted.' >&2
    status=75
  elif ! freeze_root "$reason"; then
    printf '%s\n' 'Gate 16 failure freeze failed; retry is blocked and the freeze error is fatal.' >&2
    status=75
  fi
  die "$reason" "$status"
}

expected_children() {
  /usr/bin/jq -c '[.issues[] | select(.parent == 206) | .number] | sort' "$repo_root/docs/roadmap/v0.0.2/issues.json"
}

validate_prepared_manifest() {
  local expected_test=false manifest_test manifest_source manifest_digest manifest_config manifest_toolchain
  testing && expected_test=true
  validate_private_file "$root/manifest-v1.json"
  /usr/bin/jq -e \
    '(.schema == "hostwright.phase09.gate16.qualification.manifest.v1" and .gate == 16 and .status == "prepared"
      and .claim == "none" and .formal == false and .formalClaim == false and .testMode == .testOnly
      and .qualifying == false and .sealed == false and .terminal == false
      and (.sourceCommit | test("^[a-f0-9]{40}$")) and (.sourceDigest | test("^[a-f0-9]{64}$"))
      and (.configDigest | test("^[a-f0-9]{64}$")) and (.toolchainDigest | test("^[a-f0-9]{64}$"))
      and (.signingIdentity | type == "string" and length > 0)
      and (.signingFingerprint | type == "string" and length > 0)
      and (.certificateFingerprint | type == "string" and length > 0)
      and (.teamID | type == "string" and length > 0)
      and (.prerequisite.gate == 15))' "$root/manifest-v1.json" >/dev/null \
    || finalize_die 'Gate 16 prepared manifest schema or status is invalid.' 73
  manifest_test="$(/usr/bin/jq -r '.testOnly' "$root/manifest-v1.json")"
  manifest_source="$(/usr/bin/jq -r '.sourceCommit' "$root/manifest-v1.json")"
  manifest_digest="$(/usr/bin/jq -r '.sourceDigest' "$root/manifest-v1.json")"
  manifest_config="$(/usr/bin/jq -r '.configDigest' "$root/manifest-v1.json")"
  manifest_toolchain="$(/usr/bin/jq -r '.toolchainDigest' "$root/manifest-v1.json")"
  [[ "$manifest_test" == "$expected_test" && "$manifest_source" == "$source_commit" \
    && "$manifest_digest" == "$source_digest_value" && "$manifest_config" == "$config_digest_value" \
    && "$manifest_toolchain" == "$toolchain_digest_value" ]] \
    || finalize_die 'Gate 16 prepared manifest is stale for the current source/config/toolchain.' 73
  validate_signer_values "$(/usr/bin/jq -r '.signingIdentity' "$root/manifest-v1.json")" \
    "$(/usr/bin/jq -r '.signingFingerprint' "$root/manifest-v1.json")" \
    "$(/usr/bin/jq -r '.certificateFingerprint' "$root/manifest-v1.json")" \
    "$(/usr/bin/jq -r '.teamID' "$root/manifest-v1.json")"
  validate_private_file "$root/dependency-evidence-v1.json"
  validate_private_file "$root/closure-plan-v1.json"
  validate_private_file "$root/prepared-binding-v1.json"
  validate_private_file "$root/prepared-seal-index-v1.json"
  validate_private_file "$root/prepared-evidence-v1.sha256"
  validate_private_file "$root/prepared-evidence-v1.cms"
  validate_private_file "$root/prepared-cms-signer-v1.json"
  /usr/bin/jq -e \
    '(.schema == "hostwright.phase09.gate16.dependency-evidence.v1" and .gate == 16 and .status == "verified"
      and (.gate15.rootBasename | test("^phase09-gate15-[a-f0-9-]+$"))
      and (.gate15.manifestDigest | test("^[a-f0-9]{64}$")) and (.gate15.checksumDigest | test("^[a-f0-9]{64}$"))
      and (.gate15.cmsDigest | test("^[a-f0-9]{64}$"))
      and (.gate15.cmsSigner.identity | type == "string") and (.gate15.cmsSigner.fingerprint | type == "string")
      and (.gate15.cmsSigner.certificateFingerprint | type == "string") and (.gate15.cmsSigner.teamID | type == "string"))' "$root/dependency-evidence-v1.json" >/dev/null \
    || finalize_die 'Gate 16 prepared dependency binding is invalid.' 73
  /usr/bin/jq -e \
    '(.schema == "hostwright.phase09.gate16.closure-plan.v1" and .gate == 16 and .claim == "none"
      and .exactlyOnePullRequest == true and .requiredLocalReceipts == ["pullRequests","mergeProof","checks","reviews","phase09Issues","evidenceComment","cleanup","hardStop"]
      and (.signingIdentity | type == "string") and (.signingFingerprint | type == "string")
      and (.certificateFingerprint | type == "string") and (.teamID | type == "string"))' \
    "$root/closure-plan-v1.json" >/dev/null \
    || finalize_die 'Gate 16 closure plan schema or receipt set changed.' 73
  /usr/bin/jq -e \
    --arg manifest "$(sha256_file "$root/manifest-v1.json")" \
    --arg dependency "$(sha256_file "$root/dependency-evidence-v1.json")" \
    --arg closure "$(sha256_file "$root/closure-plan-v1.json")" \
    --arg body "$(sha256_file "$root/proposed-pr-body.md")" \
    --arg comment "$(sha256_file "$root/proposed-evidence-comment.md")" \
    --arg source "$source_commit" --arg sourceDigest "$source_digest_value" \
    --arg config "$config_digest_value" --arg toolchain "$toolchain_digest_value" \
    --argjson testOnly "$expected_test" \
    '(.schema == "hostwright.phase09.gate16.prepared-binding.v1" and .gate == 16 and .testOnly == $testOnly
      and .manifestDigest == $manifest and .dependencyEvidenceDigest == $dependency and .closurePlanDigest == $closure
      and .proposedPRBodyDigest == $body and .proposedEvidenceCommentDigest == $comment
      and .sourceCommit == $source and .sourceDigest == $sourceDigest and .configDigest == $config and .toolchainDigest == $toolchain
      and (.signingIdentity | type == "string") and (.signingFingerprint | type == "string")
      and (.certificateFingerprint | type == "string") and (.teamID | type == "string"))' \
    "$root/prepared-binding-v1.json" >/dev/null \
    || finalize_die 'Gate 16 prepared manifest or closure plan authentication binding failed.' 73
  /usr/bin/jq -e \
    '(.schema == "hostwright.phase09.gate16.prepared-seal-index.v1" and .gate == 16
      and (.artifacts | type == "array" and length > 0)
      and (.signer.identity | type == "string") and (.signer.fingerprint | type == "string")
      and (.signer.certificateFingerprint | type == "string") and (.signer.teamID | type == "string"))' \
    "$root/prepared-seal-index-v1.json" >/dev/null \
    || finalize_die 'Gate 16 prepared CMS seal index is invalid.' 73
  validate_checksum_manifest "$root" "$root/prepared-evidence-v1.sha256"
  verify_cms_bundle "$root" prepared-evidence-v1.sha256 prepared-evidence-v1.cms
  [[ "$cms_signer_identity" == "$(/usr/bin/jq -r '.signingIdentity' "$root/manifest-v1.json")" \
    && "$cms_signer_fingerprint" == "$(/usr/bin/jq -r '.signingFingerprint' "$root/manifest-v1.json")" \
    && "$cms_signer_certificate_fingerprint" == "$(/usr/bin/jq -r '.certificateFingerprint' "$root/manifest-v1.json")" \
    && "$cms_signer_team" == "$(/usr/bin/jq -r '.teamID' "$root/manifest-v1.json")" ]] \
    || finalize_die 'Gate 16 prepared CMS binding signer does not match the prepared manifest.' 73
  /usr/bin/jq -e \
    '(.schema == "hostwright.phase09.gate16.cms-signer.v1" or .schema == "hostwright.phase09.test.cms-signer.v1")
      and (.identity | type == "string") and (.fingerprint | type == "string")
      and (.certificateFingerprint | type == "string") and (.teamID | type == "string")' \
    "$root/prepared-cms-signer-v1.json" >/dev/null \
    || finalize_die 'Gate 16 prepared signer extraction receipt is invalid.' 73
  /usr/bin/jq -e \
    --arg identity "$cms_signer_identity" --arg fingerprint "$cms_signer_fingerprint" \
    --arg certificate "$cms_signer_certificate_fingerprint" --arg team "$cms_signer_team" \
    '(.identity == $identity and .fingerprint == $fingerprint
      and .certificateFingerprint == $certificate and .teamID == $team)' \
    "$root/prepared-cms-signer-v1.json" >/dev/null \
    || finalize_die 'Gate 16 prepared signer extraction receipt does not match the verified CMS certificate.' 73
}

validate_record_shape() {
  local file="$1"
  shift
  /usr/bin/jq -e "$@" "$file" >/dev/null \
    || finalize_die 'Gate 16 receipt contains missing, duplicate, or unexpected fields.' 73
}

validate_time_order() {
  local earlier="$1" later="$2" label="$3"
  is_timestamp "$earlier" && is_timestamp "$later" \
    || finalize_die "Gate 16 $label timestamp is invalid." 73
  [[ "$earlier" < "$later" ]] \
    || finalize_die "Gate 16 $label timestamps are out of order." 73
}

validate_total_timestamp_order() {
  local previous='' current label
  while IFS=$'\t' read -r current label; do
    is_timestamp "$current" \
      || finalize_die "Gate 16 $label timestamp is invalid." 73
    if [[ -n "$previous" ]]; then
      if [[ "$previous" > "$current" || "$previous" == "$current" ]]; then
        finalize_die 'Gate 16 receipt timestamps are not a strict total UTC order.' 73
      fi
    fi
    previous="$current"
  done < <(
    /usr/bin/jq -r '
      ([
        [.pullRequests[0].openedAt, "pr.opened"],
        [.pullRequests[0].mergedAt, "pr.merged"],
        [.pullRequests[0].closedAt, "pr.closed"],
        [.evidenceComment.postedAt, "comment.posted"],
        [.cleanup.recordedAt, "cleanup.recorded"],
        [.hardStop.timestamp, "hard-stop.timestamp"]
      ]
      + [.checks[] | [(.completedAt), ("check." + .objectId)]]
      + [.reviews[] | [(.submittedAt), ("review." + .objectId)]]
      + [.phase09Issues[] | [(.closedAt), ("issue." + .objectId)]]
      + [.cleanup.absenceReceipts[] | [(.observedAt), ("absence." + .objectId)]])[]
      | @tsv' "$receipts_file" | LC_ALL=C /usr/bin/sort
  )
}

validate_receipts_file() {
  # The frozen child check is phase09Issues | map(.number) | sort, with no duplicate allowance.
  validate_private_file "$receipts_file"
  [[ "$(dirname "$receipts_file")" != "$root" ]] \
    || finalize_die 'Gate 16 receipt input must remain outside the evidence root.' 73
  /usr/bin/jq empty "$receipts_file" >/dev/null \
    || finalize_die 'Gate 16 receipts are not valid JSON.' 73
  validate_record_shape "$receipts_file" \
    '(.schema == "hostwright.phase09.gate16.receipts.v1")
      and ((keys | sort) == ["checks","cleanup","evidenceComment","hardStop","mergeProof","phase09Issues","pullRequests","reviews","schema","sourceCommit"])
      and (.sourceCommit | test("^[a-f0-9]{40}$"))
      and (.pullRequests | type == "array" and length == 1)
      and (.mergeProof | type == "object")
      and (.checks | type == "array")
      and (.reviews | type == "array" and length > 0)
      and (.phase09Issues | type == "array")
      and (.evidenceComment | type == "object")
      and (.cleanup | type == "object")
      and (.hardStop | type == "object")'
  local manifest_source source_from_receipt body body_digest comment_body comment_digest merge_commit base_commit parent_line parent_count
  manifest_source="$(/usr/bin/jq -r '.sourceCommit' "$root/manifest-v1.json")"
  source_from_receipt="$(/usr/bin/jq -r '.sourceCommit' "$receipts_file")"
  [[ "$source_from_receipt" == "$manifest_source" && "$source_from_receipt" == "$source_commit" ]] \
    || finalize_die 'Gate 16 receipt source identity does not match prepared evidence.' 73
  validate_record_shape "$receipts_file" \
    --arg source "$source_from_receipt" \
    '(.pullRequests[0] | ((keys | sort) == ["baseCommit","baseRef","body","bodyDigest","closedAt","headCommit","headRef","labels","mergeCommit","merged","mergedAt","number","objectId","openedAt","state"])
      and .number == 206 and .state == "closed" and .merged == true and .headCommit == $source
      and .headRef == "feat/v0.0.2-phase-09" and .baseRef == "main"
      and (.baseCommit | test("^[a-f0-9]{40}$")) and (.mergeCommit | test("^[a-f0-9]{40}$"))
      and (.labels | type == "array" and all(.[]; type == "string") and (unique | length == length) and index("status:verification") != null)
      and (.body | type == "string" and contains("Closes #206") and contains("<!-- hostwright-evidence-gate:v1 -->"))
      and (.bodyDigest | test("^[a-f0-9]{64}$")) and (.objectId | type == "string"))'
  merge_commit="$(/usr/bin/jq -r '.pullRequests[0].mergeCommit' "$receipts_file")"
  base_commit="$(/usr/bin/jq -r '.pullRequests[0].baseCommit' "$receipts_file")"
  receipt_merge_commit="$merge_commit"
  validate_record_shape "$receipts_file" \
    --arg merge "$merge_commit" --arg base "$base_commit" --arg head "$source_commit" \
    '(.mergeProof | ((keys | sort) == ["baseCommit","commit","headCommit","objectId","parents","prNumber"])
      and .prNumber == 206 and .commit == $merge and .baseCommit == $base and .headCommit == $head
      and (.parents | type == "array" and length == 2 and .[0] == $base and .[1] == $head)
      and (.objectId | type == "string"))'
  if testing; then
    parent_count="$(/usr/bin/jq -r '.mergeProof.parents | length' "$receipts_file")"
    [[ "$parent_count" == 2 ]] || finalize_die 'Gate 16 test merge proof does not contain exactly two parents.' 73
  else
    parent_line="$(git -C "$repo_root" rev-list --parents -n 1 "$merge_commit" 2>/dev/null)" \
      || finalize_die 'Gate 16 merge identity is not a locally readable commit object.' 73
    [[ "$(printf '%s\n' "$parent_line" | /usr/bin/awk '{print $1}')" == "$merge_commit" \
      && "$(printf '%s\n' "$parent_line" | /usr/bin/awk '{print NF - 1}')" == 2 \
      && "$(printf '%s\n' "$parent_line" | /usr/bin/awk '{print $2}')" == "$base_commit" \
      && "$(printf '%s\n' "$parent_line" | /usr/bin/awk '{print $3}')" == "$source_commit" ]] \
      || finalize_die 'Gate 16 merge parents do not equal the declared base then head.' 73
    git -C "$repo_root" cat-file -e "$merge_commit^{commit}" >/dev/null 2>&1 \
      || finalize_die 'Gate 16 merge object is not a commit.' 73
    (cd "$repo_root" && git rev-list "$merge_commit") >/dev/null \
      || finalize_die 'Gate 16 merge ancestry could not be read.' 73
  fi
  body="$(/usr/bin/jq -r '.pullRequests[0].body' "$receipts_file")"
  comment_body="$(/usr/bin/jq -r '.evidenceComment.body' "$receipts_file")"
  body_digest="$(/usr/bin/jq -j '.pullRequests[0].body' "$receipts_file" | sha256_stream)"
  comment_digest="$(/usr/bin/jq -j '.evidenceComment.body' "$receipts_file" | sha256_stream)"
  [[ "$(/usr/bin/jq -r '.pullRequests[0].bodyDigest' "$receipts_file")" == "$body_digest" ]] \
    || finalize_die 'Gate 16 PR body digest is not bound to the exact receipt body.' 73
  /usr/bin/jq -j '.pullRequests[0].body' "$receipts_file" \
    | /usr/bin/cmp -s - "$root/proposed-pr-body.md" \
    || finalize_die 'Gate 16 PR body content does not exactly match the generated local draft.' 73
  validate_record_shape "$receipts_file" \
    --argjson requiredChecks "$required_checks_json" --arg source "$source_commit" --arg merge "$merge_commit" \
    '(.checks | type == "array" and ((map(.name) | sort) == ($requiredChecks | sort))
      and ((map(.name) | unique | length) == length)
      and all(.[]; ((keys | sort) == ["completedAt","conclusion","headCommit","mergeCommit","name","objectId","prNumber"])
        and .prNumber == 206 and .headCommit == $source and .mergeCommit == $merge and .conclusion == "success"
        and (.name | type == "string" and length > 0) and (.objectId | type == "string")))'
  validate_record_shape "$receipts_file" \
    --arg merge "$merge_commit" --arg head "$source_commit" \
    '(.reviews | all(.[]; ((keys | sort) == ["headCommit","mergeCommit","objectId","prNumber","reviewer","state","submittedAt"])
      and .prNumber == 206 and .headCommit == $head and .mergeCommit == $merge and .state == "APPROVED" and (.reviewer | type == "string" and length > 0)
      and (.objectId | type == "string")))'
  validate_record_shape "$receipts_file" \
    --arg marker "$evidence_marker" --arg commentDigest "$comment_digest" --arg merge "$merge_commit" --arg head "$source_commit" \
    '(.evidenceComment | ((keys | sort) == ["body","bodyDigest","headCommit","issueNumber","marker","mergeCommit","objectId","posted","postedAt","prNumber"])
      and .issueNumber == 206 and .prNumber == 206 and .headCommit == $head and .mergeCommit == $merge and .posted == true and .marker == $marker
      and (.body | type == "string" and contains($marker)) and .bodyDigest == $commentDigest and (.objectId | type == "string"))'
  /usr/bin/jq -j '.evidenceComment.body' "$receipts_file" \
    | /usr/bin/cmp -s - "$root/proposed-evidence-comment.md" \
    || finalize_die 'Gate 16 evidence comment content does not exactly match the generated local draft.' 73
  validate_record_shape "$receipts_file" \
    --argjson expected "$(expected_children)" --arg merge "$merge_commit" --arg head "$source_commit" \
    '(.phase09Issues | type == "array" and ((map(.number) | sort) == $expected)
      and ((map(.number) | unique | length) == length)
      and all(.[]; ((keys | sort) == ["closedAt","headCommit","labels","mergeCommit","number","objectId","prNumber","state"])
        and .prNumber == 206 and .headCommit == $head and .mergeCommit == $merge and .state == "closed"
        and (.labels | type == "array" and all(.[]; type == "string") and (unique | length == length) and index("status:verification") != null)
        and (.objectId | type == "string")))'
  validate_record_shape "$receipts_file" \
    --arg merge "$merge_commit" --arg head "$source_commit" --arg gate15Root "$(basename "$gate15_root")" \
    --argjson ledger "$ledger_json_value" \
    '(.cleanup | ((keys | sort) == ["absenceReceipts","activeLocks","discoveryPerformed","gate15RootBasename","headCommit","mergeCommit","objectId","ownedResources","phase09ResourcesAbsent","prNumber","recordedAt","schema","status","worktreeClean"])
      and .schema == "hostwright.phase09.gate16.cleanup.v1" and .status == "passed" and .prNumber == 206 and .headCommit == $head and .mergeCommit == $merge
      and .gate15RootBasename == $gate15Root and .worktreeClean == true and .phase09ResourcesAbsent == true and .discoveryPerformed == false
      and (.activeLocks | type == "array" and length == 0) and (.ownedResources | type == "array" and length == 0)
      and (.absenceReceipts | type == "array" and map({type,identifier,path,device,inode,identity}) == ($ledger | map({type,identifier,path,device,inode,identity}))
        and all(.[]; ((keys | sort) == ["device","gate15RootBasename","headCommit","identifier","identity","inode","mergeCommit","objectId","observedAt","observedExists","path","prNumber","status","type"])
          and .status == "absent" and .observedExists == false and .prNumber == 206 and .headCommit == $head and .mergeCommit == $merge and .gate15RootBasename == $gate15Root
          and (.objectId | type == "string"))))'
  validate_record_shape "$receipts_file" \
    --arg merge "$merge_commit" --arg head "$source_commit" \
    '(.hardStop | ((keys | sort) == ["headCommit","mergeCommit","noNextPhase","objectId","phase10Started","prNumber","publicActionsAfterMerge","recorded","releasePublished","schema","status","tagCreated","timestamp"])
      and .schema == "hostwright.phase09.gate16.hard-stop.v1" and .status == "passed" and .recorded == true and .noNextPhase == true
      and .phase10Started == false and .tagCreated == false and .releasePublished == false and .publicActionsAfterMerge == 0
      and .prNumber == 206 and .headCommit == $head and .mergeCommit == $merge and (.objectId | type == "string"))'
  /usr/bin/jq -e \
    '[.pullRequests[].objectId,.mergeProof.objectId,.checks[].objectId,.reviews[].objectId,.phase09Issues[].objectId,.evidenceComment.objectId,.cleanup.objectId,.hardStop.objectId] as $ids
      | all($ids[]; type == "string" and length > 0) and (($ids | unique | length) == ($ids | length))' "$receipts_file" >/dev/null \
    || finalize_die 'Gate 16 receipt object IDs are missing or duplicated.' 73
  local pr_opened pr_merged pr_closed evidence_posted cleanup_recorded hard_stop_at
  pr_opened="$(/usr/bin/jq -r '.pullRequests[0].openedAt' "$receipts_file")"
  pr_merged="$(/usr/bin/jq -r '.pullRequests[0].mergedAt' "$receipts_file")"
  pr_closed="$(/usr/bin/jq -r '.pullRequests[0].closedAt' "$receipts_file")"
  evidence_posted="$(/usr/bin/jq -r '.evidenceComment.postedAt' "$receipts_file")"
  cleanup_recorded="$(/usr/bin/jq -r '.cleanup.recordedAt' "$receipts_file")"
  hard_stop_at="$(/usr/bin/jq -r '.hardStop.timestamp' "$receipts_file")"
  validate_time_order "$pr_opened" "$pr_merged" 'PR open/merge'
  validate_time_order "$pr_merged" "$pr_closed" 'PR merge/close'
  validate_time_order "$pr_closed" "$evidence_posted" 'PR close/evidence comment'
  validate_time_order "$evidence_posted" "$cleanup_recorded" 'evidence comment/cleanup'
  validate_time_order "$cleanup_recorded" "$hard_stop_at" 'cleanup/hard stop'
  while IFS=$'\t' read -r check_time object_id; do
    validate_time_order "$pr_opened" "$check_time" 'PR/check'
    validate_time_order "$check_time" "$pr_merged" 'check/merge'
  done < <(/usr/bin/jq -r '.checks[] | [.completedAt,.objectId] | @tsv' "$receipts_file")
  while IFS=$'\t' read -r review_time object_id; do
    validate_time_order "$pr_opened" "$review_time" 'PR/review'
    validate_time_order "$review_time" "$pr_merged" 'review/merge'
  done < <(/usr/bin/jq -r '.reviews[] | [.submittedAt,.objectId] | @tsv' "$receipts_file")
  while IFS=$'\t' read -r issue_time object_id; do
    validate_time_order "$pr_closed" "$issue_time" 'PR/issue closure'
    validate_time_order "$issue_time" "$cleanup_recorded" 'issue closure/cleanup'
  done < <(/usr/bin/jq -r '.phase09Issues[] | [.closedAt,.objectId] | @tsv' "$receipts_file")
  while IFS=$'\t' read -r observed_time object_id; do
    validate_time_order "$evidence_posted" "$observed_time" 'evidence comment/absence observation'
    validate_time_order "$observed_time" "$cleanup_recorded" 'absence observation/cleanup'
  done < <(/usr/bin/jq -r '.cleanup.absenceReceipts[] | [.observedAt,.objectId] | @tsv' "$receipts_file")
  validate_total_timestamp_order
}

artifact_root() {
  if [[ -n "$staged_root" ]]; then
    printf '%s\n' "$staged_root"
  else
    printf '%s\n' "$root"
  fi
}

write_governance_event() {
  local body labels
  local destination="$(artifact_root)"
  body="$(/usr/bin/jq -r '.pullRequests[0].body' "$receipts_file")"
  labels="$(/usr/bin/jq -c '.pullRequests[0].labels | map({name: .})' "$receipts_file")"
  /usr/bin/jq -n --arg body "$body" --argjson labels "$labels" \
    --arg source "$source_commit" --arg head "$source_commit" \
    --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
    '{sourceCommit:$source,headCommit:$head,mergeCommit:$merge,prNumber:$pr,
      pull_request:{body:$body,labels:$labels}}' > "$destination/governance-event-v1.json"
  chmod 600 "$destination/governance-event-v1.json"
}

run_local_final_checks() {
  local status=0
  run_governance_check roadmap_validate env PYTHONDONTWRITEBYTECODE=1 python3 scripts/roadmap-governance.py validate || status=1
  run_governance_check roadmap_self_test env PYTHONDONTWRITEBYTECODE=1 python3 scripts/roadmap-governance.py self-test || status=1
  run_governance_check roadmap_check_pr env PYTHONDONTWRITEBYTECODE=1 python3 scripts/roadmap-governance.py check-pr --event "$(artifact_root)/governance-event-v1.json" || status=1
  if testing; then
    return "$status"
  fi
  run_governance_check control_plane_tests swift test --jobs 1 --filter HostwrightControlPlaneTests || status=1
  run_governance_check control_plane_build swift build --jobs 1 --target HostwrightControlPlane || status=1
  run_governance_check lint scripts/lint.sh || status=1
  run_governance_check docs scripts/check-docs.sh || status=1
  run_governance_check diff git diff --check || status=1
  [[ "$status" == 0 ]]
}

write_hard_stop() {
  local destination="$(artifact_root)"
  /usr/bin/jq -S \
    --arg source "$source_commit" --arg head "$source_commit" --arg merge "$receipt_merge_commit" \
    --arg pr "206" --arg recordedAt "$(/usr/bin/jq -r '.hardStop.timestamp' "$receipts_file")" \
    '{schema:"hostwright.phase09.gate16.hard-stop.v1",status:"passed",formal:(env.HOSTWRIGHT_PHASE09_HARNESS_TESTING != "1"),claim:(if (env.HOSTWRIGHT_PHASE09_HARNESS_TESTING == "1") then "none" else "passed" end),
      sourceCommit:$source,headCommit:$head,prNumber:($pr|tonumber),mergeCommit:$merge,recordedAt:$recordedAt,receipt:.hardStop}' \
    "$receipts_file" > "$destination/hard-stop-v1.json"
  chmod 600 "$destination/hard-stop-v1.json"
}

write_cleanup_receipt() {
  local destination="$(artifact_root)"
  /usr/bin/jq -S \
    --arg source "$source_commit" --arg head "$source_commit" \
    --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
    '.cleanup + {sourceCommit:$source,headCommit:$head,mergeCommit:$merge,prNumber:$pr}' \
    "$receipts_file" > "$destination/cleanup-v1.json"
  chmod 600 "$destination/cleanup-v1.json"
}

stage_final_directory() {
  local name
  [[ ! -e "$root/final-v1" && ! -L "$root/final-v1" ]] \
    || finalize_die 'Gate 16 final-v1 publication already exists; retry is forbidden.' 75
  [[ ! -e "$root/.final-v1.next" && ! -L "$root/.final-v1.next" ]] \
    || finalize_die 'Gate 16 final-v1 staging directory already exists; preserve the root.' 75
  staged_root="$root/.final-v1.next"
  mkdir "$staged_root" || finalize_die 'Gate 16 final-v1 staging directory could not be created.' 75
  chmod 700 "$staged_root"
  for name in closure-plan-v1.json dependency-evidence-v1.json manifest-v1.json ownership-v1.tsv \
    prepared-binding-v1.json prepared-cms-signer-v1.json prepared-evidence-v1.cms prepared-evidence-v1.sha256 \
    prepared-seal-index-v1.json proposed-evidence-comment.md proposed-pr-body.md state-v1.tsv toolchain-v1.txt; do
    validate_private_file "$root/$name"
    /bin/cp "$root/$name" "$staged_root/$name" \
      || finalize_die "Gate 16 could not stage $name for atomic publication." 73
    chmod 600 "$staged_root/$name"
    validate_private_file "$staged_root/$name"
  done
}

bind_json_record() {
  local file="$1" staged="${1}.final-binding"
  validate_private_file "$file"
  [[ ! -e "$staged" && ! -L "$staged" ]] \
    || finalize_die "Gate 16 final binding temporary already exists: $(basename "$staged")" 73
  /usr/bin/jq -S \
    --arg source "$source_commit" --arg head "$source_commit" \
    --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
    '.sourceCommit=$source|.headCommit=$head|.mergeCommit=$merge|.prNumber=$pr' \
    "$file" > "$staged" \
    || finalize_die "Gate 16 final binding could not be written: $(basename "$file")" 73
  chmod 600 "$staged"
  validate_private_file "$staged"
  /bin/mv "$staged" "$file" \
    || finalize_die "Gate 16 final binding could not be published in staging: $(basename "$file")" 73
}

write_staged_prepared_seal() {
  local destination="$(artifact_root)" names name artifacts='[]'
  names='closure-plan-v1.json dependency-evidence-v1.json manifest-v1.json ownership-v1.tsv prepared-binding-v1.json proposed-evidence-comment.md proposed-pr-body.md state-v1.tsv toolchain-v1.txt'
  for name in $names; do
    validate_private_file "$destination/$name"
    artifacts="$(/usr/bin/jq -c --arg name "$name" --arg digest "$(sha256_file "$destination/$name")" \
      '. + [{name:$name,sha256:$digest}]' <<< "$artifacts")"
  done
  /usr/bin/jq -n -S \
    --arg schema 'hostwright.phase09.gate16.prepared-seal-index.v1' \
    --arg source "$source_commit" --arg head "$source_commit" \
    --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
    --arg sourceDigest "$source_digest_value" \
    --arg identity "$gate15_signer_identity" --arg fingerprint "$gate15_signer_fingerprint" \
    --arg certificate "$gate15_signer_certificate_fingerprint" --arg team "$gate15_signer_team" \
    --argjson artifacts "$artifacts" \
    '{schema:$schema,gate:16,sourceCommit:$source,headCommit:$head,mergeCommit:$merge,prNumber:$pr,sourceDigest:$sourceDigest,
      signer:{identity:$identity,fingerprint:$fingerprint,certificateFingerprint:$certificate,teamID:$team},
      artifacts:$artifacts,excludes:["prepared-evidence-v1.sha256","prepared-evidence-v1.cms","prepared-cms-signer-v1.json"]}' \
    > "$destination/prepared-seal-index-v1.json"
  chmod 600 "$destination/prepared-seal-index-v1.json"
  write_checksum_manifest "$destination" "$destination/prepared-evidence-v1.sha256" \
    $names prepared-seal-index-v1.json
  sign_cms_payload "$destination/prepared-evidence-v1.sha256" "$destination/prepared-evidence-v1.cms"
  verify_cms_bundle "$destination" prepared-evidence-v1.sha256 prepared-evidence-v1.cms
  [[ "$cms_signer_identity" == "$gate15_signer_identity" \
    && "$cms_signer_fingerprint" == "$gate15_signer_fingerprint" \
    && "$cms_signer_certificate_fingerprint" == "$gate15_signer_certificate_fingerprint" \
    && "$cms_signer_team" == "$gate15_signer_team" ]] \
    || finalize_die 'Gate 16 staged prepared CMS signer does not match the verified Gate15 signer.' 73
  write_signer_metadata "$destination/prepared-cms-signer-v1.json"
}

bind_staged_prepared_records() {
  local destination="$(artifact_root)"
  bind_json_record "$destination/dependency-evidence-v1.json"
  bind_json_record "$destination/closure-plan-v1.json"
  local closure_tmp="$destination/closure-plan-v1.json.final-binding"
  [[ ! -e "$closure_tmp" && ! -L "$closure_tmp" ]] \
    || finalize_die 'Gate 16 staged closure binding temporary already exists.' 73
  /usr/bin/jq -S \
    --arg manifestDigest "$(sha256_file "$destination/manifest-v1.json")" \
    --arg dependencyDigest "$(sha256_file "$destination/dependency-evidence-v1.json")" \
    '.preparedManifestDigest=$manifestDigest|.dependencyEvidenceDigest=$dependencyDigest' \
    "$destination/closure-plan-v1.json" > "$closure_tmp" \
    || finalize_die 'Gate 16 staged closure binding could not be refreshed.' 73
  chmod 600 "$closure_tmp"
  validate_private_file "$closure_tmp"
  /bin/mv "$closure_tmp" "$destination/closure-plan-v1.json" \
    || finalize_die 'Gate 16 staged closure binding could not be published.' 73

  local binding_tmp="$destination/prepared-binding-v1.json.final-binding"
  [[ ! -e "$binding_tmp" && ! -L "$binding_tmp" ]] \
    || finalize_die 'Gate 16 staged prepared binding temporary already exists.' 73
  /usr/bin/jq -S \
    --arg manifestDigest "$(sha256_file "$destination/manifest-v1.json")" \
    --arg dependencyDigest "$(sha256_file "$destination/dependency-evidence-v1.json")" \
    --arg closureDigest "$(sha256_file "$destination/closure-plan-v1.json")" \
    --arg bodyDigest "$(sha256_file "$destination/proposed-pr-body.md")" \
    --arg commentDigest "$(sha256_file "$destination/proposed-evidence-comment.md")" \
    --arg source "$source_commit" --arg sourceDigest "$source_digest_value" \
    --arg configDigest "$config_digest_value" --arg toolchainDigest "$toolchain_digest_value" \
    --arg head "$source_commit" --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
    '.manifestDigest=$manifestDigest|.dependencyEvidenceDigest=$dependencyDigest|.closurePlanDigest=$closureDigest
      |.proposedPRBodyDigest=$bodyDigest|.proposedEvidenceCommentDigest=$commentDigest
      |.sourceCommit=$source|.sourceDigest=$sourceDigest|.configDigest=$configDigest|.toolchainDigest=$toolchainDigest
      |.headCommit=$head|.mergeCommit=$merge|.prNumber=$pr' \
    "$destination/prepared-binding-v1.json" > "$binding_tmp" \
    || finalize_die 'Gate 16 staged prepared binding could not be rebuilt.' 73
  chmod 600 "$binding_tmp"
  validate_private_file "$binding_tmp"
  /bin/mv "$binding_tmp" "$destination/prepared-binding-v1.json" \
    || finalize_die 'Gate 16 staged prepared binding could not be published.' 73
  write_staged_prepared_seal
}

tamper_staged_binding_for_test() {
  testing && [[ "${HOSTWRIGHT_PHASE09_TEST_STAGED_BINDING_TAMPER:-0}" == 1 ]] || return 0
  local destination target staged
  destination="$(artifact_root)"
  target="$destination/prepared-binding-v1.json"
  staged="$destination/.prepared-binding-v1.tampered"
  [[ ! -e "$staged" && ! -L "$staged" ]] \
    || finalize_die 'Gate 16 staged binding tamper fixture already exists.' 73
  /usr/bin/jq '.manifestDigest=("f" * 64)' "$target" > "$staged" \
    || finalize_die 'Gate 16 staged binding tamper fixture could not be written.' 73
  chmod 600 "$staged"
  validate_private_file "$staged"
  /bin/mv "$staged" "$target" \
    || finalize_die 'Gate 16 staged binding tamper fixture could not be published.' 73
}

write_closure_receipt() {
  local destination="$(artifact_root)"
  /usr/bin/jq -S \
    --arg source "$source_commit" --arg head "$source_commit" \
    --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
    '. + {sourceCommit:$source,headCommit:$head,mergeCommit:$merge,prNumber:$pr}' \
    "$receipts_file" > "$destination/closure-receipts-v1.json"
  chmod 600 "$destination/closure-receipts-v1.json"
}

write_preseal_index() {
  local destination="$(artifact_root)" names name artifacts='[]'
  names='cleanup-v1.json closure-plan-v1.json closure-receipts-v1.json dependency-evidence-v1.json governance-event-v1.json hard-stop-v1.json manifest-v1.json ownership-v1.tsv prepared-binding-v1.json prepared-cms-signer-v1.json prepared-evidence-v1.cms prepared-evidence-v1.sha256 prepared-seal-index-v1.json proposed-evidence-comment.md proposed-pr-body.md state-v1.tsv toolchain-v1.txt cms-signer-v1.json'
  for name in $names; do
    [[ -f "$destination/$name" ]] || finalize_die "Gate 16 preseal artifact is missing: $name" 73
    artifacts="$(/usr/bin/jq -c --arg name "$name" --arg digest "$(sha256_file "$destination/$name")" \
      '. + [{name:$name,sha256:$digest,semantic:true}]' <<< "$artifacts")"
  done
  /usr/bin/jq -n -S \
    --arg schema 'hostwright.phase09.gate16.preseal-index.v1' \
    --arg source "$source_commit" --arg head "$source_commit" \
    --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
    --arg sourceDigest "$source_digest_value" --argjson artifacts "$artifacts" \
    '{schema:$schema,gate:16,sourceCommit:$source,headCommit:$head,mergeCommit:$merge,prNumber:$pr,sourceDigest:$sourceDigest,artifacts:$artifacts,
      includesStructuredHardStop:(any($artifacts[]; .name == "hard-stop-v1.json")),
      includesExtractedSigner:(any($artifacts[]; .name == "cms-signer-v1.json")),
      circularDigestsExcluded:["evidence-v1.sha256","evidence-v1.cms","seal-v1.json"]}' \
    > "$destination/preseal-index-v1.json"
  chmod 600 "$destination/preseal-index-v1.json"
}

write_staged_manifest() {
  local status='passed' claim='formal' test_value=false destination="$(artifact_root)"
  if testing; then status='test-passed'; claim='none'; test_value=true; fi
  /usr/bin/jq --arg status "$status" --arg claim "$claim" --arg completed "$(timestamp)" \
    --arg source "$source_commit" --arg head "$source_commit" \
    --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
    --argjson testOnly "$test_value" \
    '.status=$status|.claim=$claim|.formal=($status=="passed")|.formalClaim=($status=="passed")
      |.testMode=$testOnly|.testOnly=$testOnly|.qualifying=($status=="passed")|.sealed=true|.terminal=true|.completedAt=$completed
      |.sourceCommit=$source|.headCommit=$head|.mergeCommit=$merge|.prNumber=$pr' \
    "$root/manifest-v1.json" > "$destination/manifest-v1.json"
  chmod 600 "$destination/manifest-v1.json"
}

write_staged_seal() {
  local test_value=false destination="$(artifact_root)"
  local identity="$gate15_signer_identity" fingerprint="$gate15_signer_fingerprint"
  local certificate="$gate15_signer_certificate_fingerprint" team="$gate15_signer_team"
  testing && test_value=true
  /usr/bin/jq -n -S \
    --arg source "$source_commit" --arg head "$source_commit" --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
    --arg manifest "$(sha256_file "$destination/manifest-v1.json")" \
    --arg preseal "$(sha256_file "$destination/preseal-index-v1.json")" --arg hardStop "$(sha256_file "$destination/hard-stop-v1.json")" \
    --arg signerMetadata "$(sha256_file "$destination/cms-signer-v1.json")" \
    --arg identity "$identity" --arg fingerprint "$fingerprint" --arg certificate "$certificate" --arg team "$team" \
    --argjson testOnly "$test_value" \
    '{schema:"hostwright.phase09.gate16.seal.v1",gate:16,status:(if $testOnly then "test-sealed" else "sealed" end),
      claim:(if $testOnly then "none" else "formal" end),sealed:true,
      formal:(if $testOnly then false else true end),formalClaim:(if $testOnly then false else true end),
      testMode:$testOnly,testOnly:$testOnly,qualifying:(if $testOnly then false else true end),
      sourceCommit:$source,headCommit:$head,mergeCommit:$merge,prNumber:$pr,manifestDigest:$manifest,presealIndexDigest:$preseal,hardStopDigest:$hardStop,
      signerMetadataDigest:$signerMetadata,
      cmsSigner:{identity:$identity,fingerprint:$fingerprint,certificateFingerprint:$certificate,teamID:$team},
      circularity:{sealDigestExcluded:true,cmsDigestExcluded:true},terminal:true}' \
    > "$destination/seal-v1.json"
  chmod 600 "$destination/seal-v1.json"
}

validate_final_marker_set() {
  local destination="$(artifact_root)" expected_test=false
  testing && expected_test=true
  /usr/bin/jq -e --argjson testOnly "$expected_test" \
    '(.formal == (if $testOnly then false else true end)
      and .formalClaim == (if $testOnly then false else true end)
      and .testMode == $testOnly and .testOnly == $testOnly
      and .qualifying == (if $testOnly then false else true end)
      and .sealed == true)' "$destination/manifest-v1.json" >/dev/null \
    || finalize_die 'Gate 16 final manifest marker profile is incomplete or contradictory.' 73
  /usr/bin/jq -e --argjson testOnly "$expected_test" \
    '(.claim == (if $testOnly then "none" else "formal" end)
      and .formal == (if $testOnly then false else true end)
      and .formalClaim == (if $testOnly then false else true end)
      and .testMode == $testOnly and .testOnly == $testOnly
      and .qualifying == (if $testOnly then false else true end)
      and .sealed == true)' "$destination/seal-v1.json" >/dev/null \
    || finalize_die 'Gate 16 final seal marker profile is incomplete or contradictory.' 73
  /usr/bin/jq -e --slurpfile seal "$destination/seal-v1.json" \
    '(.formal == $seal[0].formal and .formalClaim == $seal[0].formalClaim
      and .testMode == $seal[0].testMode and .testOnly == $seal[0].testOnly
      and .qualifying == $seal[0].qualifying and .sealed == $seal[0].sealed)' \
    "$destination/manifest-v1.json" >/dev/null \
    || finalize_die 'Gate 16 final-v1 and reused evidence marker sets differ.' 73
  /usr/bin/jq -e --slurpfile reused "$gate15_manifest" \
    ' . as $current | $reused[0] as $reuse
      | ["formal","formalClaim","testMode","qualifying","sealed"] as $markers
      | (($markers | map(. as $key | select($current | has($key))))
         == ($markers | map(. as $key | select($reuse | has($key)))))
      and all($markers[]; . as $key | $current[$key] == $reuse[$key])' \
    "$destination/manifest-v1.json" >/dev/null \
    || finalize_die 'Gate 16 final-v1 and reused Gate15 evidence marker sets differ.' 73
}

validate_final_bindings() {
  local destination="$(artifact_root)" name expected actual expected_test=false
  local names='cleanup-v1.json closure-plan-v1.json closure-receipts-v1.json cms-signer-v1.json dependency-evidence-v1.json governance-event-v1.json hard-stop-v1.json manifest-v1.json preseal-index-v1.json prepared-binding-v1.json prepared-cms-signer-v1.json prepared-seal-index-v1.json seal-v1.json'
  local prepared_names='closure-plan-v1.json dependency-evidence-v1.json manifest-v1.json ownership-v1.tsv prepared-binding-v1.json proposed-evidence-comment.md proposed-pr-body.md state-v1.tsv toolchain-v1.txt prepared-seal-index-v1.json'
  local prepared_artifact_names='closure-plan-v1.json dependency-evidence-v1.json manifest-v1.json ownership-v1.tsv prepared-binding-v1.json proposed-evidence-comment.md proposed-pr-body.md state-v1.tsv toolchain-v1.txt'
  local preseal_names='cleanup-v1.json closure-plan-v1.json closure-receipts-v1.json dependency-evidence-v1.json governance-event-v1.json hard-stop-v1.json manifest-v1.json ownership-v1.tsv prepared-binding-v1.json prepared-cms-signer-v1.json prepared-evidence-v1.cms prepared-evidence-v1.sha256 prepared-seal-index-v1.json proposed-evidence-comment.md proposed-pr-body.md state-v1.tsv toolchain-v1.txt cms-signer-v1.json'
  local evidence_names='cleanup-v1.json closure-plan-v1.json closure-receipts-v1.json dependency-evidence-v1.json governance-event-v1.json hard-stop-v1.json manifest-v1.json ownership-v1.tsv prepared-binding-v1.json prepared-cms-signer-v1.json prepared-evidence-v1.cms prepared-evidence-v1.sha256 prepared-seal-index-v1.json proposed-evidence-comment.md proposed-pr-body.md seal-v1.json preseal-index-v1.json state-v1.tsv toolchain-v1.txt cms-signer-v1.json'
  testing && expected_test=true
  for name in $names; do
    validate_private_file "$destination/$name"
    /usr/bin/jq -e \
      --arg source "$source_commit" --arg head "$source_commit" \
      --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
      '(.sourceCommit == $source and .headCommit == $head and .mergeCommit == $merge and .prNumber == $pr)' \
      "$destination/$name" >/dev/null \
      || finalize_die "Gate 16 final record binding is inconsistent: $name" 73
  done

  /usr/bin/jq -e --argjson testOnly "$expected_test" \
    '(.status == (if $testOnly then "test-passed" else "passed" end)
      and .formal == (if $testOnly then false else true end)
      and .formalClaim == (if $testOnly then false else true end)
      and .testMode == $testOnly and .testOnly == $testOnly
      and .qualifying == (if $testOnly then false else true end)
      and .sealed == true
      and .terminal == true)' "$destination/manifest-v1.json" >/dev/null \
    || finalize_die 'Gate 16 staged manifest formality or terminal status is invalid.' 73

  /usr/bin/jq -e \
    --arg source "$source_commit" --arg head "$source_commit" --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
    --arg manifestDigest "$(sha256_file "$destination/manifest-v1.json")" \
    --arg dependencyDigest "$(sha256_file "$destination/dependency-evidence-v1.json")" \
    --arg closureDigest "$(sha256_file "$destination/closure-plan-v1.json")" \
    --arg bodyDigest "$(sha256_file "$destination/proposed-pr-body.md")" \
    --arg commentDigest "$(sha256_file "$destination/proposed-evidence-comment.md")" \
    --arg sourceDigest "$source_digest_value" --arg configDigest "$config_digest_value" \
    --arg toolchainDigest "$toolchain_digest_value" --argjson testOnly "$expected_test" \
    --arg identity "$gate15_signer_identity" --arg fingerprint "$gate15_signer_fingerprint" \
    --arg certificate "$gate15_signer_certificate_fingerprint" --arg team "$gate15_signer_team" \
    '(.schema == "hostwright.phase09.gate16.prepared-binding.v1" and .gate == 16 and .testOnly == $testOnly
      and .manifestDigest == $manifestDigest and .dependencyEvidenceDigest == $dependencyDigest
      and .closurePlanDigest == $closureDigest and .proposedPRBodyDigest == $bodyDigest
      and .proposedEvidenceCommentDigest == $commentDigest and .sourceCommit == $source
      and .headCommit == $head and .mergeCommit == $merge and .prNumber == $pr
      and .sourceDigest == $sourceDigest and .configDigest == $configDigest and .toolchainDigest == $toolchainDigest
      and .signingIdentity == $identity and .signingFingerprint == $fingerprint
      and .certificateFingerprint == $certificate and .teamID == $team)' \
    "$destination/prepared-binding-v1.json" >/dev/null \
    || finalize_die 'Gate 16 staged prepared-binding-v1.json is stale or not bound to exact final bytes.' 73

  /usr/bin/jq -e \
    --arg source "$source_commit" --arg head "$source_commit" --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
    --arg manifestDigest "$(sha256_file "$destination/manifest-v1.json")" \
    --arg dependencyDigest "$(sha256_file "$destination/dependency-evidence-v1.json")" \
    --arg identity "$gate15_signer_identity" --arg fingerprint "$gate15_signer_fingerprint" \
    --arg certificate "$gate15_signer_certificate_fingerprint" --arg team "$gate15_signer_team" \
    '(.schema == "hostwright.phase09.gate16.closure-plan.v1" and .gate == 16 and .claim == "none"
      and .sourceCommit == $source and .headCommit == $head and .mergeCommit == $merge and .prNumber == $pr
      and .preparedManifestDigest == $manifestDigest and .dependencyEvidenceDigest == $dependencyDigest
      and .signingIdentity == $identity and .signingFingerprint == $fingerprint
      and .certificateFingerprint == $certificate and .teamID == $team)' \
    "$destination/closure-plan-v1.json" >/dev/null \
    || finalize_die 'Gate 16 staged closure plan is stale or not bound to exact final bytes.' 73

  /usr/bin/jq -e \
    --arg source "$source_commit" --arg head "$source_commit" --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
    --argjson testOnly "$expected_test" \
    '(.schema == "hostwright.phase09.gate16.dependency-evidence.v1" and .gate == 16 and .status == "verified"
      and .testOnly == $testOnly and .sourceCommit == $source and .headCommit == $head and .mergeCommit == $merge and .prNumber == $pr
      and (.gate15 | type == "object") and (.gate15.manifestDigest | test("^[a-f0-9]{64}$"))
      and (.gate15.dependencyEvidenceDigest | test("^[a-f0-9]{64}$"))
      and (.gate15.checksumDigest | test("^[a-f0-9]{64}$")) and (.gate15.cmsDigest | test("^[a-f0-9]{64}$")))' \
    "$destination/dependency-evidence-v1.json" >/dev/null \
    || finalize_die 'Gate 16 staged dependency evidence binding is invalid.' 73

  local prepared_names_json preseal_names_json evidence_names_json
  prepared_names_json="$(printf '%s\n' $prepared_artifact_names | /usr/bin/jq -Rsc 'split("\n") | map(select(length > 0))')"
  preseal_names_json="$(printf '%s\n' $preseal_names | /usr/bin/jq -Rsc 'split("\n") | map(select(length > 0))')"
  evidence_names_json="$(printf '%s\n' $evidence_names | /usr/bin/jq -Rsc 'split("\n") | map(select(length > 0))')"
  /usr/bin/jq -e \
    --arg source "$source_commit" --arg head "$source_commit" --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
    --arg sourceDigest "$source_digest_value" --arg identity "$gate15_signer_identity" \
    --arg fingerprint "$gate15_signer_fingerprint" --arg certificate "$gate15_signer_certificate_fingerprint" \
    --arg team "$gate15_signer_team" --argjson expected "$prepared_names_json" \
    '(.schema == "hostwright.phase09.gate16.prepared-seal-index.v1" and .gate == 16
      and .sourceCommit == $source and .headCommit == $head and .mergeCommit == $merge and .prNumber == $pr
      and .sourceDigest == $sourceDigest and .signer == {identity:$identity,fingerprint:$fingerprint,certificateFingerprint:$certificate,teamID:$team}
      and (.artifacts | type == "array" and (map(.name) | sort) == ($expected | sort)
        and (map(.name) | unique | length) == length
        and all(.[]; (.name | type == "string") and (.sha256 | type == "string" and test("^[a-f0-9]{64}$"))))
      and .excludes == ["prepared-evidence-v1.sha256","prepared-evidence-v1.cms","prepared-cms-signer-v1.json"])' \
    "$destination/prepared-seal-index-v1.json" >/dev/null \
    || finalize_die 'Gate 16 prepared seal index does not bind the exact staged prepared set.' 73
  /usr/bin/jq -e \
    --arg source "$source_commit" --arg head "$source_commit" --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
    --arg sourceDigest "$source_digest_value" --arg identity "$gate15_signer_identity" \
    --arg fingerprint "$gate15_signer_fingerprint" --arg certificate "$gate15_signer_certificate_fingerprint" \
    --arg team "$gate15_signer_team" --argjson expected "$preseal_names_json" \
    '(.schema == "hostwright.phase09.gate16.preseal-index.v1" and .gate == 16
      and .sourceCommit == $source and .headCommit == $head and .mergeCommit == $merge and .prNumber == $pr
      and .sourceDigest == $sourceDigest
      and (.artifacts | type == "array" and (map(.name) | sort) == ($expected | sort)
        and (map(.name) | unique | length) == length
        and all(.[]; .semantic == true and (.sha256 | type == "string" and test("^[a-f0-9]{64}$"))))
      and .includesStructuredHardStop == true and .includesExtractedSigner == true)' \
    "$destination/preseal-index-v1.json" >/dev/null \
    || finalize_die 'Gate 16 preseal index does not bind the exact staged final set.' 73

  while IFS=$'\t' read -r name expected; do
    [[ -n "$name" && "$name" != */* && "$name" != *$'\n'* ]] \
      || finalize_die 'Gate 16 preseal index contains an unsafe artifact name.' 73
    [[ -f "$destination/$name" && ! -L "$destination/$name" ]] \
      || finalize_die "Gate 16 preseal index references a missing artifact: $name" 73
    actual="$(sha256_file "$destination/$name")"
    [[ "$actual" == "$expected" ]] \
      || finalize_die "Gate 16 preseal digest is inconsistent: $name" 73
  done < <(/usr/bin/jq -r '.artifacts[] | [.name,.sha256] | @tsv' "$destination/preseal-index-v1.json")

  if [[ "$(/usr/bin/awk '{print $2}' "$destination/prepared-evidence-v1.sha256" | LC_ALL=C /usr/bin/sort)" != "$(printf '%s\n' $prepared_names | LC_ALL=C /usr/bin/sort)" ]]; then
    finalize_die 'Gate 16 prepared checksum manifest does not contain the exact prepared set.' 73
  fi
  validate_checksum_manifest "$destination" "$destination/prepared-evidence-v1.sha256"
  verify_cms_bundle "$destination" prepared-evidence-v1.sha256 prepared-evidence-v1.cms
  /usr/bin/jq -e \
    --arg source "$source_commit" --arg head "$source_commit" --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
    --arg identity "$cms_signer_identity" --arg fingerprint "$cms_signer_fingerprint" \
    --arg certificate "$cms_signer_certificate_fingerprint" --arg team "$cms_signer_team" \
    '((.schema == "hostwright.phase09.test.cms-signer.v1" or .schema == "hostwright.phase09.gate16.cms-signer.v1")
      and .identity == $identity and .fingerprint == $fingerprint and .certificateFingerprint == $certificate and .teamID == $team
      and .sourceCommit == $source and .headCommit == $head and .mergeCommit == $merge and .prNumber == $pr)' \
    "$destination/prepared-cms-signer-v1.json" >/dev/null \
    || finalize_die 'Gate 16 prepared CMS signer relationship is invalid.' 73

  if [[ "$(/usr/bin/awk '{print $2}' "$destination/evidence-v1.sha256" | LC_ALL=C /usr/bin/sort)" != "$(printf '%s\n' $evidence_names | LC_ALL=C /usr/bin/sort)" ]]; then
    finalize_die 'Gate 16 final checksum manifest does not contain the exact final set.' 73
  fi
  validate_checksum_manifest "$destination" "$destination/evidence-v1.sha256"
  verify_cms_bundle "$destination" evidence-v1.sha256 evidence-v1.cms
  [[ "$cms_signer_identity" == "$gate15_signer_identity" \
    && "$cms_signer_fingerprint" == "$gate15_signer_fingerprint" \
    && "$cms_signer_certificate_fingerprint" == "$gate15_signer_certificate_fingerprint" \
    && "$cms_signer_team" == "$gate15_signer_team" ]] \
    || finalize_die 'Gate 16 final CMS relationship does not match the pinned Gate15 signer.' 73

  expected="$(sha256_file "$destination/manifest-v1.json")"
  actual="$(/usr/bin/jq -r '.manifestDigest' "$destination/seal-v1.json")"
  [[ "$actual" == "$expected" ]] \
    || finalize_die 'Gate 16 seal manifest binding is inconsistent.' 73
  expected="$(sha256_file "$destination/preseal-index-v1.json")"
  actual="$(/usr/bin/jq -r '.presealIndexDigest' "$destination/seal-v1.json")"
  [[ "$actual" == "$expected" ]] \
    || finalize_die 'Gate 16 seal preseal binding is inconsistent.' 73
  expected="$(sha256_file "$destination/hard-stop-v1.json")"
  actual="$(/usr/bin/jq -r '.hardStopDigest' "$destination/seal-v1.json")"
  [[ "$actual" == "$expected" ]] \
    || finalize_die 'Gate 16 seal hard-stop binding is inconsistent.' 73
  expected="$(sha256_file "$destination/cms-signer-v1.json")"
  actual="$(/usr/bin/jq -r '.signerMetadataDigest' "$destination/seal-v1.json")"
  [[ "$actual" == "$expected" ]] \
    || finalize_die 'Gate 16 seal signer binding is inconsistent.' 73
  /usr/bin/jq -e \
    --arg source "$source_commit" --arg head "$source_commit" --arg merge "$receipt_merge_commit" --argjson pr "$issue_number" \
    --argjson testOnly "$expected_test" --arg identity "$gate15_signer_identity" \
    --arg fingerprint "$gate15_signer_fingerprint" --arg certificate "$gate15_signer_certificate_fingerprint" \
    --arg team "$gate15_signer_team" \
    '(.schema == "hostwright.phase09.gate16.seal.v1" and .gate == 16
      and .status == (if $testOnly then "test-sealed" else "sealed" end)
      and .claim == (if $testOnly then "none" else "formal" end) and .sealed == true
      and .formal == (if $testOnly then false else true end)
      and .formalClaim == (if $testOnly then false else true end)
      and .testMode == $testOnly and .testOnly == $testOnly
      and .qualifying == (if $testOnly then false else true end)
      and .sourceCommit == $source and .headCommit == $head and .mergeCommit == $merge and .prNumber == $pr
      and .terminal == true and .cmsSigner == {identity:$identity,fingerprint:$fingerprint,certificateFingerprint:$certificate,teamID:$team})' \
    "$destination/seal-v1.json" >/dev/null \
    || finalize_die 'Gate 16 final seal status or signer relationship is invalid.' 73
}

write_evidence_digest() {
  local destination="$(artifact_root)"
  write_checksum_manifest "$destination" "$destination/evidence-v1.sha256" \
    cleanup-v1.json closure-plan-v1.json closure-receipts-v1.json dependency-evidence-v1.json \
    governance-event-v1.json hard-stop-v1.json manifest-v1.json ownership-v1.tsv \
    prepared-binding-v1.json prepared-cms-signer-v1.json prepared-evidence-v1.cms \
    prepared-evidence-v1.sha256 prepared-seal-index-v1.json proposed-evidence-comment.md \
    proposed-pr-body.md seal-v1.json preseal-index-v1.json state-v1.tsv toolchain-v1.txt \
    cms-signer-v1.json
}

verify_staged_checksum() {
  local destination="$(artifact_root)"
  validate_checksum_manifest "$destination" "$destination/evidence-v1.sha256"
}

seal_evidence() {
  local destination="$(artifact_root)"
  sign_cms_payload "$destination/evidence-v1.sha256" "$destination/evidence-v1.cms"
  verify_cms_bundle "$destination" evidence-v1.sha256 evidence-v1.cms
  [[ "$cms_signer_identity" == "$gate15_signer_identity" \
    && "$cms_signer_fingerprint" == "$gate15_signer_fingerprint" \
    && "$cms_signer_certificate_fingerprint" == "$gate15_signer_certificate_fingerprint" \
    && "$cms_signer_team" == "$gate15_signer_team" ]] \
    || finalize_die 'Gate 16 final CMS signer does not match the extracted Gate15 signer.' 73
  [[ "${HOSTWRIGHT_PHASE09_TEST_SEAL_INTERRUPT:-0}" != 1 ]] \
    || finalize_die 'Gate 16 deterministic seal interruption requested; the root is frozen.' 73
  [[ "${HOSTWRIGHT_PHASE09_TEST_PARTIAL_PUBLICATION:-0}" != 1 ]] \
    || finalize_die 'Gate 16 deterministic partial-publication crash requested; the root is frozen.' 73
}

publish_final_directory() {
  local expected actual
  expected='cleanup-v1.json closure-plan-v1.json closure-receipts-v1.json cms-signer-v1.json dependency-evidence-v1.json evidence-v1.cms evidence-v1.sha256 governance-event-v1.json hard-stop-v1.json manifest-v1.json ownership-v1.tsv preseal-index-v1.json prepared-binding-v1.json prepared-cms-signer-v1.json prepared-evidence-v1.cms prepared-evidence-v1.sha256 prepared-seal-index-v1.json proposed-evidence-comment.md proposed-pr-body.md seal-v1.json state-v1.tsv toolchain-v1.txt'
  [[ -d "$staged_root" && ! -L "$staged_root" ]] \
    || finalize_die 'Gate 16 complete final-v1 staging directory is missing.' 73
  /usr/bin/jq -e --arg source "$source_commit" \
    '(.status == "passed" or .status == "test-passed") and .terminal == true and .sealed == true
      and .sourceCommit == $source' \
    "$staged_root/manifest-v1.json" >/dev/null \
    || finalize_die 'Gate 16 staged authoritative manifest is not terminal and source-bound.' 73
  actual="$(/usr/bin/find "$staged_root" -mindepth 1 -maxdepth 1 -exec /usr/bin/basename {} \; | LC_ALL=C /usr/bin/sort)"
  [[ "$actual" == "$(printf '%s\n' $expected | LC_ALL=C /usr/bin/sort)" ]] \
    || finalize_die 'Gate 16 final-v1 staged directory is incomplete or contains unverified artifacts.' 73
  validate_private_directory "$staged_root"
  [[ ! -e "$root/final-v1" && ! -L "$root/final-v1" ]] \
    || finalize_die 'Gate 16 final-v1 destination already exists; retry is forbidden.' 75
  /bin/mv "$staged_root" "$root/final-v1" \
    || finalize_die 'Gate 16 final-v1 atomic directory publication failed.' 75
  staged_root=''
  finalization_completed=1
}

prepare() {
  validate_root_path
  require_clean_source
  collect_digests
  load_signer_pins
  run_local_governance_checks \
    || die 'Gate 16 local roadmap governance checks failed; no evidence root was created.' 73
  validate_gate15_dependency
  require_empty_root
  prepare_started=1
  trap on_prepare_exit EXIT
  write_skeleton
  trap - EXIT
  printf '%s\n' 'Gate 16 private closure root prepared; no public action was performed.'
}

finalize() {
  local input="${1:-${HOSTWRIGHT_PHASE09_GATE16_RECEIPTS:-}}" prepared_gate15_root_basename
  validate_root_path
  [[ ! -e "$root/finalization-frozen-v1" && ! -e "$root/finalization-committed-v1" \
    && ! -e "$root/finalization-active-v1" \
    && ! -e "$root/final-v1" ]] \
    || die 'Gate 16 finalization root is frozen or interrupted; preserve it and prepare a new root.' 75
  [[ -f "$root/manifest-v1.json" ]] \
    || die 'Gate 16 finalize requires a prepared private evidence root.' 73
  [[ "$(/usr/bin/jq -r '.status // "invalid"' "$root/manifest-v1.json")" == prepared ]] \
    || die 'Gate 16 evidence is already sealed, failed, or invalid; do not rerun this root.' 73
  finalization_started=1
  trap on_finalize_exit EXIT
  collect_digests
  load_signer_pins
  [[ -n "$input" ]] || die 'usage: finalize 16 <fixed-schema receipts JSON>.' 64
  validate_private_file "$input"
  mkdir "$root/finalization-active-v1" || finalize_die 'Gate 16 finalization active marker could not be created.' 75
  chmod 700 "$root/finalization-active-v1"
  printf '%s\n' $'source_commit\tstarted_at\tpid' > "$root/finalization-active-v1/info-v1.tsv"
  printf '%s\t%s\t%s\n' "$source_commit" "$(timestamp)" "$$" >> "$root/finalization-active-v1/info-v1.tsv"
  chmod 600 "$root/finalization-active-v1/info-v1.tsv"
  if testing && [[ "${HOSTWRIGHT_PHASE09_TEST_UNEXPECTED_FINALIZE_EXIT:-0}" == 1 ]]; then
    printf '%s\n' 'Gate 16 deterministic unexpected finalization exit requested.' >&2
    exit 74
  fi
  receipts_file="$input"
  validate_prepared_manifest
  prepared_gate15_root_basename="$(/usr/bin/jq -r '.prerequisite.rootBasename' "$root/manifest-v1.json")"
  [[ "$prepared_gate15_root_basename" =~ $expected_gate15_root_pattern ]] \
    || finalize_die 'Gate 16 prepared Gate15 root binding is invalid.' 73
  : "${HOSTWRIGHT_PHASE09_GATE15_EVIDENCE_ROOT:?HOSTWRIGHT_PHASE09_GATE15_EVIDENCE_ROOT is required for finalization}"
  [[ "$(basename "$HOSTWRIGHT_PHASE09_GATE15_EVIDENCE_ROOT")" == "$prepared_gate15_root_basename" ]] \
    || finalize_die 'Gate 16 finalization Gate15 root differs from the authenticated prepared dependency.' 73
  validate_gate15_dependency
  validate_receipts_file
  stage_final_directory
  cms_signer_identity="$gate15_signer_identity"
  cms_signer_fingerprint="$gate15_signer_fingerprint"
  cms_signer_certificate_fingerprint="$gate15_signer_certificate_fingerprint"
  cms_signer_team="$gate15_signer_team"
  write_signer_metadata "$staged_root/cms-signer-v1.json"
  write_closure_receipt
  write_governance_event
  run_local_final_checks \
    || finalize_die 'Gate 16 local final verification failed; the root is frozen.' 73
  write_cleanup_receipt
  write_hard_stop
  write_staged_manifest
  bind_staged_prepared_records
  tamper_staged_binding_for_test
  write_preseal_index
  write_staged_seal
  validate_final_marker_set
  write_evidence_digest
  seal_evidence
  verify_staged_checksum
  validate_final_bindings
  write_finalization_terminal_lock
  cleanup_finalization_marker_before_publication
  publish_final_directory
  trap - EXIT
  if testing; then
    printf '%s\n' 'Gate 16 test-only finalization completed; status is test-passed and claim is none.'
  else
    printf '%s\n' 'Gate 16 local evidence sealed; terminal hard stop recorded. No public action was performed.'
  fi
}

read_only_state() {
  local operation="$1" state='no-root' final_published=false merge_commit='' \
    frozen=false active=false terminal_lock=false finalization_completed=false
  collect_digests
  if [[ -n "${HOSTWRIGHT_PHASE09_GATE_ROOT:-}" ]]; then
    validate_root_path
    [[ -f "$root/manifest-v1.json" && ! -L "$root/manifest-v1.json" ]] \
      || die 'Gate 16 read-only state requires a prepared root manifest.' 73
    validate_private_file "$root/manifest-v1.json"
    state="$(/usr/bin/jq -r '.status // "invalid"' "$root/manifest-v1.json")" \
      || die 'Gate 16 read-only state could not parse the root manifest.' 73
    [[ -e "$root/finalization-frozen-v1" ]] && frozen=true
    [[ -e "$root/finalization-active-v1" ]] && active=true
    if [[ -e "$root/finalization-committed-v1" ]]; then
      [[ -d "$root/finalization-committed-v1" && ! -L "$root/finalization-committed-v1" ]] \
        || die 'Gate 16 terminal finalization lock is invalid.' 75
      validate_private_file "$root/finalization-committed-v1/info-v1.tsv"
      terminal_lock=true
    fi
    if [[ -f "$root/final-v1/manifest-v1.json" && ! -L "$root/final-v1/manifest-v1.json" ]]; then
      final_published=true
      merge_commit="$(/usr/bin/jq -r '.mergeCommit // empty' "$root/final-v1/manifest-v1.json")" \
        || die 'Gate 16 read-only state could not parse the final manifest.' 73
    fi
    if [[ "$frozen" == true ]]; then
      state='failed'
    elif [[ "$final_published" == true && "$terminal_lock" == true && "$active" == false ]]; then
      state='finalized'
      finalization_completed=true
    elif [[ "$terminal_lock" == true ]]; then
      state='publication-incomplete'
    fi
  fi
  /usr/bin/jq -n -cS \
    --arg operation "$operation" --arg state "$state" --arg source "$source_commit" \
    --arg merge "$merge_commit" --arg sourceDigest "$source_digest_value" \
    --arg configDigest "$config_digest_value" --arg toolchainDigest "$toolchain_digest_value" \
    --argjson finalPublished "$final_published" --argjson frozen "$frozen" --argjson active "$active" \
    --argjson terminalLock "$terminal_lock" --argjson finalizationCompleted "$finalization_completed" \
    '{schema:"hostwright.phase09.gate16.status.v1",gate:16,operation:$operation,mode:"read-only",
      claim:"none",formalPassage:false,publicActionsPerformed:false,readOnly:true,status:$state,
      finalizationRequiresExplicitReceipts:true,finalPublished:$finalPublished,frozen:$frozen,active:$active,
      terminalLock:$terminalLock,finalizationCompleted:$finalizationCompleted,
      sourceCommit:$source,headCommit:$source,prNumber:206,mergeCommit:(if $merge == "" then null else $merge end),
      sourceDigest:$sourceDigest,configDigest:$configDigest,toolchainDigest:$toolchainDigest}'
}

run() {
  read_only_state run
}

status() {
  read_only_state status
}

diagnose() {
  local validate_status=1 self_test_status=1 clean=false
  source_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
  source_is_clean && clean=true || true
  python3 scripts/roadmap-governance.py validate >/dev/null 2>&1 && validate_status=0 || true
  python3 scripts/roadmap-governance.py self-test >/dev/null 2>&1 && self_test_status=0 || true
  collect_digests
  /usr/bin/jq -n -cS \
    --arg schema 'hostwright.phase09.gate16.diagnostic.v1' --arg claim none --arg sourceCommit "$source_commit" \
    --arg branch "$(git -C "$repo_root" branch --show-current 2>/dev/null || true)" --argjson clean "$clean" \
    --arg sourceDigest "$source_digest_value" --arg configDigest "$config_digest_value" --arg toolchainDigest "$toolchain_digest_value" \
    --argjson roadmapValidate "$([[ "$validate_status" == 0 ]] && printf true || printf false)" \
    --argjson roadmapSelfTest "$([[ "$self_test_status" == 0 ]] && printf true || printf false)" \
    '{schema:$schema,gate:16,claim:$claim,formalPassage:false,publicActionsPerformed:false,sourceCommit:$sourceCommit,branch:$branch,cleanSource:$clean,
      sourceDigest:$sourceDigest,configDigest:$configDigest,toolchainDigest:$toolchainDigest,
      localChecks:{roadmapValidate:$roadmapValidate,roadmapSelfTest:$roadmapSelfTest}}'
}

contract() {
  cat <<'EOF'
Phase 09 Gate 16 local closure harness contract v4
This harness is local-only. It validates caller-supplied fixed-schema receipts and performs no public action.
diagnose emits canonical JSON with claim:"none" and never creates formal evidence.
prepare requires current clean committed source, current formal Gate15 evidence, exact transitive manifest/checksum/CMS verification, and a canonical private root.
  Gate15 and every transitive manifest carry matching current source/config/toolchain/dependency digests plus signing identity, fingerprint, certificateFingerprint, and Team ID. Formal dependency receipts require every marker in the exact profile formal=true, formalClaim=true, testMode=false, qualifying=true, status=passed, sealed=true; testOnly and claim, when present, must agree. Missing, contradictory, unknown, legacy, and nested test markers are rejected. Verified CMS certificates are extracted and pinned; identity-list presence is not proof.
prepare cryptographically seals the prepared manifest, closure plan, generated PR body, generated evidence comment, and binding with the pinned signer.
run 16 and status 16 are read-only local state/preflight reports with claim:"none"; the canonical router forwards missing or invalid finalize 16 receipt arguments after its boundary check so Gate 16 can freeze the valid root, while only valid receipts can publish final-v1.
finalize validates one PR #206 receipt, exact head/base/merge bindings, exact merge parents, fixed successful checks, approved review, child closure, structured ownership absence receipts, cleanup, and hard stop before staging.
Receipt timestamps are strict UTC values in one total order, and the receipt PR body/comment must exactly match the generated files. Formal mode accepts only passed/formal, non-test Gate15 and transitive manifests/receipts with verified sealed CMS; a complete private final-v1 directory is CMS-verified before one atomic directory rename, and the root manifest remains prepared until then.
The prepared manifest and closure plan are digest-bound. Final closure/dependency/manifest bindings rebuild prepared-binding-v1.json and its prepared seal. Every final-v1 JSON record directly binds sourceCommit/headCommit, mergeCommit, and prNumber 206; exact binding, checksum/CMS, preseal, and seal-reference checks run against exact staged bytes before publication. The active marker and every owned temporary are cleaned and verified before publication, while a durable terminal lock prevents concurrent reuse. The atomic rename is the only required action after cleanup; a deterministic cleanup failure freezes the root before any passed final-v1 can be visible and cannot be retried. The finalize EXIT trap is installed before receipt argument/path validation.
Production CMS uses the pinned certificate SHA-256, pinned certificate fingerprint, Team ID, and identity from the Gate11/12 signing contract. Test mode is private, deterministic, and always non-formal.
No network, GitHub, runtime, Keychain, or protected-resource action is performed by this script.
EOF
}

main() {
  [[ "$#" -ge 1 ]] || die 'usage: phase09-gate16-qualification.sh <contract|diagnose|prepare|run|status|finalize> ...' 64
  validate_worktree
  case "$1" in
    contract)
      [[ "$#" == 1 ]] || die 'contract accepts no arguments.' 64
      contract
      ;;
    diagnose)
      [[ "$#" == 1 ]] || die 'diagnose accepts no arguments.' 64
      diagnose
      ;;
    prepare)
      [[ "$#" == 2 && "$2" == 16 ]] || die 'Gate 16 harness accepts only prepare 16.' 64
      prepare
      ;;
    run)
      [[ "$#" == 2 && "$2" == 16 ]] || die 'Gate 16 harness accepts only run 16.' 64
      run
      ;;
    status)
      [[ "$#" == 2 && "$2" == 16 ]] || die 'Gate 16 harness accepts only status 16.' 64
      status
      ;;
    finalize)
      [[ "$#" == 2 || "$#" == 3 ]] && [[ "$2" == 16 ]] \
        || die 'usage: finalize 16 <fixed-schema receipts JSON>.' 64
      finalize "${3:-}"
      ;;
    *)
      die 'unknown qualification command.' 64
      ;;
  esac
}

main "$@"
