#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
evidence_root="${HOSTWRIGHT_SAST_EVIDENCE_ROOT:?set HOSTWRIGHT_SAST_EVIDENCE_ROOT to an absolute directory}"
case "$evidence_root" in
    /*) ;;
    *) printf '%s\n' "SAST evidence root must be absolute" >&2; exit 64 ;;
esac

source_commit="$(git -C "$repository_root" rev-parse HEAD)"
test -z "$(git -C "$repository_root" status --porcelain=v1 --untracked-files=all)"
python3 - "$repository_root" "$evidence_root" <<'PY'
import pathlib
import sys
source = pathlib.Path(sys.argv[1]).resolve()
evidence = pathlib.Path(sys.argv[2])
if evidence.is_symlink() or evidence.exists() or source == evidence.resolve() or source in evidence.resolve().parents:
    raise SystemExit('SAST requires a new evidence directory outside the clean checkout')
evidence.mkdir(mode=0o700, parents=True)
PY
semgrep_version="$(semgrep --version)"

semgrep scan \
    --config "$repository_root/contracts/v0.0.2/security/semgrep-hostwright.yml" \
    --config "$repository_root/contracts/v0.0.2/security/semgrep-swift.json" \
    --metrics off \
    --json \
    --output "$evidence_root/semgrep.json" \
    "$repository_root/Sources" "$repository_root/scripts" \
    >"$evidence_root/semgrep.stdout.log" 2>"$evidence_root/semgrep.stderr.log"

python3 - "$evidence_root" "$source_commit" "$semgrep_version" "$repository_root" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
commit = sys.argv[2]
semgrep_version = sys.argv[3]
source = pathlib.Path(sys.argv[4])
if (subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() != commit
        or subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain=v1', '--untracked-files=all'], text=True).strip()
        or subprocess.check_output(['semgrep', '--version'], text=True).strip() != semgrep_version):
    raise SystemExit('source or scanner changed during SAST qualification')
version = json.loads((source / 'contracts/v0.0.2/versions.json').read_text())['productVersion']
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
    "version": version,
    "executionMode": "real",
    "sourceCleanBefore": True,
    "sourceCleanAfter": True,
    "blockers": [],
    "failures": [],
    "semgrepVersion": semgrep_version,
    "attachments": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in root.iterdir() if p.is_file()},
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
