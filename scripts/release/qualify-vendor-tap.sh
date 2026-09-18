#!/usr/bin/env bash
set -euo pipefail

baseline_version=""
candidate_version=""
baseline_tag=""
candidate_tag=""
qualification_mode=""
baseline_package_version=""
candidate_package_version=""
readonly tap_name="hostwright/tap"
readonly formula_reference="$tap_name/hostwright"
readonly hostwright_repository="https://github.com/hostwright/hostwright.git"
readonly tap_repository_url="https://github.com/hostwright/homebrew-tap.git"
readonly package_identifier="dev.hostwright.cli"
readonly package_prefix="/usr/local"
readonly package_staging_root="/Library/Application Support/Hostwright/InstallerPayload"
readonly installer_log="/var/log/install.log"
readonly package_remove_refusal="Package-managed installations support only --data-policy preserve because Hostwright does not infer or search for per-user state databases."
package_downgrade_refusal=""
readonly -a package_owned_paths=(
  "$package_staging_root"
  "$package_prefix/.hostwright-lifecycle"
  "$package_prefix/.hostwright-install-manifest.json"
  "$package_prefix/bin/hostwright"
  "$package_prefix/bin/hostwright-control"
  "$package_prefix/bin/hostwright-dist"
  "$package_prefix/bin/hostwrightd"
  "$package_prefix/share/hostwright"
  "$package_prefix/share/hostwright/examples"
  "$package_prefix/share/hostwright/examples/hostwright.yaml"
  "$package_prefix/share/doc/hostwright"
  "$package_prefix/share/doc/hostwright/LICENSE"
  "$package_prefix/share/doc/hostwright/README.md"
)

die() {
  printf '%s\n' "$1" >&2
  exit "${2:-64}"
}

require_sha() {
  local name="$1"
  local value="${!name:-}"
  [[ "$value" =~ ^[a-f0-9]{40}$ ]] || die "$name must be one exact lowercase commit SHA."
}

# No version override retains the historical dev.11 -> dev.12 cell.
configure_versions() {
  if [[ ${HOSTWRIGHT_BASELINE_VERSION+x}${HOSTWRIGHT_CANDIDATE_VERSION+x}${HOSTWRIGHT_BASELINE_TAG+x}${HOSTWRIGHT_CANDIDATE_TAG+x} == "" ]]; then
    qualification_mode=historical
    baseline_version="0.0.2-dev.11"
    candidate_version="0.0.2-dev.12"
    baseline_tag="v$baseline_version"
    candidate_tag="v$candidate_version"
  else
    qualification_mode=explicit
    baseline_version="${HOSTWRIGHT_BASELINE_VERSION:-}"
    candidate_version="${HOSTWRIGHT_CANDIDATE_VERSION:-}"
    baseline_tag="${HOSTWRIGHT_BASELINE_TAG:-}"
    candidate_tag="${HOSTWRIGHT_CANDIDATE_TAG:-}"
    [[ -n "$baseline_version" && -n "$candidate_version" && -n "$baseline_tag" && -n "$candidate_tag" ]] \
      || die "Explicit qualification requires both versions and both tags; partial overrides are ambiguous."
  fi
  [[ "$baseline_tag" == "v$baseline_version" && "$candidate_tag" == "v$candidate_version" ]] \
    || die "Qualification tags must exactly match their explicit versions."
  baseline_package_version="$(receipt_version "$baseline_version")"
  candidate_package_version="$(receipt_version "$candidate_version")"
  local baseline_number="${baseline_package_version##*.}" candidate_number="${candidate_package_version##*.}"
  (( candidate_number > baseline_number )) || die "Candidate must be a strictly newer supported dev -> RC -> stable installer version."
  package_downgrade_refusal="Downgrade refused: installed version $candidate_version is newer than candidate $baseline_version. Use a verified Hostwright rollback record instead."
}

receipt_version() {
  local version="$1" number
  case "$version" in
    0.0.2) printf '0.0.2.2000\n' ;;
    0.0.2-dev.*)
      number="${version#0.0.2-dev.}"
      [[ "$number" =~ ^(0|[1-9][0-9]{0,2})$ ]] || die "Unsupported qualification version: $version"
      printf '0.0.2.%s\n' "$number" ;;
    0.0.2-rc.*)
      number="${version#0.0.2-rc.}"
      [[ "$number" =~ ^[1-9][0-9]?$ ]] || die "Unsupported qualification version: $version"
      printf '0.0.2.%s\n' "$((1000 + number))" ;;
    *) die "Unsupported qualification version: $version" ;;
  esac
}

inventory_check() {
  [[ -n "${HOSTWRIGHT_ARTIFACT_INVENTORY:-}" && "${HOSTWRIGHT_ARTIFACT_INVENTORY_SHA256:-}" =~ ^[a-f0-9]{64}$ ]] \
    || die "A complete SHA256-bound artifact receipt inventory is required."
  command -v python3 >/dev/null || die "Python 3 is required to verify artifact receipts." 69
  python3 - "$1" "$HOSTWRIGHT_ARTIFACT_INVENTORY" "$HOSTWRIGHT_ARTIFACT_INVENTORY_SHA256" \
    "$baseline_version" "$candidate_version" "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT" "$HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT" \
    "$HOSTWRIGHT_BASELINE_TAP_COMMIT" "$HOSTWRIGHT_CANDIDATE_TAP_COMMIT" "${@:2}" <<'PYTHON'
import hashlib,json,os,re,stat,sys
from pathlib import Path
mode,receipt_path,receipt_sha,bv,cv,bc,cc,bt,ct,*extra=sys.argv[1:]
def require(value,message):
    if not value: raise ValueError(message)
def pairs(items):
    result={}
    for key,value in items:
        require(key not in result,'Duplicate receipt JSON key');result[key]=value
    return result
def decode(raw):
    return json.loads(raw,object_pairs_hook=pairs,parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Nonfinite receipt JSON')))
def file_hash(path,private=False):
    path=Path(path)
    require(path.is_absolute() and path.resolve()==path and not any(ord(x)<32 or ord(x)==127 for x in str(path)),'Noncanonical receipt/artifact path')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        before=os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink==1,'Artifact is not one regular file')
        if private:
            require(before.st_uid==os.getuid() and stat.S_IMODE(before.st_mode)==0o600 and before.st_size<=8388608,'Receipt inventory must be private bounded 0600')
        h=hashlib.sha256(); chunks=[]
        while True:
            chunk=os.read(fd,1048576)
            if not chunk:break
            h.update(chunk)
            if private: chunks.append(chunk)
        identity=lambda x:(x.st_dev,x.st_ino,x.st_size,x.st_mtime_ns,x.st_ctime_ns)
        require(identity(before)==identity(os.fstat(fd))==identity(path.lstat()),'Artifact changed while hashing')
        return (h.hexdigest(),b''.join(chunks)) if private else h.hexdigest()
    finally:os.close(fd)
def version(value):
    if value=='0.0.2':return '0.0.2.2000'
    match=re.fullmatch(r'0\.0\.2-(dev|rc)\.(0|[1-9][0-9]*)',value)
    require(match is not None,'Unsupported receipt version')
    channel,number=match.group(1),int(match.group(2))
    require((channel=='dev' and 0<=number<1000) or (channel=='rc' and 1<=number<=99),'Unsupported receipt channel range')
    return '0.0.2.'+str(number+(1000 if channel=='rc' else 0))
def hex_sha(value):return isinstance(value,str) and re.fullmatch('[a-f0-9]{64}',value)
def payload(value):
    require(isinstance(value,list) and value,'Missing full payload receipt inventory')
    result={}
    for item in value:
        path=item['path'];digest=item['sha256']
        require(isinstance(path,str) and path and path!='.' and not Path(path).is_absolute() and path==str(Path(path)) and '..' not in Path(path).parts and not any(ord(x)<32 for x in path),'Unsafe payload path')
        require(path not in result and hex_sha(digest),'Duplicate/invalid payload receipt')
        result[path]=digest
    return result
try:
    receipt_path=Path(receipt_path)
    for parent in receipt_path.parents:
        info=parent.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid in (0,os.getuid()) and not info.st_mode&0o022,'Unsafe receipt ancestry')
    actual_sha,raw=file_hash(receipt_path,True)
    require(actual_sha==receipt_sha,'Artifact receipt inventory SHA256 mismatch')
    receipt=decode(raw)
    require(receipt.get('schemaVersion')==1 and receipt.get('kind')=='hostwright.vendor-tap-inputs.v1','Missing supported artifact receipt inventory')
    for role,v,c,t in [('baseline',bv,bc,bt),('candidate',cv,cc,ct)]:
        item=receipt[role]
        require((item['version'],item['tag'],item['sourceCommit'],item['tapCommit'],item['packageReceiptVersion'])==(v,'v'+v,c,t,version(v)),'Artifact receipt version/tag/source/tap mismatch')
        for kind,suffix in [('archive','zip'),('package','pkg')]:
            require(item[kind]['fileName']==f'hostwright-{v}-macos-arm64-{c[:12]}.{suffix}' and hex_sha(item[kind]['sha256']),'Missing exact archive/package artifact binding')
        require(hex_sha(item['releaseManifestSHA256']) and hex_sha(item['formulaSHA256']),'Missing exact manifest/formula binding')
        files=payload(item['payloadFiles'])
        names=['hostwright','hostwright-control','hostwright-dist','hostwrightd']
        if v not in ('0.0.2-dev.11','0.0.2-dev.12'):
            names+=['hostwright-containerization-helper','hostwright-network-helper','hostwright-network-provider-worker','hostwright-storage-helper']
        require({'bin/'+name for name in names}<=files.keys(),'Missing required executable payload inventory')
    if mode in ('formula','archive','package','installed','recovery'):
        tested_version=extra[0]
        require(tested_version in (bv,cv),'Unexpected tested artifact version')
        item=receipt['baseline' if tested_version==bv else 'candidate']
        if mode=='formula':require(file_hash(Path(extra[1]).resolve())==item['formulaSHA256'],'Formula exact-byte binding mismatch')
        if mode=='archive':require(file_hash(Path(extra[1]).resolve())==item['archive']['sha256'],'Homebrew archive exact-byte binding mismatch')
        if mode=='package':
            manifest_path=Path(extra[1]).resolve()
            require(file_hash(manifest_path)==item['releaseManifestSHA256'],'Release manifest exact-byte binding mismatch')
            manifest=decode(manifest_path.read_bytes())
            require((manifest['releaseTag'],manifest['packageVersion'],manifest['sourceCommit'])==(item['tag'],tested_version,item['sourceCommit']) and manifest['sourceDirty'] is False,'Release manifest source/version mismatch')
            require(manifest['archive']==item['archive'] and manifest['package']==item['package'] and payload(manifest['payloadFiles'])==payload(item['payloadFiles']),'Release manifest omits or changes full artifact receipt inventory')
            require(file_hash(Path(extra[2]).resolve())==item['package']['sha256'],'Installer package exact-byte binding mismatch')
        if mode=='recovery':require(file_hash(Path(extra[1]).resolve())==payload(item['payloadFiles'])['bin/hostwright-dist'],'Recovery executable exact-byte binding mismatch')
        if mode=='installed':
            prefix=Path(extra[1]).resolve()
            for relative,expected in payload(item['payloadFiles']).items():
                path=prefix/relative
                require(path.resolve()==path and prefix in path.parents,'Installed payload escapes exact prefix')
                require(file_hash(path)==expected,'Installed payload exact-byte binding mismatch: '+relative)
    elif mode=='summary':
        print(json.dumps({'schemaVersion':1,'kind':'hostwright.vendor-tap-tested-bindings.v1','inventorySHA256':receipt_sha,'baseline':receipt['baseline'],'candidate':receipt['candidate']},sort_keys=True))
    else:require(mode=='contract','Unsupported artifact receipt operation')
except (ValueError,KeyError,TypeError,OSError,json.JSONDecodeError) as error:
    print('Artifact receipt rejected: '+str(error),file=sys.stderr);sys.exit(64)
PYTHON
}

validate_contract() {
  local name
  for name in HOSTWRIGHT_APPLICATION_SUPPORT_DIR HOSTWRIGHT_CACHE_DIR HOSTWRIGHT_LOG_DIR HOSTWRIGHT_STATE_DB HOSTWRIGHT_BASELINE_PACKAGE_VERSION HOSTWRIGHT_CANDIDATE_PACKAGE_VERSION; do
    [[ -z "${!name+x}" ]] || die "Ambiguous qualification environment override: $name"
  done
  while IFS= read -r name; do
    case "$name" in
      HOSTWRIGHT_BASELINE_RELEASE_COMMIT|HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT|HOSTWRIGHT_BASELINE_TAP_COMMIT|HOSTWRIGHT_CANDIDATE_TAP_COMMIT|HOSTWRIGHT_BASELINE_VERSION|HOSTWRIGHT_CANDIDATE_VERSION|HOSTWRIGHT_BASELINE_TAG|HOSTWRIGHT_CANDIDATE_TAG|HOSTWRIGHT_ARTIFACT_INVENTORY|HOSTWRIGHT_ARTIFACT_INVENTORY_SHA256|HOSTWRIGHT_QUALIFICATION_ROOT) ;;
      HOSTWRIGHT_*) die "Ambiguous qualification environment override: $name" ;;
    esac
  done < <(compgen -e)
  require_sha HOSTWRIGHT_BASELINE_RELEASE_COMMIT
  require_sha HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT
  require_sha HOSTWRIGHT_BASELINE_TAP_COMMIT
  require_sha HOSTWRIGHT_CANDIDATE_TAP_COMMIT
  [[ "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT" != "$HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT" ]] \
    || die "The two release commits must be distinct."
  [[ "$HOSTWRIGHT_BASELINE_TAP_COMMIT" != "$HOSTWRIGHT_CANDIDATE_TAP_COMMIT" ]] \
    || die "The two tap commits must be distinct."
  if [[ "$qualification_mode" == explicit || ${HOSTWRIGHT_ARTIFACT_INVENTORY+x}${HOSTWRIGHT_ARTIFACT_INVENTORY_SHA256+x} != "" ]]; then
    inventory_check contract
  fi
}

validate_host() {
  [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] \
    || die "Vendor-tap qualification requires macOS on Apple silicon." 69
  local macos_major
  macos_major="$(sw_vers -productVersion | cut -d. -f1)"
  [[ "$macos_major" =~ ^[0-9]+$ && "$macos_major" -ge 26 ]] \
    || die "Vendor-tap qualification requires macOS 26 or newer." 69
  command -v python3 >/dev/null || die "Python 3 is required for full qualification artifact bindings." 69
  inventory_check contract
  command -v brew >/dev/null || die "Homebrew is required." 69
  command -v gh >/dev/null || die "GitHub CLI is required for attestation verification." 69
  [[ "${RELEASE_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] \
    || die "RELEASE_TEAM_ID must be the independently configured Developer Team ID." 69
  [[ -x /usr/bin/sudo && -x /usr/sbin/installer && -x /usr/sbin/pkgutil \
      && -x /usr/sbin/spctl && -x /usr/bin/shasum ]] \
    || die "Apple package qualification tools are unavailable." 69
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
    printf 'baselineVersion=%s\n' "$baseline_version"
    printf 'candidateVersion=%s\n' "$candidate_version"
    printf 'baselineTag=%s\n' "$baseline_tag"
    printf 'candidateTag=%s\n' "$candidate_tag"
    printf 'artifactInventorySHA256=%s\n' "$HOSTWRIGHT_ARTIFACT_INVENTORY_SHA256"
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
  [[ "$(wc -l < "$state_file" | tr -d ' ')" == 13 ]] || die "Qualification state is malformed or lacks bound version/artifact inventory." 70
  [[ "$(state_value baselineVersion)" == "$baseline_version" \
      && "$(state_value candidateVersion)" == "$candidate_version" \
      && "$(state_value baselineTag)" == "$baseline_tag" \
      && "$(state_value candidateTag)" == "$candidate_tag" \
      && "$(state_value artifactInventorySHA256)" == "$HOSTWRIGHT_ARTIFACT_INVENTORY_SHA256" ]] \
    || die "Qualification version/tag/artifact inventory differs from durable state." 70
  [[ "$(state_value baselineReleaseCommit)" == "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT" \
      && "$(state_value candidateReleaseCommit)" == "$HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT" \
      && "$(state_value baselineTapCommit)" == "$HOSTWRIGHT_BASELINE_TAP_COMMIT" \
      && "$(state_value candidateTapCommit)" == "$HOSTWRIGHT_CANDIDATE_TAP_COMMIT" ]] \
    || die "Qualification inputs do not match the durable state." 70
}

verify_release_pair() {
  verify_release_ref "$baseline_tag" "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT"
  verify_release_ref "$candidate_tag" "$HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT"
  local comparison
  comparison="$(gh api "repos/hostwright/hostwright/compare/${HOSTWRIGHT_BASELINE_RELEASE_COMMIT}...${HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT}" --jq .status)"
  [[ "$comparison" == ahead ]] || die "Baseline source must be an exact ancestor of candidate source." 70
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
  local expected_state="$1"
  local brew_binary taps tap_repository remote
  brew_binary="$(command -v brew)"
  taps="$("$brew_binary" tap)" || die "Unable to inventory Homebrew taps." 70
  case "$expected_state" in
    absent)
      if grep -Fxq "$tap_name" <<< "$taps"; then
        die "The clean-host cell already contains the Hostwright tap." 70
      fi
      "$brew_binary" tap "$tap_name" "$tap_repository_url" >&2
      ;;
    present)
      grep -Fxq "$tap_name" <<< "$taps" || die "The qualification tap is missing." 70
      ;;
    *) die "Invalid qualification tap expectation." 70 ;;
  esac
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
  inventory_check formula "$version" "$formula"
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
    /usr/bin/codesign --verify --verbose=2 -R=notarized --check-notarization \
      "$prefix/bin/$executable"
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
  inventory_check archive "$version" "$cache"
  inventory_check installed "$version" "$prefix"
  record "$label-installed version=$version archiveSHA256=$(/usr/bin/shasum -a 256 "$cache" | awk '{ print $1 }')"
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

validate_prepare_preflight() {
  local -a root_entries
  local home application_support launch_agent launchd_status taps brew_prefix config_dir log_path error_log_path
  shopt -s nullglob dotglob
  root_entries=("$HOSTWRIGHT_QUALIFICATION_ROOT"/*)
  shopt -u nullglob dotglob
  [[ "${#root_entries[@]}" -eq 0 ]] \
    || die "The qualification root must be empty before prepare." 70
  home="${HOME:-}"
  [[ "$home" == /* && "$home" != *$'\n'* ]] \
    || die "HOME must identify one safe absolute directory." 70
  application_support="$home/Library/Application Support/Hostwright"
  launch_agent="$home/Library/LaunchAgents/homebrew.mxcl.hostwright.plist"
  [[ ! -e "$application_support" && ! -L "$application_support" ]] \
    || die "The clean-host cell contains pre-existing Hostwright Application Support state." 70
  [[ ! -e "$launch_agent" && ! -L "$launch_agent" ]] \
    || die "The clean-host cell contains a pre-existing Hostwright LaunchAgent." 70
  launchd_status=0
  /bin/launchctl print "gui/$(id -u)/homebrew.mxcl.hostwright" >/dev/null 2>&1 \
    || launchd_status=$?
  case "$launchd_status" in
    0) die "The clean-host cell contains a loaded Hostwright service." 70 ;;
    113) ;;
    *) die "Unable to prove the Hostwright service is absent." 70 ;;
  esac
  if brew list --formula hostwright >/dev/null 2>&1 || command -v hostwright >/dev/null 2>&1; then
    die "The clean-host cell already contains Hostwright." 70
  fi
  taps="$(brew tap)" || die "Unable to inventory Homebrew taps." 70
  if grep -Fxq "$tap_name" <<< "$taps"; then
    die "The clean-host cell already contains the Hostwright tap." 70
  fi
  brew_prefix="$(brew --prefix)"
  config_dir="$brew_prefix/etc/hostwright"
  log_path="$brew_prefix/var/log/hostwrightd.log"
  error_log_path="$brew_prefix/var/log/hostwrightd.error.log"
  [[ ! -e "$config_dir" && ! -e "$log_path" && ! -e "$error_log_path" ]] \
    || die "The clean-host cell contains pre-existing Hostwright config or logs." 70
  require_package_absent "before package qualification"
}

require_package_absent() {
  local label="$1"
  local receipt_status=0 path
  /usr/sbin/pkgutil --pkg-info "$package_identifier" >/dev/null 2>&1 || receipt_status=$?
  [[ "$receipt_status" -eq 1 ]] \
    || die "The exact Hostwright package receipt is not absent $label." 70
  for path in "${package_owned_paths[@]}"; do
    [[ ! -e "$path" && ! -L "$path" ]] \
      || die "A Hostwright package-owned path is not absent $label: $path" 70
  done
}

downloaded_package=""
downloaded_team_id=""

download_qualified_package() {
  local tag="$1"
  local version="$2"
  local commit="$3"
  local directory="$4"
  local expected_name manifest actual_sha expected_sha signature
  expected_name="hostwright-$version-macos-arm64-${commit:0:12}.pkg"
  mkdir -m 700 "$directory"
  gh release download "$tag" \
    --repo hostwright/hostwright \
    --pattern release-manifest.json \
    --pattern "$expected_name" \
    --dir "$directory"
  manifest="$directory/release-manifest.json"
  downloaded_package="$directory/$expected_name"
  [[ -f "$manifest" && ! -L "$manifest" \
      && -f "$downloaded_package" && ! -L "$downloaded_package" ]] \
    || die "$tag did not provide one safe manifest and package." 70
  [[ "$(plutil -extract releaseTag raw "$manifest")" == "$tag" \
      && "$(plutil -extract packageVersion raw "$manifest")" == "$version" \
      && "$(plutil -extract sourceCommit raw "$manifest")" == "$commit" \
      && "$(plutil -extract sourceDirty raw "$manifest")" == false \
      && "$(plutil -extract package.fileName raw "$manifest")" == "$expected_name" ]] \
    || die "$tag manifest is not bound to the expected package and commit." 70
  downloaded_team_id="$(plutil -extract installerSigner.teamIdentifier raw "$manifest")"
  [[ "$downloaded_team_id" == "$RELEASE_TEAM_ID" \
      && "$(plutil -extract applicationSigner.teamIdentifier raw "$manifest")" == "$downloaded_team_id" ]] \
    || die "$tag signer Team IDs do not match the protected release Team ID." 70
  expected_sha="$(plutil -extract package.sha256 raw "$manifest")"
  actual_sha="$(/usr/bin/shasum -a 256 "$downloaded_package" | awk '{ print $1 }')"
  [[ "$expected_sha" == "$actual_sha" ]] || die "$tag package digest differs from its manifest." 70
  inventory_check package "$version" "$manifest" "$downloaded_package"
  gh attestation verify "$manifest" --repo hostwright/hostwright >/dev/null
  record "package-download version=$version source=$commit manifestSHA256=$(/usr/bin/shasum -a 256 "$manifest" | awk '{ print $1 }') packageSHA256=$actual_sha"
  gh attestation verify "$downloaded_package" --repo hostwright/hostwright >/dev/null
  signature="$(/usr/sbin/pkgutil --check-signature "$downloaded_package" 2>&1)" \
    || die "$tag package signature verification failed." 70
  [[ "$signature" == *"$downloaded_team_id"* ]] \
    || die "$tag package signature uses an unexpected Team ID." 70
  /usr/sbin/spctl --assess --type install --verbose=4 "$downloaded_package"
}

package_installation_id=""

verify_package_state() {
  local label="$1"
  local version="$2"
  local commit="$3"
  local generation="$4"
  local package_version="$5"
  local recent_receipt="$6"
  local receipt_version="$7"
  local status_file receipt_file executable observed_id
  status_file="$HOSTWRIGHT_QUALIFICATION_ROOT/$label-package-status.json"
  receipt_file="$HOSTWRIGHT_QUALIFICATION_ROOT/$label-package-receipt.plist"
  executable="$package_prefix/bin/hostwright-dist"
  [[ -x "$executable" && ! -L "$executable" ]] \
    || die "$label did not install a safe hostwright-dist executable." 70
  sudo -n "$executable" status --prefix "$package_prefix" --output json > "$status_file"
  /usr/sbin/pkgutil --pkg-info-plist "$package_identifier" > "$receipt_file"
  [[ "$(plutil -extract readiness raw "$status_file")" == ready \
      && "$(plutil -extract status.generation raw "$status_file")" == "$generation" \
      && "$(plutil -extract status.installedManifest.packageVersion raw "$status_file")" == "$version" \
      && "$(plutil -extract status.installedManifest.sourceCommit raw "$status_file")" == "$commit" \
      && "$(plutil -extract status.packageIdentifier raw "$status_file")" == "$package_identifier" \
      && "$(plutil -extract status.packageVersion raw "$status_file")" == "$package_version" \
      && "$(plutil -extract status.mostRecentPackageReceiptVersion raw "$status_file")" == "$recent_receipt" \
      && "$(plutil -extract status.pendingReceiptCleanup raw "$status_file")" == false \
      && "$(plutil -extract pkg-version raw "$receipt_file")" == "$receipt_version" ]] \
    || die "$label did not produce the expected durable package generation." 70
  observed_id="$(plutil -extract status.installationID raw "$status_file")"
  if [[ -z "$package_installation_id" ]]; then
    package_installation_id="$observed_id"
  fi
  [[ "$observed_id" == "$package_installation_id" ]] \
    || die "$label changed the package installation identity." 70
  for executable in hostwright hostwright-control hostwright-dist hostwrightd; do
    [[ "$("$package_prefix/bin/$executable" --version)" == "$version" ]] \
      || die "$label installed an unexpected $executable version." 70
  done
  inventory_check installed "$version" "$package_prefix"
  record "$label-passed generation=$generation version=$version"
}

package_snapshot_digest() {
  local work="$1"
  local distribution="$package_prefix/bin/hostwright-dist"
  local -a staged_paths=(
    "$package_staging_root/manifest.json"
    "$package_staging_root/bin/hostwright"
    "$package_staging_root/bin/hostwright-control"
    "$package_staging_root/bin/hostwright-dist"
    "$package_staging_root/bin/hostwrightd"
    "$package_staging_root/share/hostwright/examples/hostwright.yaml"
    "$package_staging_root/share/doc/hostwright/LICENSE"
    "$package_staging_root/share/doc/hostwright/README.md"
  )
  sudo -n "$distribution" status --prefix "$package_prefix" --output json > "$work/snapshot-status.json"
  /usr/sbin/pkgutil --pkg-info-plist "$package_identifier" > "$work/snapshot-receipt.plist"
  /usr/bin/shasum -a 256 \
    "$package_prefix/bin/hostwright" \
    "$package_prefix/bin/hostwright-control" \
    "$package_prefix/bin/hostwright-dist" \
    "$package_prefix/bin/hostwrightd" > "$work/snapshot-binaries.sha256"
  sudo -n /usr/bin/shasum -a 256 "${staged_paths[@]}" > "$work/snapshot-staging.sha256"
  /usr/bin/shasum -a 256 \
    "$work/snapshot-status.json" \
    "$work/snapshot-receipt.plist" \
    "$work/snapshot-binaries.sha256" \
    "$work/snapshot-staging.sha256" \
    | /usr/bin/shasum -a 256 | awk '{ print $1 }'
}

expect_package_refusal() {
  local label="$1"
  shift
  local output status=0
  output="$("$@" 2>&1)" || status=$?
  [[ "$status" -eq 64 && "$output" == *"$package_remove_refusal"* ]] \
    || die "$label did not return the exact package remove-data refusal." 70
  record "$label-passed"
}

installer_log_checkpoint() {
  local metadata owner links device inode size
  [[ -f "$installer_log" && ! -L "$installer_log" ]] \
    || die "The Apple Installer log is not one regular file." 70
  metadata="$(sudo -n /usr/bin/stat -f '%u:%l:%d:%i:%z' "$installer_log")" \
    || die "Unable to inspect the Apple Installer log." 70
  IFS=: read -r owner links device inode size <<< "$metadata"
  [[ "$owner" == 0 && "$links" == 1 \
      && "$device" =~ ^[0-9]+$ && "$inode" =~ ^[0-9]+$ && "$size" =~ ^[0-9]+$ ]] \
    || die "The Apple Installer log has unsafe identity metadata." 70
  printf '%s:%s:%s\n' "$device" "$inode" "$size"
}

installer_log_since() {
  local checkpoint="$1" current device inode offset current_device current_inode current_size
  IFS=: read -r device inode offset <<< "$checkpoint"
  [[ "$device" =~ ^[0-9]+$ && "$inode" =~ ^[0-9]+$ && "$offset" =~ ^[0-9]+$ ]] \
    || die "The Apple Installer log checkpoint is invalid." 70
  current="$(installer_log_checkpoint)"
  IFS=: read -r current_device current_inode current_size <<< "$current"
  [[ "$current_device" == "$device" && "$current_inode" == "$inode" ]] \
    || die "The Apple Installer log changed identity during qualification." 70
  (( current_size >= offset )) \
    || die "The Apple Installer log was truncated during qualification." 70
  sudo -n /usr/bin/tail -c "+$((offset + 1))" "$installer_log"
}

qualify_package_lifecycle() {
  local work baseline_package candidate_package baseline_team candidate_team
  local distribution before after downgrade_output downgrade_log downgrade_log_checkpoint
  local downgrade_status=0 install_label=install-baseline repair_label=repair-baseline upgrade_label=upgrade-candidate
  local rollback_label=rollback-baseline repaired_label=repair-after-rollback-baseline upgraded_label=upgrade-again-candidate
  if [[ "$qualification_mode" == historical ]]; then
    install_label=install-dev11; repair_label=repair-dev11; upgrade_label=upgrade-dev12
    rollback_label=rollback-dev11; repaired_label=repair-after-rollback-dev11; upgraded_label=upgrade-again-dev12
  fi
  require_package_absent "before package qualification"
  umask 077
  work="$(mktemp -d "$HOSTWRIGHT_QUALIFICATION_ROOT/package-lifecycle.XXXXXX")"
  [[ -d "$work" && ! -L "$work" && "$(stat -f '%u:%Lp' "$work")" == "$(id -u):700" ]] \
    || die "Package qualification workspace is unsafe." 70

  download_qualified_package "$baseline_tag" "$baseline_version" \
    "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT" "$work/baseline"
  baseline_package="$downloaded_package"
  baseline_team="$downloaded_team_id"
  download_qualified_package "$candidate_tag" "$candidate_version" \
    "$HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT" "$work/candidate"
  candidate_package="$downloaded_package"
  candidate_team="$downloaded_team_id"
  [[ "$baseline_team" == "$candidate_team" ]] \
    || die "The two qualification packages use different Developer Team IDs." 70

  sudo -n /usr/sbin/installer -pkg "$baseline_package" -target /
  verify_package_state "$install_label" "$baseline_version" "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT" 1 "$baseline_package_version" "$baseline_package_version" "$baseline_package_version"
  sudo -n /usr/sbin/installer -pkg "$baseline_package" -target /
  verify_package_state "$repair_label" "$baseline_version" "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT" 2 "$baseline_package_version" "$baseline_package_version" "$baseline_package_version"
  sudo -n /usr/sbin/installer -pkg "$candidate_package" -target /
  verify_package_state "$upgrade_label" "$candidate_version" "$HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT" 3 "$candidate_package_version" "$candidate_package_version" "$candidate_package_version"

  distribution="$package_prefix/bin/hostwright-dist"
  sudo -n "$distribution" rollback --prefix "$package_prefix" --output json \
    > "$HOSTWRIGHT_QUALIFICATION_ROOT/rollback-baseline-package-result.json"
  verify_package_state "$rollback_label" "$baseline_version" "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT" 4 "$baseline_package_version" "$candidate_package_version" "$candidate_package_version"
  sudo -n /usr/sbin/installer -pkg "$baseline_package" -target /
  verify_package_state "$repaired_label" "$baseline_version" "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT" 5 "$baseline_package_version" "$baseline_package_version" "$baseline_package_version"
  sudo -n /usr/sbin/installer -pkg "$candidate_package" -target /
  verify_package_state "$upgraded_label" "$candidate_version" "$HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT" 6 "$candidate_package_version" "$candidate_package_version" "$candidate_package_version"

  before="$(package_snapshot_digest "$work")"
  downgrade_log_checkpoint="$(installer_log_checkpoint)"
  downgrade_output="$(sudo -n /usr/sbin/installer -pkg "$baseline_package" -target / 2>&1)" \
    || downgrade_status=$?
  [[ "$downgrade_status" -eq 1 ]] || die "The baseline package downgrade was not refused." 70
  downgrade_log="$(installer_log_since "$downgrade_log_checkpoint")"
  [[ "$downgrade_output$downgrade_log" == *"$package_downgrade_refusal"* \
      && "$downgrade_log" == *"${baseline_package##*/}"* ]] \
    || die "The baseline package failure did not prove Hostwright's semantic downgrade refusal." 70
  after="$(package_snapshot_digest "$work")"
  [[ "$before" == "$after" ]] || die "The rejected package downgrade changed installed state." 70
  record "package-downgrade-refusal-passed"

  expect_package_refusal package-remove-plan-refusal \
    sudo -n "$distribution" uninstall-plan --prefix "$package_prefix" --data-policy remove --output json
  after="$(package_snapshot_digest "$work")"
  [[ "$before" == "$after" ]] || die "Rejected package remove planning changed installed state." 70
  expect_package_refusal package-remove-uninstall-refusal \
    sudo -n "$distribution" package-uninstall --prefix "$package_prefix" --data-policy remove --output json
  after="$(package_snapshot_digest "$work")"
  [[ "$before" == "$after" ]] || die "Rejected package remove uninstall changed installed state." 70

  sudo -n "$distribution" package-uninstall --prefix "$package_prefix" \
    --data-policy preserve --output json \
    > "$HOSTWRIGHT_QUALIFICATION_ROOT/package-preserve-uninstall-result.json"
  [[ "$(plutil -extract kind raw "$HOSTWRIGHT_QUALIFICATION_ROOT/package-preserve-uninstall-result.json")" \
      == distributionPackageUninstall \
      && "$(plutil -extract lifecycle.dataPolicy raw "$HOSTWRIGHT_QUALIFICATION_ROOT/package-preserve-uninstall-result.json")" \
      == preserve ]] \
    || die "Package preserve uninstall returned an unexpected result." 70
  require_package_absent "after package preserve uninstall"

  /usr/bin/find "$work" -depth -delete
  [[ ! -e "$work" ]] || die "Package qualification downloads were not cleaned up." 70
  inventory_check summary > "$HOSTWRIGHT_QUALIFICATION_ROOT/tested-artifact-bindings.json"
  printf '{"schemaVersion":1,"kind":"phase02PackageLifecycle","status":"passed","baselineVersion":"%s","candidateVersion":"%s","baselineCommit":"%s","candidateCommit":"%s","teamIdentifier":"%s","transitions":6,"failures":0,"cleanup":"succeeded"}\n' \
    "$baseline_version" "$candidate_version" "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT" "$HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT" "$candidate_team" \
    > "$HOSTWRIGHT_QUALIFICATION_ROOT/package-lifecycle-summary.json"
  record "signed-package-lifecycle-and-exact-cleanup-passed"
}

cleanup_qualified_package() {
  local receipt_status=0 path found=false distribution manifest status_file package_version
  local expected_commit expected_version expected_digest actual_digest signature team_id
  /usr/sbin/pkgutil --pkg-info "$package_identifier" >/dev/null 2>&1 || receipt_status=$?
  [[ "$receipt_status" -eq 0 || "$receipt_status" -eq 1 ]] \
    || die "Unable to classify the Hostwright package receipt during cleanup." 70
  [[ "$receipt_status" -eq 0 ]] && found=true
  for path in "${package_owned_paths[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then found=true; fi
  done
  [[ "$found" == true ]] || return 0

  if [[ -x "$package_prefix/bin/hostwright-dist" && ! -L "$package_prefix/bin/hostwright-dist" ]]; then
    distribution="$package_prefix/bin/hostwright-dist"
    manifest="$package_prefix/.hostwright-install-manifest.json"
  elif [[ -x "$package_staging_root/bin/hostwright-dist" && ! -L "$package_staging_root/bin/hostwright-dist" ]]; then
    distribution="$package_staging_root/bin/hostwright-dist"
    manifest="$package_staging_root/manifest.json"
  else
    die "Package cleanup cannot prove an exact Hostwright recovery executable." 70
  fi
  [[ -f "$distribution" && ! -L "$distribution" \
      && "$(stat -f '%u:%l' "$distribution")" == "0:1" \
      && -f "$manifest" && ! -L "$manifest" \
      && "$(stat -f '%u:%l' "$manifest")" == "0:1" ]] \
    || die "Package cleanup executable or manifest lacks exact root-owned regular-file identity." 70
  expected_commit="$(plutil -extract sourceCommit raw "$manifest")"
  expected_version="$(plutil -extract packageVersion raw "$manifest")"
  [[ "$expected_commit:$expected_version" == "$HOSTWRIGHT_BASELINE_RELEASE_COMMIT:$baseline_version" \
      || "$expected_commit:$expected_version" == "$HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT:$candidate_version" ]] \
    || die "Package cleanup manifest is not bound to this qualification pair." 70
  [[ "$(plutil -extract files.2.path raw "$manifest")" == bin/hostwright-dist ]] \
    || die "Package cleanup manifest does not identify the recovery executable." 70
  expected_digest="$(plutil -extract files.2.sha256 raw "$manifest")"
  actual_digest="$(/usr/bin/shasum -a 256 "$distribution" | awk '{ print $1 }')"
  [[ "$expected_digest" =~ ^[a-f0-9]{64}$ && "$actual_digest" == "$expected_digest" ]] \
    || die "Package cleanup executable does not match its exact manifest digest." 70
  inventory_check recovery "$expected_version" "$distribution"
  /usr/bin/codesign --verify --strict --verbose=2 "$distribution"
  signature="$(/usr/bin/codesign -d --verbose=4 "$distribution" 2>&1)"
  team_id="$(printf '%s\n' "$signature" | awk -F= '$1 == "TeamIdentifier" { print $2 }')"
  [[ "$team_id" == "$RELEASE_TEAM_ID" ]] \
    || die "Package cleanup executable does not match the protected release Team ID." 70
  status_file="$HOSTWRIGHT_QUALIFICATION_ROOT/package-cleanup-status.json"
  sudo -n "$distribution" status --prefix "$package_prefix" --output json > "$status_file"
  package_version="$(plutil -extract status.packageVersion raw "$status_file")"
  [[ "$(plutil -extract status.packageIdentifier raw "$status_file")" == "$package_identifier" \
      && ( "$package_version" == "$baseline_package_version" || "$package_version" == "$candidate_package_version" ) \
      && "$(plutil -extract status.installedManifest.sourceCommit raw "$status_file")" == "$expected_commit" \
      && "$(plutil -extract status.installedManifest.packageVersion raw "$status_file")" == "$expected_version" ]] \
    || die "Package cleanup status is not owned by this qualification pair." 70
  sudo -n "$distribution" recover --prefix "$package_prefix" --output json \
    > "$HOSTWRIGHT_QUALIFICATION_ROOT/package-cleanup-recovery.json"
  if [[ -x "$distribution" && ! -L "$distribution" ]]; then
    sudo -n "$distribution" package-uninstall \
      --prefix "$package_prefix" --data-policy preserve --output json \
      > "$HOSTWRIGHT_QUALIFICATION_ROOT/package-cleanup-uninstall.json"
  fi
  require_package_absent "after failed-run package cleanup"
  record "failed-run-package-cleanup-completed"
}

prepare() {
  local tap_repository brew_prefix config_dir config_path config_source config_digest log_path error_log_path boot
  brew_prefix="$(brew --prefix)"
  config_dir="$brew_prefix/etc/hostwright"
  config_path="$config_dir/hostwright.yaml"
  log_path="$brew_prefix/var/log/hostwrightd.log"
  error_log_path="$brew_prefix/var/log/hostwrightd.error.log"
  verify_release_pair
  boot="$(boot_epoch)"
  write_state preparing "$boot"
  record "prepare-intent"
  qualify_package_lifecycle
  tap_repository="$(ensure_tap_checkout absent)"
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
  verify_release_pair
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
  tap_repository="$(ensure_tap_checkout present)"
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
  record "brew-upgrade-and-service-restart-passed baseline=$baseline_version candidate=$candidate_version"

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
  cleanup_qualified_package
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
[[ "$#" == 1 ]] || die "One qualification stage is required."
configure_versions
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
if [[ "$command" == prepare ]]; then
  validate_prepare_preflight
fi
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
record "versions mode=$qualification_mode baseline=$baseline_version baselineTag=$baseline_tag baselineReceipt=$baseline_package_version candidate=$candidate_version candidateTag=$candidate_tag candidateReceipt=$candidate_package_version inventorySHA256=$HOSTWRIGHT_ARTIFACT_INVENTORY_SHA256 inventoryPath=$HOSTWRIGHT_ARTIFACT_INVENTORY"
record "inputs baselineReleaseCommit=$HOSTWRIGHT_BASELINE_RELEASE_COMMIT candidateReleaseCommit=$HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT baselineTapCommit=$HOSTWRIGHT_BASELINE_TAP_COMMIT candidateTapCommit=$HOSTWRIGHT_CANDIDATE_TAP_COMMIT"
record "host productVersion=$(sw_vers -productVersion) buildVersion=$(sw_vers -buildVersion) architecture=$(uname -m) model=$(sysctl -n hw.model)"
record "stage-$command-started"
case "$command" in
  prepare) prepare ;;
  resume) resume ;;
  cleanup) cleanup_failed_run ;;
esac
