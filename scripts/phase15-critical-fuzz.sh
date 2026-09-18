#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
exec python3 "$repository_root/scripts/release/qualification-lanes.py" fuzz \
  --source "$repository_root" \
  --evidence "${HOSTWRIGHT_FUZZ_EVIDENCE_ROOT:?set HOSTWRIGHT_FUZZ_EVIDENCE_ROOT to an absolute directory}" \
  --duration "${HOSTWRIGHT_FUZZ_DURATION_SECONDS:-300}"
