#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  echo "usage: build-static-swift-sdk.sh --root ABSOLUTE_DIR --repo-root ABSOLUTE_DIR --build-dir ABSOLUTE_DIR --products-dir ABSOLUTE_DIR --records ABSOLUTE_DIR" >&2
  exit 64
}

root= repo_root= build_dir= products_dir= records=
while (( $# )); do
  case "$1" in
    --root) (( $# >= 2 )) || usage; root=$2; shift 2 ;;
    --repo-root) (( $# >= 2 )) || usage; repo_root=$2; shift 2 ;;
    --build-dir) (( $# >= 2 )) || usage; build_dir=$2; shift 2 ;;
    --products-dir) (( $# >= 2 )) || usage; products_dir=$2; shift 2 ;;
    --records) (( $# >= 2 )) || usage; records=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$root" == /* && "$repo_root" == /* && "$build_dir" == /* && "$products_dir" == /* && "$records" == /* ]] || usage
[[ -d "$root/builder/swift-ci/sdks/static-linux/scripts" && -d "$root/swift-project/swift" ]] || {
  echo "Swift SDK source checkout is incomplete" >&2
  exit 65
}
for path in "$build_dir" "$products_dir" "$records"; do
  [[ ! -e "$path" && ! -L "$path" ]] || { echo "Swift SDK output already exists: $path" >&2; exit 65; }
done
mkdir -m 700 "$build_dir" "$products_dir" "$records"

swift_path=$(command -v swift)
swift_real=$(readlink -f "$swift_path")
toolchain_bin=$(dirname "$swift_real")
if [[ "${swift_real##*/}" == swiftly ]]; then
  swiftly_toolchain=$(swiftly use --print-location 2>"$records/swiftly-use.stderr") || {
    echo "Swiftly could not resolve its active toolchain" >&2
    exit 69
  }
  [[ "$swiftly_toolchain" == /* ]] || {
    echo "Swiftly returned an invalid toolchain path: $swiftly_toolchain" >&2
    exit 69
  }
  printf '%s\n' "$swiftly_toolchain" > "$records/swift-toolchain-location"
  toolchain_bin="$swiftly_toolchain/usr/bin"
  swift_path="$toolchain_bin/swift"
  swift_real=$(readlink -f "$swift_path")
fi
[[ -x "$toolchain_bin/swiftc" && -x "$toolchain_bin/clang" && -x "$toolchain_bin/clang++" ]] || {
  echo "Swift 6.3 toolchain must include swiftc, clang, and clang++" >&2
  exit 69
}
[[ "$("$swift_path" --version | head -1)" == "Swift version 6.3"* ]] || {
  echo "static Swift SDK build requires the pinned Swift 6.3 compiler" >&2
  exit 69
}

export PATH="$toolchain_bin:$PATH"
export CC="$toolchain_bin/clang" CXX="$toolchain_bin/clang++"
export SOURCE_DATE_EPOCH=1767225600 TZ=UTC LANG=C.UTF-8 LC_ALL=C.UTF-8 TERM=xterm
export HOSTWRIGHT_SDK_BUILD_JOBS=3
export HOSTWRIGHT_SDK_HOST_TOOLS_BUILD_TYPE=Release
export HOSTWRIGHT_SDK_TARGET_STDLIB_BUILD_TYPE=RelWithDebInfo
export SWIFTCI_USE_LOCAL_DEPS=1 CMAKE_EXPORT_COMPILE_COMMANDS=ON
export CMAKE_BUILD_PARALLEL_LEVEL="$HOSTWRIGHT_SDK_BUILD_JOBS"
export MAKEFLAGS="-j$HOSTWRIGHT_SDK_BUILD_JOBS"

git -C "$root/builder" apply --check "$repo_root/scripts/release/patches/swift-sdk/swift-ci-build-jobs.patch"
git -C "$root/builder" apply "$repo_root/scripts/release/patches/swift-sdk/swift-ci-build-jobs.patch"
git -C "$root/swift-project/swift-driver" apply --check "$repo_root/scripts/release/patches/swift-sdk/swift-driver-ninja-jobs.patch"
git -C "$root/swift-project/swift-driver" apply "$repo_root/scripts/release/patches/swift-sdk/swift-driver-ninja-jobs.patch"
git -C "$root/swift-project/swift-foundation-icu" apply --check "$repo_root/scripts/release/patches/swift-sdk/foundation-icu-upstream-license.patch"
git -C "$root/swift-project/swift-foundation-icu" apply "$repo_root/scripts/release/patches/swift-sdk/foundation-icu-upstream-license.patch"

{
  printf 'Swift: '; "$swift_path" --version | head -1
  printf 'swift: '; sha256sum "$swift_real"
  for tool in swiftc clang clang++ ld.lld llvm-ar ninja cmake; do
    resolved=$(command -v "$tool")
    printf '%s: ' "$tool"
    sha256sum "$(readlink -f "$resolved")"
  done
  printf 'builder patch: '; sha256sum "$repo_root/scripts/release/patches/swift-sdk/swift-ci-build-jobs.patch"
  printf 'driver patch: '; sha256sum "$repo_root/scripts/release/patches/swift-sdk/swift-driver-ninja-jobs.patch"
  printf 'ICU license patch: '; sha256sum "$repo_root/scripts/release/patches/swift-sdk/foundation-icu-upstream-license.patch"
} > "$records/toolchain-and-patches.txt"
python3 - "$records/build-environment.json" <<'PY'
import json, os, platform, sys
keys = ['PATH', 'CC', 'CXX', 'SOURCE_DATE_EPOCH', 'TZ', 'LANG', 'LC_ALL', 'TERM',
        'SWIFTCI_USE_LOCAL_DEPS', 'CMAKE_EXPORT_COMPILE_COMMANDS',
        'CMAKE_BUILD_PARALLEL_LEVEL', 'MAKEFLAGS', 'HOSTWRIGHT_SDK_BUILD_JOBS',
        'HOSTWRIGHT_SDK_HOST_TOOLS_BUILD_TYPE',
        'HOSTWRIGHT_SDK_TARGET_STDLIB_BUILD_TYPE']
with open(sys.argv[1], 'x', encoding='utf-8') as stream:
    json.dump({'environment': {key: os.environ[key] for key in keys},
               'swiftSDKBuildConfiguration': {
                   'hostToolsReleaseCFlags': '-O2 -DNDEBUG',
                   'hostToolsReleaseCXXFlags': '-O2 -DNDEBUG',
                   'targetStdlibAssertions': True,
               },
               'platform': platform.uname()._asdict()}, stream, sort_keys=True, separators=(',', ':'))
    stream.write('\n')
PY
date -u +%FT%TZ > "$records/build-started"
build_working_directory=$(pwd -P)
printf '%s\n' "$build_working_directory" > "$records/build-working-directory"

set +e
strace -f -qq -ttt -T -s 65535 -yy -e trace=process,file -o "$records/build.trace" \
  bash -x "$root/builder/swift-ci/sdks/static-linux/scripts/build.sh" \
    --source-dir "$root" --build-dir "$build_dir" --products-dir "$products_dir" \
    --archs aarch64 --jobs "$HOSTWRIGHT_SDK_BUILD_JOBS" --version 0.1.0-hostwright.1 2>&1 | tee "$records/build.log"
result=${PIPESTATUS[0]}
set -e
printf '%s\n' "$result" > "$records/build-exit-status"
date -u +%FT%TZ > "$records/build-finished"
(( result == 0 )) || exit "$result"

find "$products_dir" -type f -name '*.tar.gz' -print > "$records/product-archives.txt"
mapfile -t archives < "$records/product-archives.txt"
(( ${#archives[@]} == 1 )) || { echo "expected one static Swift SDK archive" >&2; exit 65; }
cp "${archives[0]}" "$records/swift-static-sdk.tar.gz"
sha256sum "$records/swift-static-sdk.tar.gz" > "$records/swift-static-sdk.sha256"
python3 "$repo_root/scripts/release/capture-swift-sdk-build-inputs.py" \
  --sources "$root" --build "$build_dir" --sdk-archive "$records/swift-static-sdk.tar.gz" \
  --output "$records/build-inputs"
python3 "$repo_root/scripts/release/capture-sdk-object-sources.py" \
  --sources "$root" --build "$build_dir" --sdk-root "$build_dir/sdk_root/aarch64" \
  --trace "$records/build.trace" --trace-cwd "$build_working_directory" \
  --generated-output "$records/build-inputs/generated-headers" \
  --output "$records/build-inputs/sdk-object-sources.json"
(cd "$records" && find . -type f ! -name checksums.sha256 -print0 | sort -z | xargs -0 sha256sum) > "$records/checksums.sha256"
