#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
evidence_root="${HOSTWRIGHT_SANITIZER_EVIDENCE_ROOT:?set HOSTWRIGHT_SANITIZER_EVIDENCE_ROOT to an absolute directory}"
test_filter="${HOSTWRIGHT_SANITIZER_TEST_FILTER:-}"

case "$evidence_root" in
    /*) ;;
    *) printf '%s\n' "sanitizer evidence root must be absolute" >&2; exit 64 ;;
esac

source_commit="$(git -C "$repository_root" rev-parse HEAD)"
mkdir -p "$evidence_root/logs"

run_lane() {
    local sanitizer="$1"
    local scratch="$evidence_root/$sanitizer-build"
    local arguments=(
        test
        --package-path "$repository_root"
        --scratch-path "$scratch"
        --sanitize "$sanitizer"
        --jobs 1
    )
    if [[ -n "$test_filter" ]]; then
        arguments+=(--filter "$test_filter")
    fi
    swift "${arguments[@]}" 2>&1 | tee "$evidence_root/logs/$sanitizer.log"
}

run_lane address
run_lane thread

python3 - "$evidence_root" "$source_commit" "$test_filter" "$(swift --version | head -1)" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
commit = sys.argv[2]
test_filter = sys.argv[3]
swift_version = sys.argv[4]
lanes = []
for sanitizer in ("address", "thread"):
    log = root / "logs" / f"{sanitizer}.log"
    data = log.read_bytes()
    text = data.decode("utf-8", errors="replace")
    if "Test Suite 'All tests' passed" not in text and "Test run with" not in text:
        raise SystemExit(f"sanitizer test completion marker missing for {sanitizer}")
    lanes.append({
        "sanitizer": sanitizer,
        "logSHA256": hashlib.sha256(data).hexdigest(),
        "testFilter": test_filter or None,
    })

receipt = {
    "kind": "hostwright.phase15.sanitizers.v1",
    "schemaVersion": 1,
    "status": "passed",
    "sourceCommit": commit,
    "swiftVersion": swift_version,
    "lanes": lanes,
}
(root / "complete.json").write_text(
    json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY

printf 'phase15 sanitizer qualification passed: %s\n' "$evidence_root"
