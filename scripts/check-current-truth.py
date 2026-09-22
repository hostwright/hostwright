#!/usr/bin/env python3
"""Fail when current-main release, contract, or immutable-history truth drifts."""

from __future__ import annotations

import hashlib
import json
import re
import sys
import subprocess
import tempfile
from pathlib import Path


PINNED_FILES = globals().get("HOSTWRIGHT_QUALIFICATION_FILES")
PINNED_ENTRIES = globals().get("HOSTWRIGHT_QUALIFICATION_ENTRIES")
if (PINNED_FILES is None) != (PINNED_ENTRIES is None):
    raise RuntimeError("incomplete qualification source snapshot")
ROOT = Path(".") if PINNED_FILES is not None else Path(__file__).resolve().parents[1]
EVIDENCE_CLASSES = [
    "unit-contract",
    "local-integration",
    "live-runtime",
    "hardware-benchmark",
    "distribution-artifact",
    "migration-upgrade",
    "security-assessment",
    "resilience-chaos",
    "multi-host",
    "interop-conformance",
    "ux-accessibility",
]
PHASE_SCHEDULE = [
    {"phase": phase, "targetDate": f"2026-07-{phase + 12:02d}"}
    for phase in range(1, 16)
]


def read_bytes(path: str) -> bytes:
    if PINNED_FILES is not None:
        try:
            return PINNED_FILES[path]
        except KeyError as error:
            raise RuntimeError(f"qualification source snapshot lacks {path}") from error
    return (ROOT / path).read_bytes()


def read(path: str) -> str:
    return read_bytes(path).decode("utf-8")


def require(condition: bool, message: str, errors: list[str]) -> None:
    if not condition:
        errors.append(message)


def validate_examples(errors: list[str]) -> None:
    inputs = PINNED_FILES if PINNED_FILES is not None else subprocess.check_output(
        ["git", "-C", str(ROOT), "ls-files", "-z"], text=True
    ).split("\0")
    example_paths = sorted(
        path for path in inputs
        if re.fullmatch(r"examples/[^/]+/hostwright\.yaml", path)
    )
    require(bool(example_paths), "no executable manifest examples found", errors)
    for path in example_paths:
        content = read(path)
        require(re.search(r"(?m)^version:\s*3\s*$", content) is not None, f"{path} is not Manifest v3", errors)


def main() -> int:
    errors: list[str] = []
    identity = read("Sources/HostwrightCore/HostwrightIdentity.swift")
    contracts = read("Sources/HostwrightCore/ContractVersions.swift")
    evidence_models = read("Sources/HostwrightCore/EvidenceModels.swift")

    version_match = re.search(r'version = "(0\.0\.2(?:-dev\.[1-9][0-9]{0,2}|-rc\.[1-9][0-9]?)?)"', identity)
    require(version_match is not None, "HostwrightIdentity version is not a supported v0.0.2 release channel", errors)
    if version_match is not None:
        version_golden = json.loads(read("contracts/v0.0.2/versions.json"))
        require(
            version_golden.get("productVersion") == version_match.group(1),
            "HostwrightIdentity and the version golden disagree",
            errors,
        )
        require(
            version_golden.get("stateSchema") == 24,
            "version golden stateSchema does not match the current schema authority",
            errors,
        )
    require('releaseTarget = "v0.0.2"' in identity, "HostwrightIdentity release target is not v0.0.2", errors)
    for fragment in ["manifest = 3", "controlAPI = 2", "runtimeProviderAPI = 2", "storageProviderAPI = 1", "pluginABI = 1", "stateSchema = 24"]:
        require(fragment in contracts, f"missing contract truth: {fragment}", errors)

    schema = json.loads(read("schemas/hostwright-yaml.schema.json"))
    version_schema = schema.get("properties", {}).get("version", {})
    require(version_schema.get("const") == 3, "manifest JSON schema version is not const 3", errors)
    require("version" in schema.get("required", []), "manifest JSON schema does not require version", errors)

    model_evidence_classes = re.findall(r'case\s+\w+\s*=\s*"([a-z-]+)"', evidence_models.split("public enum HostwrightEvidenceStatus", 1)[0])
    evidence_schema = json.loads(read("schemas/hostwright-evidence.schema.json"))
    schema_evidence_classes = evidence_schema.get("properties", {}).get("evidenceClass", {}).get("enum")
    issue_manifest = json.loads(read("docs/roadmap/v0.0.2/issues.json"))
    require(model_evidence_classes == EVIDENCE_CLASSES, "Swift evidence classes drifted from the v0.0.2 constitution", errors)
    require(schema_evidence_classes == EVIDENCE_CLASSES, "evidence schema classes drifted from the v0.0.2 constitution", errors)
    require(issue_manifest.get("evidenceClasses") == EVIDENCE_CLASSES, "roadmap issue evidence classes drifted from the v0.0.2 constitution", errors)
    require(
        issue_manifest.get("historicalPhaseSchedule") == PHASE_SCHEDULE,
        "historical roadmap phase schedule must preserve daily targets from 2026-07-13 through 2026-07-27",
        errors,
    )

    validate_examples(errors)

    immutable = json.loads(read("docs/release/IMMUTABLE_RELEASES.json"))
    require(immutable.get("schemaVersion") == 1, "immutable release manifest schema is invalid", errors)
    for record in immutable.get("files", []):
        digest = hashlib.sha256(read_bytes(record["path"])).hexdigest()
        require(digest == record["sha256"], f"immutable historical release changed: {record['path']}", errors)

    if errors:
        for error in errors:
            print(f"current truth check failed: {error}", file=sys.stderr)
        return 1
    print("current truth check: v0.0.2 contracts, examples, and immutable history agree")
    return 0


def self_test() -> int:
    global ROOT, PINNED_FILES, PINNED_ENTRIES
    previous = ROOT, PINNED_FILES, PINNED_ENTRIES
    try:
        with tempfile.TemporaryDirectory(prefix="hostwright-tracked-examples-") as directory:
            ROOT = Path(directory)
            subprocess.run(["git", "init", "--quiet", directory], check=True)
            tracked = ROOT / "examples/checked-in/hostwright.yaml"
            tracked.parent.mkdir(parents=True)
            tracked.write_text("version: 2\n", encoding="utf-8")
            subprocess.run(["git", "-C", directory, "add", "examples"], check=True)
            errors: list[str] = []
            validate_examples(errors)
            assert errors == ["examples/checked-in/hostwright.yaml is not Manifest v3"], errors
            tracked.write_text("version: 3\n", encoding="utf-8")
            untracked = ROOT / "examples/demo/hostwright.yaml"
            untracked.parent.mkdir(parents=True)
            untracked.write_text("version: 2\n", encoding="utf-8")
            errors = []
            validate_examples(errors)
            assert not errors, errors
            PINNED_FILES = {"examples/explicit/hostwright.yaml": b"version: 2\n"}
            PINNED_ENTRIES = {}
            errors = []
            validate_examples(errors)
            assert errors == ["examples/explicit/hostwright.yaml is not Manifest v3"], errors
    finally:
        ROOT, PINNED_FILES, PINNED_ENTRIES = previous
    print("current truth self-test: tracked failures, working-tree edits, untracked isolation, explicit snapshots passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(self_test() if sys.argv[1:] == ["--self-test"] else main())
