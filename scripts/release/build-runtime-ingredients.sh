#!/usr/bin/env bash
set -euo pipefail
umask 077
readonly source_capture="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/capture-runtime-source.py"
readonly package_capture="$(dirname -- "$source_capture")/capture-package-sources.py"

readonly containerization_commit=44bec8b9933bc491d0cbf44abac90a1f6aaebf6b
readonly kata_commit=660e3bb6535b141c84430acb25b159857278d596
readonly kernel_version=6.18.15
readonly kernel_config_version=186
readonly kernel_source_sha=7c716216c3c4134ed0de69195701e677577bbcdd3979f331c182acd06bf2f170
readonly build_time=2026-01-01T00:00:00Z

die() { printf '%s\n' "$1" >&2; exit "${2:-70}"; }
usage() { die "usage: build-runtime-ingredients.sh --output ABSOLUTE_DIR --kernel-inputs ABSOLUTE_DIR --swift-sdk ABSOLUTE_FILE --swift-sdk-sha256 SHA256" 64; }

output= kernel_inputs= swift_sdk= swift_sdk_sha=
while (( $# )); do
  case "$1" in
    --output) (( $# >= 2 )) || usage; output=$2; shift 2 ;;
    --kernel-inputs) (( $# >= 2 )) || usage; kernel_inputs=$2; shift 2 ;;
    --swift-sdk) (( $# >= 2 )) || usage; swift_sdk=$2; shift 2 ;;
    --swift-sdk-sha256) (( $# >= 2 )) || usage; swift_sdk_sha=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$output" == /* && "$kernel_inputs" == /* && "$swift_sdk" == /* && "$swift_sdk_sha" =~ ^[a-f0-9]{64}$ ]] || usage
[[ ! -e "$output" && ! -L "$output" ]] || die "runtime ingredient output already exists"
[[ -f "$swift_sdk" && ! -L "$swift_sdk" ]] || die "missing regular source-built Swift SDK archive"
[[ "$(sha256sum "$swift_sdk" | awk '{print $1}')" == "$swift_sdk_sha" ]] || die "Swift SDK archive digest mismatch"
[[ "$(uname -s)" == Linux && "$(uname -m)" == aarch64 ]] || die "runtime ingredients require Linux arm64" 69
for tool in aarch64-linux-gnu-gcc bison clang flex gcc git jq ld.lld make python3 sha256sum swift swiftly yq; do command -v "$tool" >/dev/null || die "missing producer tool: $tool" 69; done
[[ "$(swift --version | head -1)" == *"Swift version 6.3"* ]] || die "runtime ingredients require Swift 6.3" 69

# Swiftly stores toolchains separately from its configuration directory.
swift_toolchain=$(swiftly use --print-location)
[[ "$swift_toolchain" == /* && -d "$swift_toolchain" ]] || die "missing selected Swiftly toolchain"
swift_toolchain=$(readlink -f "$swift_toolchain")
swift_bin="$swift_toolchain/usr/bin/swift"
swiftc_bin="$swift_toolchain/usr/bin/swiftc"
swift_real=$(readlink -f "$swift_bin")
swiftc_real=$(readlink -f "$swiftc_bin")
for real in "$swift_real" "$swiftc_real"; do
  [[ "$real" == "$swift_toolchain/"* && -f "$real" && -x "$real" ]] \
    || die "Swift entrypoint resolves outside the verified toolchain"
done

for name in linux-6.18.15.tar.xz linux-6.18.15.tar.sign gregkh-pinned-public-key.asc; do
  [[ -f "$kernel_inputs/$name" && ! -L "$kernel_inputs/$name" ]] || die "missing retained kernel input: $name"
done
[[ "$(sha256sum "$kernel_inputs/linux-6.18.15.tar.xz" | awk '{print $1}')" == "$kernel_source_sha" ]] \
  || die "kernel source differs from the exact pin"

parent=$(dirname "$output")
[[ -d "$parent" && ! -L "$parent" ]] || die "runtime ingredient output parent is unsafe"
work=$(mktemp -d "$parent/.runtime-ingredients.XXXXXXXX")
cleanup() {
  status=$?
  trap - EXIT
  if [[ -d "$work" && ! -L "$work" ]]; then
    if (( status != 0 )); then
      for log in "$work"/evidence/*.log; do
        [[ -f "$log" && ! -L "$log" ]] || continue
        tail -n 80 "$log" >&2
      done
    fi
    find "$work" -depth -delete
  fi
  exit "$status"
}
trap cleanup EXIT
mkdir -m 700 "$work/evidence" "$work/payloads" "$work/sources"
mkdir -m 700 "$work/evidence/source-trees"

python3 scripts/release/verify-kernel-source-signature.py \
  --inputs "$kernel_inputs" --output "$work/evidence/kernel-source-signature.json"

git clone --filter=blob:none https://github.com/kata-containers/kata-containers.git "$work/sources/kata"
git -C "$work/sources/kata" checkout --detach "$kata_commit"
test "$(git -C "$work/sources/kata" rev-parse HEAD)" = "$kata_commit"
test "$(cat "$work/sources/kata/tools/packaging/kernel/kata_config_version")" = "$kernel_config_version"
git -C "$work/sources/kata" archive --format=tar "$kata_commit" | gzip -n > "$work/evidence/kata-source.tar.gz"
python3 "$source_capture" --repository "$work/sources/kata" --commit "$kata_commit" \
  --output "$work/evidence/source-trees/kata"

export KBUILD_BUILD_TIMESTAMP="$build_time" KBUILD_BUILD_USER=hostwright KBUILD_BUILD_HOST=github-arm64
export KBUILD_BUILD_VERSION=1 SOURCE_DATE_EPOCH=1767225600
export KCFLAGS="-fdebug-prefix-map=$work=/hostwright-runtime-build" KAFLAGS="-fdebug-prefix-map=$work=/hostwright-runtime-build"
for pass in first second; do
  root="$work/kernel-build"
  if [[ -e "$root" ]]; then
    [[ -d "$root" && ! -L "$root" ]] || die "unsafe previous kernel build tree"
    find "$root" -depth -delete
  fi
  mkdir -m 700 "$root"
  cp -a "$work/sources/kata" "$root/kata"
  (
    cd "$root/kata/tools/packaging/kernel"
    bash -x ./build-kernel.sh -a aarch64 -v "$kernel_version" -u "file://$kernel_inputs/" -f setup
    test -d "kata-linux-$kernel_version-$kernel_config_version"
    cp "kata-linux-$kernel_version-$kernel_config_version/.config" "$work/evidence/kernel-$pass.config"
    bash -x ./build-kernel.sh -a aarch64 -v "$kernel_version" build
    cp "kata-linux-$kernel_version-$kernel_config_version/arch/arm64/boot/Image" "$work/kernel-$pass.Image"
  ) >"$work/evidence/kernel-$pass.log" 2>&1
done
cmp "$work/kernel-first.Image" "$work/kernel-second.Image"
install -m 0644 "$work/kernel-first.Image" "$work/payloads/vmlinux-$kernel_version-$kernel_config_version"

git clone --filter=blob:none https://github.com/apple/containerization.git "$work/sources/containerization"
git -C "$work/sources/containerization" checkout --detach "$containerization_commit"
test "$(git -C "$work/sources/containerization" rev-parse HEAD)" = "$containerization_commit"
git -C "$work/sources/containerization" archive --format=tar "$containerization_commit" | gzip -n > "$work/evidence/containerization-source.tar.gz"
python3 "$source_capture" --repository "$work/sources/containerization" --commit "$containerization_commit" \
  --output "$work/evidence/source-trees/containerization"
cp "$swift_sdk" "$work/swift-static-sdk.tar.gz"
printf '%s  %s\n' "$swift_sdk_sha" "$work/swift-static-sdk.tar.gz" | sha256sum --check --status
swift sdk install "$work/swift-static-sdk.tar.gz" --checksum "$swift_sdk_sha"
mv "$work/swift-static-sdk.tar.gz" "$work/evidence/swift-static-sdk.tar.gz"
mkdir -m 700 "$work/evidence/kernel-inputs"
cp "$kernel_inputs/linux-6.18.15.tar.xz" "$kernel_inputs/linux-6.18.15.tar.sign" \
  "$kernel_inputs/gregkh-pinned-public-key.asc" "$work/evidence/kernel-inputs/"

export GIT_COMMIT="$containerization_commit" GIT_TAG=0.35.0 BUILD_TIME="$build_time" SOURCE_DATE_EPOCH=1767225600
cp scripts/release/patches/containerization-guest-security.patch "$work/evidence/"
for pass in first second; do
  tree="$work/containerization-build"
  if [[ -e "$tree" ]]; then
    [[ -d "$tree" && ! -L "$tree" ]] || die "unsafe previous runtime build tree"
    find "$tree" -depth -delete
  fi
  git clone --shared "$work/sources/containerization" "$tree"
  git -C "$tree" checkout --detach "$containerization_commit"
  git -C "$tree" apply --check "$work/evidence/containerization-guest-security.patch"
  git -C "$tree" apply "$work/evidence/containerization-guest-security.patch"
  (
    cd "$tree/vminitd"
    # Header timestamps otherwise change Clang module signatures and Swift object hashes.
    swift build -v -c release --swift-sdk aarch64-swift-linux-musl --disable-automatic-resolution \
      -Xcc -Xclang -Xcc -fno-pch-timestamp \
      --product vminitd -Xlinker -s -Xlinker -Map="$work/evidence/vminitd-$pass.map"
    swift build -v -c release --swift-sdk aarch64-swift-linux-musl --disable-automatic-resolution \
      -Xcc -Xclang -Xcc -fno-pch-timestamp \
      --product vmexec -Xlinker -s -Xlinker -Map="$work/evidence/vmexec-$pass.map"
    bin=$(swift build -c release --swift-sdk aarch64-swift-linux-musl --disable-automatic-resolution --show-bin-path)
    cp "$bin/vminitd" "$work/vminitd-$pass"
    cp "$bin/vmexec" "$work/vmexec-$pass"
    find .build -type f \( -name '*.a' -o -name '*.o' -o -name '*.resp' -o -name '*.rsp' \
      -o -name '*.LinkFileList' -o -name '*.autolink' -o -name sources \
      -o -name output-file-map.json -o -name description.json -o -name release.yaml \) -print0 \
      | sort -z | tar --null -T - --sort=name --mtime=@1767225600 --owner=0 --group=0 --numeric-owner -cf - \
      | gzip -n > "$work/evidence/vminit-link-inputs-$pass.tar.gz"
    if [[ "$pass" == first ]]; then
      cp Package.resolved "$work/evidence/vminit-Package.resolved"
      python3 "$package_capture" --lockfile Package.resolved --checkouts .build/checkouts \
        --output "$work/evidence/source-trees/vminit-packages"
    fi
  ) >"$work/evidence/vminit-$pass.log" 2>&1
done
cmp "$work/vminitd-first" "$work/vminitd-second"
cmp "$work/vmexec-first" "$work/vmexec-second"
install -m 0755 "$work/vminitd-first" "$work/payloads/vminitd"
install -m 0755 "$work/vmexec-first" "$work/payloads/vmexec"

for pass in first second; do
  python3 scripts/release/create-runtime-rootfs.py \
    --vminitd "$work/vminitd-$pass" --vmexec "$work/vmexec-$pass" \
    --output "$work/vminit-$pass.rootfs.tar.gz" \
    >"$work/evidence/rootfs-$pass.log" 2>&1
done
cmp "$work/vminit-first.rootfs.tar.gz" "$work/vminit-second.rootfs.tar.gz"
python3 scripts/release/create-runtime-oci.py \
  --layer "$work/vminit-first.rootfs.tar.gz" --output "$work/payloads/vminit"

cp "$(command -v clang)" "$work/evidence/clang"
cp "$(command -v ld.lld)" "$work/evidence/ld.lld"
cp "$swift_real" "$work/evidence/swift"
cp "$swiftc_real" "$work/evidence/swiftc"
printf '%s\n' "$swift_bin -> $swift_real" > "$work/evidence/swift-entrypoint.txt"
printf '%s\n' "$swiftc_bin -> $swiftc_real" > "$work/evidence/swiftc-entrypoint.txt"
cp "$(command -v gcc)" "$work/evidence/gcc"
cp "$(command -v aarch64-linux-gnu-gcc)" "$work/evidence/aarch64-linux-gnu-gcc"
clang --version > "$work/evidence/clang.version"
ld.lld --version > "$work/evidence/ld.lld.version"
swift --version > "$work/evidence/swift.version"
swift -print-target-info > "$work/evidence/swift-target-info.json"
gcc --version > "$work/evidence/gcc.version"
aarch64-linux-gnu-gcc --version > "$work/evidence/aarch64-linux-gnu-gcc.version"
python3 - "$work/evidence/build-environment.json" <<'PY'
import json, os, platform, sys
allowed = ['BUILD_TIME','GIT_COMMIT','GIT_TAG','KBUILD_BUILD_HOST','KBUILD_BUILD_TIMESTAMP',
           'KBUILD_BUILD_USER','KBUILD_BUILD_VERSION','KCFLAGS','KAFLAGS','SOURCE_DATE_EPOCH','SWIFTLY_HOME_DIR']
value = {'environment': {name: os.environ[name] for name in allowed if name in os.environ},
         'machine': platform.machine(), 'system': platform.system(), 'release': platform.release()}
with open(sys.argv[1], 'x', encoding='utf-8') as stream:
    json.dump(value, stream, sort_keys=True, separators=(',', ':')); stream.write('\n')
PY
(cd "$work"; find payloads evidence -type f -print0 | sort -z | xargs -0 sha256sum) > "$work/checksums.sha256"
mv "$work" "$output"
trap - EXIT
printf 'runtime build ingredients prepared: %s\n' "$output"
