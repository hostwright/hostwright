#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"

echo "Scanning for historical Orchard terms under: $ROOT"
echo "Allowed matches: docs/source-material preservation logs/originals and docs/naming decision/history files."
echo

if command -v rg >/dev/null 2>&1; then
  rg -n --hidden --glob '!.git' --glob '!.build' --glob '!*.pdf' --glob '!*.docx' --glob '!*.zip' \
    '\bOrchard\b|\borchard\b|orchardd|orchard\.yaml|orchard\.cc' "$ROOT" \
    | grep -v 'grep-orchard.sh' || true
else
  grep -RInE '\bOrchard\b|\borchard\b|orchardd|orchard\.yaml|orchard\.cc' "$ROOT" \
    --exclude-dir=.git \
    --exclude-dir=.build \
    --exclude='*.pdf' \
    --exclude='*.docx' \
    --exclude='*.zip' \
    | grep -v 'grep-orchard.sh' \
    || true
fi
