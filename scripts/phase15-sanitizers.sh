#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
exec python3 "$repository_root/scripts/release/qualification-lanes.py" sanitizers \
  --source "$repository_root" \
  --evidence "${HOSTWRIGHT_SANITIZER_EVIDENCE_ROOT:?set HOSTWRIGHT_SANITIZER_EVIDENCE_ROOT to an absolute directory}"
