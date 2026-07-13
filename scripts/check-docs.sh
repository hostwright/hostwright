#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

python3 scripts/check-doc-links.py README.md docs
python3 scripts/check-current-truth.py

swift build --product hostwright
bin_dir="$(swift build --show-bin-path)"
hostwright="$bin_dir/hostwright"

for manifest in examples/*/hostwright.yaml; do
  "$hostwright" validate "$manifest" >/dev/null
  "$hostwright" plan "$manifest" --output json >/dev/null
done

echo "documentation quickstarts: validated and planned every example manifest"
