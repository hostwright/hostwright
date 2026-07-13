#!/usr/bin/env bash
set -euo pipefail

swift build
swift test
scripts/integration.sh
python3 scripts/roadmap-governance.py validate
python3 scripts/roadmap-governance.py self-test
python3 scripts/render-roadmap-index.py check
python3 scripts/check-current-truth.py
scripts/check-docs.sh
