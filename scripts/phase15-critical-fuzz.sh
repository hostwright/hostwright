#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
duration_seconds="${HOSTWRIGHT_FUZZ_DURATION_SECONDS:-300}"
evidence_root="${HOSTWRIGHT_FUZZ_EVIDENCE_ROOT:?set HOSTWRIGHT_FUZZ_EVIDENCE_ROOT to an absolute directory}"

case "$duration_seconds" in
    ''|*[!0-9]*) printf '%s\n' "fuzz duration must be a positive integer" >&2; exit 64 ;;
esac
if (( duration_seconds < 1 )); then
    printf '%s\n' "fuzz duration must be a positive integer" >&2
    exit 64
fi
case "$evidence_root" in
    /*) ;;
    *) printf '%s\n' "fuzz evidence root must be absolute" >&2; exit 64 ;;
esac

llvm_prefix="$(brew --prefix llvm)"
llvm_version="$($llvm_prefix/bin/clang --version | head -1)"
llvm_major="$($llvm_prefix/bin/clang -dumpversion | cut -d. -f1)"
fuzzer_runtime="$llvm_prefix/lib/clang/$llvm_major/lib/darwin/libclang_rt.fuzzer_no_main_osx.a"
if [[ ! -f "$fuzzer_runtime" ]]; then
    printf 'libFuzzer runtime is unavailable at %s\n' "$fuzzer_runtime" >&2
    exit 69
fi

source_commit="$(git -C "$repository_root" rev-parse HEAD)"
mkdir -p "$evidence_root/build" "$evidence_root/corpora" "$evidence_root/logs" "$evidence_root/artifacts"

swift build \
    --package-path "$repository_root" \
    --scratch-path "$evidence_root/build" \
    --product hostwright-critical-fuzzer \
    --configuration debug \
    --jobs 1 \
    --sanitize address \
    -Xswiftc -sanitize-coverage=edge,inline-8bit-counters,pc-table \
    -Xlinker -force_load \
    -Xlinker "$fuzzer_runtime" \
    -Xlinker -lc++ \
    2>&1 | tee "$evidence_root/logs/build.log"

binary="$evidence_root/build/arm64-apple-macosx/debug/hostwright-critical-fuzzer"
targets=(
    manifest-v3
    compose-import
    control-stream-v2.1
    containerization-helper-v1
    apple-container-json
    release-qualification-json
)

for target in "${targets[@]}"; do
    corpus="$evidence_root/corpora/$target"
    mkdir -p "$corpus"
    cp -R "$repository_root/Tests/HostwrightCriticalFuzzer/Corpus/$target/." "$corpus/"
    HOSTWRIGHT_FUZZ_TARGET="$target" "$binary" \
        -artifact_prefix="$evidence_root/artifacts/$target-" \
        -max_len=1048576 \
        -max_total_time="$duration_seconds" \
        -print_final_stats=1 \
        "$corpus" \
        2>&1 | tee "$evidence_root/logs/$target.log"
done

python3 - "$evidence_root" "$source_commit" "$duration_seconds" "$llvm_version" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
commit = sys.argv[2]
duration = int(sys.argv[3])
llvm_version = sys.argv[4]
targets = [
    "manifest-v3", "compose-import", "control-stream-v2.1",
    "containerization-helper-v1", "apple-container-json",
    "release-qualification-json",
]

receipts = []
for target in targets:
    log = root / "logs" / f"{target}.log"
    corpus = root / "corpora" / target
    data = log.read_bytes()
    text = data.decode("utf-8", errors="replace")
    if "DONE" not in text or "stat::number_of_executed_units:" not in text:
        raise SystemExit(f"incomplete libFuzzer evidence for {target}")
    files = []
    for path in sorted(item for item in corpus.iterdir() if item.is_file()):
        payload = path.read_bytes()
        files.append({
            "name": path.name,
            "sha256": hashlib.sha256(payload).hexdigest(),
            "sizeBytes": len(payload),
        })
    receipts.append({
        "target": target,
        "durationSeconds": duration,
        "logSHA256": hashlib.sha256(data).hexdigest(),
        "corpus": files,
    })

receipt = {
    "kind": "hostwright.phase15.critical-fuzz.v1",
    "schemaVersion": 1,
    "status": "passed",
    "sourceCommit": commit,
    "llvmVersion": llvm_version,
    "sanitizer": "address",
    "coverage": "edge,inline-8bit-counters,pc-table",
    "targets": receipts,
}
(root / "complete.json").write_text(
    json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY

printf 'phase15 critical fuzz qualification passed: %s\n' "$evidence_root"
