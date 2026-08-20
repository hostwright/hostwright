#!/usr/bin/env bash
set -euo pipefail

swift package dump-package | python3 scripts/check-shipped-process-boundary.py
python3 scripts/check-shipped-process-boundary.py --self-test
