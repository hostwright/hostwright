#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  echo "usage: capture-static-swift-sdk-evidence.sh --root ABSOLUTE_DIR --repo-root ABSOLUTE_DIR --build-dir ABSOLUTE_DIR --records ABSOLUTE_DIR --temporary-root ABSOLUTE_DIR" >&2
  exit 64
}
root= repo_root= build_dir= records= temporary_root=
while (( $# )); do
  case "$1" in
    --root) (( $# >= 2 )) || usage; root=$2; shift 2 ;;
    --repo-root) (( $# >= 2 )) || usage; repo_root=$2; shift 2 ;;
    --build-dir) (( $# >= 2 )) || usage; build_dir=$2; shift 2 ;;
    --records) (( $# >= 2 )) || usage; records=$2; shift 2 ;;
    --temporary-root) (( $# >= 2 )) || usage; temporary_root=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$root" == /* && "$repo_root" == /* && "$build_dir" == /* && "$records" == /* && "$temporary_root" == /* ]] || usage
[[ -d "$root" && -d "$build_dir" && -d "$records" && -d "$temporary_root" ]] || usage
[[ "$(cat "$records/build-exit-status")" == 0 ]] || exit 1
[[ ! -e "$records/build-inputs" && ! -L "$records/build-inputs" ]] || exit 1
build_working_directory=$(cat "$records/build-working-directory")
[[ "$build_working_directory" == /* ]] || exit 1
printf '%s Capturing SDK source and build inputs\n' "$(date -u +%FT%TZ)"
python3 "$repo_root/scripts/release/capture-swift-sdk-build-inputs.py" \
  --sources "$root" --build "$build_dir" --sdk-archive "$records/swift-static-sdk.tar.gz" \
  --output "$records/build-inputs"
printf '%s Mapping SDK objects to their compiler inputs\n' "$(date -u +%FT%TZ)"
python3 "$repo_root/scripts/release/capture-sdk-object-sources.py" \
  --sources "$root" --build "$build_dir" --sdk-root "$build_dir/sdk_root/aarch64" \
  --sdk-build-inputs "$records/build-inputs/build-inputs.json" \
  --trace "$records/build.trace" --trace-cwd "$build_working_directory" \
  --relocate "/tmp=$temporary_root" \
  --generated-output "$records/build-inputs/generated-headers" \
  --output "$records/build-inputs/sdk-object-sources.json"
printf '%s Hashing complete SDK evidence\n' "$(date -u +%FT%TZ)"
(cd "$records" && find . -type f ! -name checksums.sha256 -print0 | sort -z | xargs -0 sha256sum) > "$records/checksums.sha256"
printf '%s SDK evidence complete\n' "$(date -u +%FT%TZ)"
