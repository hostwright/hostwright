#!/usr/bin/env bash
set -euo pipefail

command=$1
shift
if [[ "${HOSTWRIGHT_CI_SWIFT_INPUT_HASHING:-false}" == true ]]; then
  exec swift "$command" -Xswiftc -enable-incremental-file-hashing "$@"
fi
exec swift "$command" "$@"
