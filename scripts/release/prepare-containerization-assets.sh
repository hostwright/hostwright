#!/usr/bin/env bash
set -euo pipefail

umask 077

readonly framework_version="0.35.0"
readonly kernel_archive_url="https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst"
readonly kernel_archive_size="596775193"
readonly kernel_archive_sha256="f63d54507d1f18635d94475077e4c2330de4d8e05cedf25f7c38f063b0e66a91"
readonly kernel_archive_member="opt/kata/share/kata-containers/vmlinux-6.18.15-186"
readonly kernel_name="vmlinux-6.18.15-186"
readonly kernel_size="16151040"
readonly kernel_sha256="2fe4a58d2885d623bcb4d705900ac8c1d4f02371152da8126b3b00c8c47fc3a1"

readonly vminit_repository="apple/containerization/vminit"
readonly vminit_reference="ghcr.io/apple/containerization/vminit:0.35.0"
readonly vminit_tag="0.35.0"
readonly vminit_index_digest="5708d65ba1914caa756a2e813831e17d7655042799310bc94efef82210c2dac6"
readonly vminit_index_size="306"
readonly vminit_variant_digest="04cd14f8e6ec9617611429aaf2a91a841b27ff9eae847acaca48430f58c5e57d"
readonly vminit_variant_size="409"
readonly vminit_configuration_digest="30d24816422f41337fae35f59a3c03ac13559fd42bd0d67321a7db4d57ac4988"
readonly vminit_configuration_size="255"
readonly vminit_layer_digest="e3b2b9d347c2e5834d9fe5b4d615f5c0632c485d785e64f5c6b4c9b179ac168f"
readonly vminit_layer_size="66895112"
readonly vminit_index_media_type="application/vnd.oci.image.index.v1+json"
readonly vminit_manifest_media_type="application/vnd.oci.image.manifest.v1+json"

work_root=""

die() {
  printf '%s\n' "$1" >&2
  exit "${2:-70}"
}

usage() {
  /bin/cat >&2 <<'USAGE'
Usage:
  prepare-containerization-assets.sh --output ABSOLUTE_PATH [--dry-run]
  prepare-containerization-assets.sh --verify ABSOLUTE_PATH
USAGE
}

cleanup() {
  local status="$1"
  trap - EXIT INT TERM HUP
  if [[ -n "$work_root" && -d "$work_root" && ! -L "$work_root" ]]; then
    /bin/rm -rf -- "$work_root"
  fi
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

assert_safe_absolute_path() {
  local path="$1"
  [[ "$path" == /* && "$path" != / && "$path" != *$'\n'* && "$path" != *$'\r'* \
      && "$path" != *//* && "$path" != */./* && "$path" != */. \
      && "$path" != */../* && "$path" != */.. ]] \
    || die "Containerization asset output must be one normalized absolute path." 64

  local current="/"
  local relative="${path#/}"
  local component
  local -a components=()
  IFS='/' read -r -a components <<< "$relative"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != . && "$component" != .. ]] \
      || die "Containerization asset output contains an unsafe path component." 64
    if [[ "$current" == / ]]; then
      current="/$component"
    else
      current="$current/$component"
    fi
    if [[ -L "$current" ]]; then
      die "Containerization asset output traverses a symbolic link: $current" 66
    fi
    if [[ -e "$current" && ! -d "$current" && "$current" != "$path" ]]; then
      die "Containerization asset output traverses a non-directory: $current" 66
    fi
  done
}

assert_safe_parent() {
  local output="$1"
  local parent
  parent="$(/usr/bin/dirname "$output")"
  [[ -d "$parent" && ! -L "$parent" ]] \
    || die "Containerization asset output parent must already be a non-symlink directory." 66
  [[ "$(/usr/bin/stat -f '%u' "$parent")" == "$(/usr/bin/id -u)" ]] \
    || die "Containerization asset output parent must be owned by the preparation user." 77
  local mode
  mode="$(/usr/bin/stat -f '%Lp' "$parent")"
  (( (8#$mode & 8#022) == 0 )) \
    || die "Containerization asset output parent must not be group- or world-writable." 77
}

sha256_of() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

verify_file() {
  local file="$1"
  local expected_size="$2"
  local expected_sha256="$3"
  local label="$4"
  [[ -f "$file" && ! -L "$file" ]] || die "$label is missing or not a regular file."
  [[ "$(/usr/bin/stat -f '%z' "$file")" == "$expected_size" ]] \
    || die "$label size differs from the locked value."
  [[ "$(sha256_of "$file")" == "$expected_sha256" ]] \
    || die "$label SHA-256 differs from the locked value."
}

expected_entries() {
  expected_directories
  expected_files
}

expected_directories() {
  /bin/cat <<EOF
kernel
vminit
vminit/blobs
vminit/blobs/sha256
EOF
}

expected_files() {
  /bin/cat <<EOF
kernel/$kernel_name
vminit/blobs/sha256/$vminit_configuration_digest
vminit/blobs/sha256/$vminit_index_digest
vminit/blobs/sha256/$vminit_layer_digest
vminit/blobs/sha256/$vminit_variant_digest
vminit/index.json
vminit/oci-layout
EOF
}

verify_tree() {
  local root="$1"
  [[ -d "$root" && ! -L "$root" ]] \
    || die "Containerization asset root is missing or not a non-symlink directory."
  [[ "$(/usr/bin/stat -f '%u' "$root")" == "$(/usr/bin/id -u)" \
      && "$(/usr/bin/stat -f '%Lp' "$root")" == 700 ]] \
    || die "Containerization asset root ownership or mode differs." 77

  local links
  links="$(/usr/bin/find "$root" -mindepth 1 -type l -print -quit)"
  [[ -z "$links" ]] || die "Containerization asset root contains a symbolic link: $links" 66

  local actual expected
  actual="$(cd "$root" && /usr/bin/find . -mindepth 1 -print | /usr/bin/sed 's#^\./##' | LC_ALL=C /usr/bin/sort)"
  expected="$(expected_entries | LC_ALL=C /usr/bin/sort)"
  [[ "$actual" == "$expected" ]] \
    || die "Containerization asset root contains missing or unexpected entries."

  local directory
  while IFS= read -r directory; do
    [[ "$(/usr/bin/stat -f '%u' "$root/$directory")" == "$(/usr/bin/id -u)" \
        && "$(/usr/bin/stat -f '%Lp' "$root/$directory")" == 700 ]] \
      || die "Containerization asset directory mode differs: $directory" 77
  done < <(expected_directories)

  local file
  while IFS= read -r file; do
    [[ "$(/usr/bin/stat -f '%u' "$root/$file")" == "$(/usr/bin/id -u)" \
        && "$(/usr/bin/stat -f '%Lp' "$root/$file")" == 644 \
        && "$(/usr/bin/stat -f '%l' "$root/$file")" == 1 ]] \
      || die "Containerization asset file mode differs: $file" 77
  done < <(expected_files)

  verify_file "$root/kernel/$kernel_name" "$kernel_size" "$kernel_sha256" "Kata kernel"
  verify_file "$root/vminit/blobs/sha256/$vminit_index_digest" \
    "$vminit_index_size" "$vminit_index_digest" "vminit OCI index"
  verify_file "$root/vminit/blobs/sha256/$vminit_variant_digest" \
    "$vminit_variant_size" "$vminit_variant_digest" "vminit arm64 manifest"
  verify_file "$root/vminit/blobs/sha256/$vminit_configuration_digest" \
    "$vminit_configuration_size" "$vminit_configuration_digest" "vminit configuration"
  verify_file "$root/vminit/blobs/sha256/$vminit_layer_digest" \
    "$vminit_layer_size" "$vminit_layer_digest" "vminit layer"

  local expected_layout expected_index
  expected_layout='{"imageLayoutVersion":"1.0.0"}'
  expected_index="{\"schemaVersion\":2,\"manifests\":[{\"mediaType\":\"$vminit_index_media_type\",\"digest\":\"sha256:$vminit_index_digest\",\"size\":$vminit_index_size,\"annotations\":{\"org.opencontainers.image.ref.name\":\"$vminit_reference\"}}]}"
  [[ "$(/bin/cat "$root/vminit/oci-layout")" == "$expected_layout" ]] \
    || die "Containerization OCI layout metadata differs from the locked value."
  [[ "$(/bin/cat "$root/vminit/index.json")" == "$expected_index" ]] \
    || die "Containerization OCI root index differs from the locked value."
}

print_lock() {
  /bin/cat <<EOF
Containerization framework: $framework_version
Kata archive: $kernel_archive_sha256 ($kernel_archive_size bytes)
Kata kernel: $kernel_sha256 ($kernel_size bytes)
vminit index: sha256:$vminit_index_digest ($vminit_index_size bytes)
vminit arm64 manifest: sha256:$vminit_variant_digest ($vminit_variant_size bytes)
vminit configuration: sha256:$vminit_configuration_digest ($vminit_configuration_size bytes)
vminit layer: sha256:$vminit_layer_digest ($vminit_layer_size bytes)
EOF
}

download_public() {
  local url="$1"
  local destination="$2"
  /usr/bin/curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --retry 3 --retry-all-errors --output "$destination" "$url"
  /bin/chmod 600 "$destination"
}

download_registry() {
  local auth_config="$1"
  local accept="$2"
  local url="$3"
  local destination="$4"
  /usr/bin/curl --config "$auth_config" --fail --location --silent --show-error \
    --proto '=https' --tlsv1.2 --retry 3 --retry-all-errors \
    --header "Accept: $accept" --output "$destination" "$url"
  /bin/chmod 600 "$destination"
}

prepare() {
  local output="$1"
  local parent base downloads staging token_response auth_config token
  parent="$(/usr/bin/dirname "$output")"
  base="$(/usr/bin/basename "$output")"

  if [[ -e "$output" || -L "$output" ]]; then
    verify_tree "$output"
    printf 'Containerization 0.35.0 assets already verified: %s\n' "$output"
    return
  fi

  [[ -x /usr/bin/awk && -x /usr/bin/basename && -x /usr/bin/curl \
      && -x /usr/bin/dirname && -x /usr/bin/find && -x /usr/bin/id \
      && -x /usr/bin/mktemp && -x /usr/bin/plutil && -x /usr/bin/sed \
      && -x /usr/bin/shasum && -x /usr/bin/sort && -x /usr/bin/stat \
      && -x /usr/bin/tar && -x /bin/chmod && -x /bin/mkdir && -x /bin/mv ]] \
    || die "Required macOS asset verification tools are unavailable." 69

  work_root="$(/usr/bin/mktemp -d "$parent/.${base}.prepare.XXXXXXXX")"
  [[ -d "$work_root" && ! -L "$work_root" ]] \
    || die "Unable to create a private asset preparation directory."
  /bin/chmod 700 "$work_root"
  downloads="$work_root/downloads"
  staging="$work_root/root"
  /bin/mkdir -m 700 "$downloads" "$staging"

  local kernel_archive="$downloads/kata-static-3.28.0-arm64.tar.zst"
  download_public "$kernel_archive_url" "$kernel_archive"
  verify_file "$kernel_archive" "$kernel_archive_size" "$kernel_archive_sha256" "Kata archive"

  /bin/mkdir -m 700 "$staging/kernel"
  /usr/bin/tar -xOf "$kernel_archive" "$kernel_archive_member" \
    > "$downloads/$kernel_name"
  /bin/chmod 600 "$downloads/$kernel_name"
  verify_file "$downloads/$kernel_name" "$kernel_size" "$kernel_sha256" "Kata kernel"
  /bin/mv "$downloads/$kernel_name" "$staging/kernel/$kernel_name"

  token_response="$downloads/ghcr-token.json"
  download_public \
    "https://ghcr.io/token?scope=repository%3Aapple%2Fcontainerization%2Fvminit%3Apull" \
    "$token_response"
  [[ "$(/usr/bin/stat -f '%z' "$token_response")" -le 16384 ]] \
    || die "GHCR token response is oversized."
  token="$(/usr/bin/plutil -extract token raw -o - "$token_response")"
  [[ ${#token} -ge 16 && ${#token} -le 8192 && "$token" =~ ^[A-Za-z0-9._~-]+$ ]] \
    || die "GHCR returned an invalid bearer token."
  auth_config="$downloads/curl-auth.conf"
  printf 'header = "Authorization: Bearer %s"\n' "$token" > "$auth_config"
  /bin/chmod 600 "$auth_config"
  token=""
  /bin/rm -f "$token_response"

  local registry_root="https://ghcr.io/v2/$vminit_repository"
  local index_file="$downloads/$vminit_index_digest"
  local variant_file="$downloads/$vminit_variant_digest"
  local configuration_file="$downloads/$vminit_configuration_digest"
  local layer_file="$downloads/$vminit_layer_digest"
  download_registry "$auth_config" "$vminit_index_media_type" \
    "$registry_root/manifests/$vminit_tag" "$index_file"
  verify_file "$index_file" "$vminit_index_size" "$vminit_index_digest" "vminit OCI index"
  download_registry "$auth_config" "$vminit_manifest_media_type" \
    "$registry_root/manifests/sha256:$vminit_variant_digest" "$variant_file"
  verify_file "$variant_file" "$vminit_variant_size" "$vminit_variant_digest" "vminit arm64 manifest"
  download_registry "$auth_config" 'application/octet-stream' \
    "$registry_root/blobs/sha256:$vminit_configuration_digest" "$configuration_file"
  verify_file "$configuration_file" "$vminit_configuration_size" \
    "$vminit_configuration_digest" "vminit configuration"
  download_registry "$auth_config" 'application/octet-stream' \
    "$registry_root/blobs/sha256:$vminit_layer_digest" "$layer_file"
  verify_file "$layer_file" "$vminit_layer_size" "$vminit_layer_digest" "vminit layer"
  /bin/rm -f "$auth_config"

  /bin/mkdir -m 700 -p "$staging/vminit/blobs/sha256"
  /bin/mv "$index_file" "$staging/vminit/blobs/sha256/$vminit_index_digest"
  /bin/mv "$variant_file" "$staging/vminit/blobs/sha256/$vminit_variant_digest"
  /bin/mv "$configuration_file" "$staging/vminit/blobs/sha256/$vminit_configuration_digest"
  /bin/mv "$layer_file" "$staging/vminit/blobs/sha256/$vminit_layer_digest"

  printf '%s\n' '{"imageLayoutVersion":"1.0.0"}' > "$staging/vminit/oci-layout"
  printf '%s\n' \
    "{\"schemaVersion\":2,\"manifests\":[{\"mediaType\":\"$vminit_index_media_type\",\"digest\":\"sha256:$vminit_index_digest\",\"size\":$vminit_index_size,\"annotations\":{\"org.opencontainers.image.ref.name\":\"$vminit_reference\"}}]}" \
    > "$staging/vminit/index.json"
  /usr/bin/find "$staging" -type d -exec /bin/chmod 700 {} +
  /usr/bin/find "$staging" -type f -exec /bin/chmod 644 {} +
  verify_tree "$staging"

  assert_safe_absolute_path "$output"
  assert_safe_parent "$output"
  [[ ! -e "$output" && ! -L "$output" ]] \
    || die "Containerization asset output appeared while preparation was running."
  /bin/mv "$staging" "$output"
  printf 'Containerization 0.35.0 assets prepared and verified: %s\n' "$output"
}

mode=""
output=""
dry_run=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ -z "$mode" && $# -ge 2 ]] || { usage; exit 64; }
      mode=prepare
      output="$2"
      shift 2
      ;;
    --verify)
      [[ -z "$mode" && $# -ge 2 ]] || { usage; exit 64; }
      mode=verify
      output="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

[[ -n "$mode" && -n "$output" ]] || { usage; exit 64; }
[[ "$mode" == prepare || "$dry_run" == false ]] || { usage; exit 64; }
assert_safe_absolute_path "$output"

case "$mode" in
  verify)
    verify_tree "$output"
    printf 'Containerization 0.35.0 assets verified: %s\n' "$output"
    ;;
  prepare)
    assert_safe_parent "$output"
    if [[ "$dry_run" == true ]]; then
      if [[ -e "$output" || -L "$output" ]]; then verify_tree "$output"; fi
      print_lock
      printf 'Dry run: no files downloaded or written for %s\n' "$output"
    else
      prepare "$output"
    fi
    ;;
esac
