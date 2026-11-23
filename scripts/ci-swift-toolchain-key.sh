#!/usr/bin/env bash
set -euo pipefail

swift_version=$(swift --version)
xcode_version=$(xcodebuild -version)
key=$(printf '%s\n%s\n' "$swift_version" "$xcode_version" | shasum -a 256 | cut -d ' ' -f 1)
printf 'hash=%s\n' "$key" >> "$GITHUB_OUTPUT"
