#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

python3 scripts/check-doc-links.py README.md docs
python3 scripts/check-current-truth.py

swift build --jobs 1 --product hostwright
swift build --jobs 1 --product hostwright-control
bin_dir="$(swift build --show-bin-path)"
hostwright="$bin_dir/hostwright"
control="$bin_dir/hostwright-control"

"$hostwright" --version >/dev/null
"$hostwright" --help >/dev/null

for manifest in examples/*/hostwright.yaml; do
  request_id="docs-${manifest//[^A-Za-z0-9]/-}"
  printf '{"apiVersion":2,"requestID":"%s","operation":"plan"}\n' "$request_id" \
    | "$control" --manifest "$root/$manifest" \
    | /usr/bin/jq -e --arg request_id "$request_id" \
      '.apiVersion == 2 and .requestID == $request_id and .operation == "plan" and .success == true' \
      >/dev/null
done

echo "documentation quickstarts: local help/version and revision-2.0 plan compatibility validated every example manifest"
