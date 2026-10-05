#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly framework_version="0.35.0"
readonly kernel_name="vmlinux-6.18.15-186"
readonly kernel_size="16148992"
readonly kernel_sha256="55f86b8394c1d46551836f5c1d3525cdc8d505aeb9bb630c608edb564674239d"
readonly manifest_digest="15a70c63c9ca254020d8bdbe1b6e48332db0629881f563624bfd319412a37ea3"
readonly manifest_size="406"
readonly configuration_digest="7812fb606774f30d8b6d36c2a37a6e12ae719ece3fc34775f9b87ee94639e257"
readonly configuration_size="151"
readonly layer_digest="3c6b087fc41b30d44dac2951f0ee798b242fac8e00db9b6375e25ef48765418d"
readonly layer_size="67222934"
readonly index_sha256="ca910ca52793fbd5269c98aff0ba03091238558ac087d47967611f9d033076d1"
readonly index_size="240"
readonly layout_sha256="18f0797eab35a4597c1e9624aa4f15fd91f6254e5538c1e0d193b2a95dd4acc6"
readonly layout_size="30"
readonly guest_loader_name="hostwright-netfilter"
readonly guest_loader_size="2949246"
readonly guest_loader_sha256="a411dbcf1efaaf0ea0da17d76e3376a92b99037a8cb00af6588e8ecc6f3f7e99"

work_root=""
die() { printf '%s\n' "$1" >&2; exit "${2:-70}"; }
usage() {
  /bin/cat >&2 <<'USAGE'
Usage:
  prepare-containerization-assets.sh --output ABSOLUTE_PATH \
    --runtime-archive ABSOLUTE_PATH --source-commit SHA40 --run-id ID --attempt N [--dry-run]
  prepare-containerization-assets.sh --verify ABSOLUTE_PATH
USAGE
}
cleanup() {
  local status="$1"
  trap - EXIT INT TERM HUP
  if [[ -n "$work_root" && -d "$work_root" && ! -L "$work_root" ]]; then /bin/rm -rf -- "$work_root"; fi
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

assert_safe_absolute_path() {
  local path="$1" current="/" relative component
  [[ "$path" == /* && "$path" != / && "$path" != *$'\n'* && "$path" != *$'\r'* \
      && "$path" != *//* && "$path" != */./* && "$path" != */. \
      && "$path" != */../* && "$path" != */.. ]] \
    || die "Containerization asset path must be one normalized absolute path." 64
  relative="${path#/}"
  local -a components=()
  IFS='/' read -r -a components <<< "$relative"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != . && "$component" != .. ]] \
      || die "Containerization asset path contains an unsafe component." 64
    if [[ "$current" == / ]]; then current="/$component"; else current="$current/$component"; fi
    [[ ! -L "$current" ]] || die "Containerization asset path traverses a symbolic link: $current" 66
    if [[ -e "$current" && ! -d "$current" && "$current" != "$path" ]]; then
      die "Containerization asset path traverses a non-directory: $current" 66
    fi
  done
}
assert_safe_parent() {
  local parent mode
  parent="$(/usr/bin/dirname "$1")"
  [[ -d "$parent" && ! -L "$parent" ]] || die "Asset output parent must be an existing non-symlink directory." 66
  [[ "$(/usr/bin/stat -f '%u' "$parent")" == "$(/usr/bin/id -u)" ]] || die "Asset output parent must be owned by the preparation user." 77
  mode="$(/usr/bin/stat -f '%Lp' "$parent")"
  (( (8#$mode & 8#022) == 0 )) || die "Asset output parent must not be group- or world-writable." 77
}
sha256_of() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
verify_file() {
  local file="$1" size="$2" digest="$3" label="$4"
  [[ -f "$file" && ! -L "$file" ]] || die "$label is missing or not a regular file."
  [[ "$(/usr/bin/stat -f '%z' "$file")" == "$size" ]] || die "$label size differs from the locked value."
  [[ "$(sha256_of "$file")" == "$digest" ]] || die "$label SHA-256 differs from the locked value."
}
expected_directories() { /bin/cat <<'EOF'
guest
kernel
vminit
vminit/blobs
vminit/blobs/sha256
EOF
}
expected_files() { /bin/cat <<EOF
guest/$guest_loader_name
kernel/$kernel_name
vminit/blobs/sha256/$manifest_digest
vminit/blobs/sha256/$configuration_digest
vminit/blobs/sha256/$layer_digest
vminit/index.json
vminit/oci-layout
EOF
}
expected_entries() { expected_directories; expected_files; }
verify_guest_loader() {
  local file="$1" size header
  [[ -f "$file" && ! -L "$file" ]] || die "Guest network-policy loader is missing or not a regular file."
  size="$(/usr/bin/stat -f '%z' "$file")"
  [[ "$size" == "$guest_loader_size" ]] || die "Guest network-policy loader size differs from the locked value."
  header="$(/usr/bin/od -An -tx1 -N20 "$file" | /usr/bin/tr -s '[:space:]' ' ' | /usr/bin/awk '{$1=$1; print}')"
  [[ "$header" == "7f 45 4c 46 02 01 01 "*" 02 00 b7 00" \
      || "$header" == "7f 45 4c 46 02 01 01 "*" 03 00 b7 00" ]] \
    || die "Guest network-policy loader must be a Linux ARM64 ELF executable."
  [[ "$(sha256_of "$file")" == "$guest_loader_sha256" ]] \
    || die "Guest network-policy loader SHA-256 differs from the locked value."
}
verify_tree() {
  local root="$1" links actual expected entry layout index
  [[ -d "$root" && ! -L "$root" ]] || die "Containerization asset root is missing or unsafe."
  [[ "$(/usr/bin/stat -f '%u' "$root")" == "$(/usr/bin/id -u)" \
      && "$(/usr/bin/stat -f '%Lp' "$root")" == 700 ]] || die "Containerization asset root ownership or mode differs." 77
  links="$(/usr/bin/find "$root" -mindepth 1 -type l -print -quit)"
  [[ -z "$links" ]] || die "Containerization asset root contains a symbolic link: $links" 66
  actual="$(cd "$root" && /usr/bin/find . -mindepth 1 -print | /usr/bin/sed 's#^\./##' | LC_ALL=C /usr/bin/sort)"
  expected="$(expected_entries | LC_ALL=C /usr/bin/sort)"
  [[ "$actual" == "$expected" ]] || die "Containerization asset root has missing or unexpected entries."
  while IFS= read -r entry; do
    [[ "$(/usr/bin/stat -f '%u' "$root/$entry")" == "$(/usr/bin/id -u)" \
        && "$(/usr/bin/stat -f '%Lp' "$root/$entry")" == 700 ]] || die "Asset directory mode differs: $entry" 77
  done < <(expected_directories)
  while IFS= read -r entry; do
    [[ "$(/usr/bin/stat -f '%u' "$root/$entry")" == "$(/usr/bin/id -u)" \
        && "$(/usr/bin/stat -f '%Lp' "$root/$entry")" == 644 \
        && "$(/usr/bin/stat -f '%l' "$root/$entry")" == 1 ]] || die "Asset file mode differs: $entry" 77
  done < <(expected_files)
  verify_file "$root/kernel/$kernel_name" "$kernel_size" "$kernel_sha256" "Rebuilt Linux kernel"
  verify_file "$root/vminit/oci-layout" "$layout_size" "$layout_sha256" "OCI layout metadata"
  verify_file "$root/vminit/index.json" "$index_size" "$index_sha256" "OCI image index JSON"
  verify_file "$root/vminit/blobs/sha256/$manifest_digest" "$manifest_size" "$manifest_digest" "Direct OCI image manifest"
  verify_file "$root/vminit/blobs/sha256/$configuration_digest" "$configuration_size" "$configuration_digest" "OCI image configuration"
  verify_file "$root/vminit/blobs/sha256/$layer_digest" "$layer_size" "$layer_digest" "OCI image layer"
  verify_guest_loader "$root/guest/$guest_loader_name"
  layout='{"imageLayoutVersion":"1.0.0"}'
  index="{\"manifests\":[{\"digest\":\"sha256:$manifest_digest\",\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"size\":$manifest_size}],\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"schemaVersion\":2}"
  [[ "$(/bin/cat "$root/vminit/oci-layout")" == "$layout" ]] || die "OCI layout metadata differs from the generated contract."
  [[ "$(/bin/cat "$root/vminit/index.json")" == "$index" ]] || die "OCI index does not point directly to the pinned manifest."
}
print_lock() {
  /bin/cat <<EOF
Containerization framework: $framework_version
Rebuilt Linux kernel: $kernel_sha256 ($kernel_size bytes)
Direct OCI image manifest: sha256:$manifest_digest ($manifest_size bytes)
Containerization ImageStore reference: untagged@sha256:$manifest_digest
OCI image configuration: $configuration_digest ($configuration_size bytes)
OCI image layer: $layer_digest ($layer_size bytes)
Guest policy loader: $guest_loader_sha256 ($guest_loader_size bytes)
EOF
}
prepare() {
  local output="$1" archive="$2" source_commit="$3" run_id="$4" attempt="$5"
  local parent staging materializer
  assert_safe_absolute_path "$output"
  assert_safe_absolute_path "$archive"
  assert_safe_parent "$output"
  [[ -f "$archive" && ! -L "$archive" ]] || die "Runtime provenance archive must be a regular non-symlink file." 66
  [[ ! -e "$output" && ! -L "$output" ]] || die "Asset output already exists; verify or choose a fresh output path." 73
  [[ "$source_commit" =~ ^[a-f0-9]{40}$ && "$run_id" =~ ^[1-9][0-9]*$ && "$attempt" =~ ^[1-9][0-9]*$ ]] \
    || die "Runtime provenance source commit, run ID, or attempt is invalid." 64
  parent="$(/usr/bin/dirname "$output")"
  work_root="$(/usr/bin/mktemp -d "$parent/.$(/usr/bin/basename "$output").prepare.XXXXXXXX")"
  /bin/chmod 700 "$work_root"
  staging="$work_root/root"
  materializer="$(/usr/bin/dirname "$0")/materialize-runtime-assets.py"
  /usr/bin/python3 "$materializer" --archive "$archive" --output "$staging" \
    --source-commit "$source_commit" --run-id "$run_id" --attempt "$attempt" \
    || die "Authenticated runtime provenance could not be materialized."
  verify_tree "$staging"
  [[ ! -e "$output" && ! -L "$output" ]] || die "Asset output appeared while preparation was running." 73
  /bin/mv "$staging" "$output"
  printf 'Containerization %s assets prepared from authenticated runtime provenance: %s\n' "$framework_version" "$output"
}

mode="" output="" archive="" source_commit="" run_id="" attempt="" dry_run=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|--verify|--runtime-archive|--source-commit|--run-id|--attempt)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      case "$1" in
        --output) [[ -z "$mode" ]] || { usage; exit 64; }; mode=prepare; output="$2" ;;
        --verify) [[ -z "$mode" ]] || { usage; exit 64; }; mode=verify; output="$2" ;;
        --runtime-archive) [[ -z "$archive" ]] || { usage; exit 64; }; archive="$2" ;;
        --source-commit) [[ -z "$source_commit" ]] || { usage; exit 64; }; source_commit="$2" ;;
        --run-id) [[ -z "$run_id" ]] || { usage; exit 64; }; run_id="$2" ;;
        --attempt) [[ -z "$attempt" ]] || { usage; exit 64; }; attempt="$2" ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done
[[ -n "$mode" && -n "$output" ]] || { usage; exit 64; }
assert_safe_absolute_path "$output"
case "$mode" in
  verify)
    [[ "$dry_run" == false && -z "$archive$source_commit$run_id$attempt" ]] || { usage; exit 64; }
    verify_tree "$output"
    printf 'Containerization %s assets verified: %s\n' "$framework_version" "$output"
    ;;
  prepare)
    [[ -n "$archive" && -n "$source_commit" && -n "$run_id" && -n "$attempt" ]] || { usage; exit 64; }
    assert_safe_parent "$output"
    if [[ "$dry_run" == true ]]; then
      [[ "$source_commit" =~ ^[a-f0-9]{40}$ && "$run_id" =~ ^[1-9][0-9]*$ && "$attempt" =~ ^[1-9][0-9]*$ ]] \
        || die "Runtime provenance source commit, run ID, or attempt is invalid." 64
      print_lock
      printf 'Dry run: authenticated source %s run %s attempt %s would be verified and materialized.\n' "$source_commit" "$run_id" "$attempt"
    else
      prepare "$output" "$archive" "$source_commit" "$run_id" "$attempt"
    fi
    ;;
esac
