#!/usr/bin/env bash
set -euo pipefail

if [[ ${#SWIFTPM_LOCK_HASH} -ne 64 || "$SWIFTPM_LOCK_HASH" == *[!0-9a-f]* ]]; then
  echo 'A valid Package.resolved hash is required for the SwiftPM cache key.' >&2
  exit 1
fi
swift_version=$(swift --version 2>&1)
xcode_version=$(xcodebuild -version 2>&1)
toolchain_hash=$(printf '%s\0%s\0' "$swift_version" "$xcode_version" | shasum -a 256 | cut -d ' ' -f 1)
# Keep test products in a separate namespace from package-only builds.
namespace="${SWIFTPM_CACHE_NAMESPACE:-spm-v1}"
prefix="$namespace-$RUNNER_OS-$RUNNER_ARCH-$toolchain_hash-"
printf 'prefix=%s\nkey=%s%s\n' "$prefix" "$prefix" "$SWIFTPM_LOCK_HASH" >> "$GITHUB_OUTPUT"
