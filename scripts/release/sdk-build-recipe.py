#!/usr/bin/env python3
"""Identify compiler inputs independently of the Hostwright application commit."""
import hashlib
import json
from pathlib import Path


FILES = (
    "scripts/release/build-static-swift-sdk.sh",
    "scripts/release/materialize-swift-sdk-sources.py",
    "scripts/release/runtime-swift-sources.json",
)
WORKFLOW = ".github/workflows/runtime-ingredients.yml"
BUILD_JOB = "  source-built-swift-sdk:\n"
CHECKPOINT_STEP = "      - name: Capture the reusable SDK build checkpoint\n"


def fingerprint(root):
    root = Path(root).resolve(strict=True)
    paths = list(FILES)
    patches = root / "scripts/release/patches/swift-sdk"
    paths.extend(path.relative_to(root).as_posix() for path in sorted(patches.rglob("*")) if path.is_file())
    if len(paths) == len(FILES):
        raise ValueError("SDK build patches are missing")
    hashes = {}
    for name in paths + [WORKFLOW]:
        path = root / name
        if path.is_symlink() or not path.resolve(strict=True).is_relative_to(root):
            raise ValueError("unsafe SDK recipe input: " + name)
        data = path.read_bytes()
        if name == WORKFLOW:
            text = data.decode("utf-8")
            if text.count(BUILD_JOB) != 1 or text.count(CHECKPOINT_STEP) != 1:
                raise ValueError("SDK compilation boundary is missing or ambiguous")
            header, jobs = text.split("jobs:\n", 1)
            job = jobs.split(BUILD_JOB, 1)[1].split(CHECKPOINT_STEP, 1)[0]
            if "\n  " in job and any(line.startswith("  ") and not line.startswith("    ") for line in job.splitlines()):
                raise ValueError("checkpoint is outside the SDK compilation job")
            data = (header + BUILD_JOB + job).encode("utf-8")
        hashes[name] = hashlib.sha256(data).hexdigest()
    encoded = json.dumps(hashes, sort_keys=True, separators=(",", ":")).encode()
    return {"kind": "hostwright.swift-sdk-build-recipe.v1", "sha256": hashlib.sha256(encoded).hexdigest(),
            "inputs": hashes}
