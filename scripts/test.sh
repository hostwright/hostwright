#!/usr/bin/env bash
set -euo pipefail

swift build
swift test
scripts/integration.sh
