#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repository_root"

swift package dump-package >/dev/null
swift build --jobs 1 --product hostwright-release-qualify
swift test --jobs 1 --filter HostwrightReleaseQualificationTests

python3 -c '
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open(encoding="utf-8") as handle:
    document = json.load(handle)
if document.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
    raise SystemExit("release qualification schema has an unexpected dialect")
if document.get("$id") != "https://hostwright.dev/schemas/hostwright-release-qualification.schema.json":
    raise SystemExit("release qualification schema has an unexpected identity")
' schemas/hostwright-release-qualification.schema.json

swift run --jobs 1 hostwright-release-qualify plan --root "$repository_root" \
    | python3 -c '
import json
import sys

document = json.load(sys.stdin)
if document.get("kind") != "hostwright.release-qualification.plan.v1":
    raise SystemExit("release qualification plan kind is invalid")
if document.get("schemaVersion") != 1:
    raise SystemExit("release qualification plan schema version is invalid")
'

git diff --check
printf '%s\n' "phase15 release qualification focused checks passed"
