#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
evidence_root="${HOSTWRIGHT_SAST_EVIDENCE_ROOT:?set HOSTWRIGHT_SAST_EVIDENCE_ROOT to an absolute directory}"
case "$evidence_root" in
    /*) ;;
    *) printf '%s\n' "SAST evidence root must be absolute" >&2; exit 64 ;;
esac

source_commit="$(git -C "$repository_root" rev-parse HEAD)"
mkdir -p "$evidence_root"

semgrep scan \
    --config "$repository_root/contracts/v0.0.2/security/semgrep-hostwright.yml" \
    --config "$repository_root/contracts/v0.0.2/security/semgrep-swift.json" \
    --metrics off \
    --json \
    --output "$evidence_root/semgrep.json" \
    "$repository_root/Sources" "$repository_root/scripts" \
    2>"$evidence_root/semgrep.stderr.log"

python3 - "$evidence_root" "$source_commit" "$(semgrep --version)" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
commit = sys.argv[2]
version = sys.argv[3]
result_path = root / "semgrep.json"
result_bytes = result_path.read_bytes()
results = json.loads(result_bytes)
findings = results.get("results", [])
errors = results.get("errors", [])
blocking_errors = [item for item in errors if item.get("level") not in {"warn", "info"}]
if findings:
    raise SystemExit(f"Semgrep reported {len(findings)} finding(s)")
if blocking_errors:
    raise SystemExit(f"Semgrep reported {len(blocking_errors)} blocking scan error(s)")

receipt = {
    "kind": "hostwright.phase15.sast.v1",
    "schemaVersion": 1,
    "status": "passed",
    "sourceCommit": commit,
    "semgrepVersion": version,
    "findingCount": 0,
    "warningCount": len(errors),
    "warningTypes": sorted({
        str(item.get("type", ["unknown"])[0])
        if isinstance(item.get("type"), list)
        else str(item.get("type", "unknown"))
        for item in errors
    }),
    "resultSHA256": hashlib.sha256(result_bytes).hexdigest(),
}
(root / "complete.json").write_text(
    json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY

printf 'phase15 SAST qualification passed: %s\n' "$evidence_root"
