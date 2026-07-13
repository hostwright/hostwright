#!/usr/bin/env python3
"""Fail when current-main release, contract, or immutable-history truth drifts."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
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


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(condition: bool, message: str, errors: list[str]) -> None:
    if not condition:
        errors.append(message)


def main() -> int:
    errors: list[str] = []
    identity = read("Sources/HostwrightCore/HostwrightIdentity.swift")
    contracts = read("Sources/HostwrightCore/ContractVersions.swift")
    evidence_models = read("Sources/HostwrightCore/EvidenceModels.swift")
    readme = read("README.md")
    install = read("docs/reference/install.md")
    compatibility = read("docs/reference/compatibility.md")
    manifest_doc = read("docs/reference/manifest.md")
    cli = read("docs/reference/cli.md")
    state = read("docs/architecture/state-store.md")
    release = read("docs/release/RELEASE_PROCESS.md")
    roadmap = read("docs/roadmap/v0.0.2/IMPLEMENTATION_PLAN.md")
    historical_plan = read("docs/IMPLEMENTATION_PLAN.md")

    require('version = "0.0.2-dev"' in identity, "HostwrightIdentity version is not 0.0.2-dev", errors)
    require('releaseTarget = "v0.0.2"' in identity, "HostwrightIdentity release target is not v0.0.2", errors)
    for fragment in ["manifest = 2", "controlAPI = 2", "runtimeProviderAPI = 2", "pluginABI = 1", "stateSchema = 7"]:
        require(fragment in contracts, f"missing contract truth: {fragment}", errors)

    require("0.0.2-dev" in readme and "v0.0.2" in readme, "README lacks current version/release truth", errors)
    require("`brew install hostwright` does not exist today" in readme, "README must state the unqualified brew command does not exist", errors)
    require("`brew install hostwright` does not exist today" in install, "install docs must state the unqualified brew command does not exist", errors)
    require("source development workflow only" in install, "install docs must identify current source-only development workflow", errors)
    require("exact development evidence" in compatibility, "compatibility docs must distinguish evidence from GA claims", errors)
    require("version: 2" in manifest_doc and "migrate preview" in manifest_doc, "manifest docs lack v2/migration truth", errors)
    require("0.0.2-dev" in cli and "apiVersion\":2" in cli, "CLI docs lack product/API v2 truth", errors)
    require("Schema version 7 is the latest" in state, "state docs do not name schema v7", errors)
    require("active release target is `v0.0.2`" in release, "release process does not name v0.0.2", errors)
    require("one master issue, 15 phase epics, and 167 child workstreams" in roadmap, "roadmap count statement is missing", errors)
    require("Target GA gate: 2026-07-27" in roadmap, "roadmap GA target is not 2026-07-27", errors)
    require("2026-07-13 through 2026-07-27" in roadmap, "roadmap daily execution cadence is missing", errors)
    require(historical_plan.startswith("# Historical Implementation Plan"), "former plan is not visibly historical", errors)

    schema = json.loads(read("schemas/hostwright-yaml.schema.json"))
    version_schema = schema.get("properties", {}).get("version", {})
    require(version_schema.get("const") == 2, "manifest JSON schema version is not const 2", errors)
    require("version" in schema.get("required", []), "manifest JSON schema does not require version", errors)

    model_evidence_classes = re.findall(r'case\s+\w+\s*=\s*"([a-z-]+)"', evidence_models.split("public enum HostwrightEvidenceStatus", 1)[0])
    evidence_schema = json.loads(read("schemas/hostwright-evidence.schema.json"))
    schema_evidence_classes = evidence_schema.get("properties", {}).get("evidenceClass", {}).get("enum")
    issue_manifest = json.loads(read("docs/roadmap/v0.0.2/issues.json"))
    require(model_evidence_classes == EVIDENCE_CLASSES, "Swift evidence classes drifted from the v0.0.2 constitution", errors)
    require(schema_evidence_classes == EVIDENCE_CLASSES, "evidence schema classes drifted from the v0.0.2 constitution", errors)
    require(issue_manifest.get("evidenceClasses") == EVIDENCE_CLASSES, "roadmap issue evidence classes drifted from the v0.0.2 constitution", errors)
    require(
        issue_manifest.get("phaseSchedule") == PHASE_SCHEDULE,
        "roadmap phase schedule must run daily from 2026-07-13 through 2026-07-27",
        errors,
    )

    example_paths = sorted((ROOT / "examples").glob("*/hostwright.yaml"))
    require(bool(example_paths), "no executable manifest examples found", errors)
    for path in example_paths:
        content = path.read_text(encoding="utf-8")
        require(re.search(r"(?m)^version:\s*2\s*$", content) is not None, f"{path.relative_to(ROOT)} is not Manifest v2", errors)

    immutable = json.loads(read("docs/release/IMMUTABLE_RELEASES.json"))
    require(immutable.get("schemaVersion") == 1, "immutable release manifest schema is invalid", errors)
    for record in immutable.get("files", []):
        path = ROOT / record["path"]
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        require(digest == record["sha256"], f"immutable historical release changed: {record['path']}", errors)

    if errors:
        for error in errors:
            print(f"current truth check failed: {error}", file=sys.stderr)
        return 1
    print("current truth check: v0.0.2 contracts, docs, examples, and immutable history agree")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
