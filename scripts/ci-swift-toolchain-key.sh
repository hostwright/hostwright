#!/usr/bin/env bash
set -euo pipefail

swift_version=$(swift --version 2>&1)
xcode_version=$(xcodebuild -version 2>&1)
key=$(printf '%s\0%s\0' "$swift_version" "$xcode_version" | shasum -a 256 | cut -d ' ' -f 1)
printf 'hash=%s\n' "$key" >> "$GITHUB_OUTPUT"
