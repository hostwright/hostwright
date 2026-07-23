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
    limitations = read("docs/reference/limitations.md")
    build_status = read("docs/BUILD_STATUS.md")
    runtime_architecture = read("docs/architecture/runtime-adapter.md")
    runtime_binding_adr = read("docs/design/adr-0007-resource-identity-provider-binding.md")
    contract_readme = read("contracts/v0.0.2/README.md")
    capability_catalog = read("Sources/HostwrightCore/CapabilityCatalog.swift")
    state = read("docs/architecture/state-store.md")
    requirements = read("docs/requirements/REQUIREMENTS.md")
    acceptance = read("docs/requirements/ACCEPTANCE_MATRIX.md")
    traceability = read("docs/requirements/SOURCE_TRACEABILITY.md")
    documentation_site = read("docs/architecture/documentation-site-public-education.md")
    extension_architecture = read("docs/architecture/plugin-extension-architecture.md")
    beta_readiness = read("docs/release/beta-readiness.md")
    release = read("docs/release/RELEASE_PROCESS.md")
    roadmap = read("docs/roadmap/v0.0.2/IMPLEMENTATION_PLAN.md")
    historical_plan = read("docs/IMPLEMENTATION_PLAN.md")

    version_match = re.search(r'version = "(0\.0\.2-dev\.1[012])"', identity)
    require(version_match is not None, "HostwrightIdentity version is not a Phase 02 qualification build", errors)
    if version_match is not None:
        version_golden = json.loads(read("contracts/v0.0.2/versions.json"))
        require(
            version_golden.get("productVersion") == version_match.group(1),
            "HostwrightIdentity and the version golden disagree",
            errors,
        )
    require('releaseTarget = "v0.0.2"' in identity, "HostwrightIdentity release target is not v0.0.2", errors)
    for fragment in ["manifest = 2", "controlAPI = 2", "runtimeProviderAPI = 2", "pluginABI = 1", "stateSchema = 7"]:
        require(fragment in contracts, f"missing contract truth: {fragment}", errors)

    require("0.0.2-dev" in readme and "v0.0.2" in readme, "README lacks current version/release truth", errors)
    require("`brew install hostwright` does not exist today" in readme, "README must state the unqualified brew command does not exist", errors)
    require("Phase 02 qualification is complete" in readme, "README does not record completed Phase 02 qualification", errors)
    require("Phase 03 qualification is complete" in readme, "README does not record completed Phase 03 qualification", errors)
    require("brew install hostwright/tap/hostwright" in readme, "README lacks the available vendor-tap command", errors)
    require("`brew install hostwright` does not exist today" in install, "install docs must state the unqualified brew command does not exist", errors)
    require(
        "source development and the Hostwright-controlled `0.0.2-dev` qualification channel are available" in install,
        "install docs do not identify the available source and vendor qualification channels",
        errors,
    )
    require("brew install hostwright/tap/hostwright" in install, "install docs lack the available vendor-tap command", errors)
    require("v0.0.2-dev.11" in install and "v0.0.2-dev.12" in install, "install docs lack the immutable Phase 02 qualification pair", errors)
    require("exact development evidence" in compatibility, "compatibility docs must distinguish evidence from GA claims", errors)
    require("Apple `container` 1.0.0 and 1.1.0" in compatibility, "compatibility docs lack the exact Phase 03 Apple CLI matrix", errors)
    require("Containerization 0.35.0" in compatibility, "compatibility docs lack the exact Phase 03 Containerization pin", errors)
    require("version: 2" in manifest_doc and "migrate preview" in manifest_doc, "manifest docs lack v2/migration truth", errors)
    require("0.0.2-dev" in cli and "apiVersion\":2" in cli, "CLI docs lack product/API v2 truth", errors)
    for fragment in ["hostwright runtime providers", "hostwright runtime migrate", "--runtime-provider auto|apple-cli|containerization"]:
        require(fragment in cli, f"CLI docs lack Phase 03 runtime surface: {fragment}", errors)
    require("Phase 03 qualification is complete" in limitations, "limitations do not record completed Phase 03 qualification", errors)
    require("Phase 03 runtime-provider qualification is complete" in build_status, "build status does not record Phase 03 qualification", errors)
    for fragment in ["apple-container-cli", "apple-containerization", "helper protocol v1", "Provider Selection, Migration, And Recovery"]:
        require(fragment in runtime_architecture, f"runtime architecture lacks Phase 03 truth: {fragment}", errors)
    require("Phase 03 live migration evidence" in runtime_binding_adr, "provider-binding ADR retains pre-Phase 03 verification truth", errors)
    require("runtime-provider-capabilities.json" in contract_readme and "helper protocol v1" in contract_readme, "contract README lacks Phase 03 runtime contracts", errors)
    for identifier in ["runtime.apple-container-cli", "runtime.containerization"]:
        pattern = rf'capability\("{re.escape(identifier)}"[^\n]+\.stable, 3, 129'
        require(re.search(pattern, capability_catalog) is not None, f"capability catalog does not report qualified Phase 03 provider: {identifier}", errors)
    require("Schema version 7 is the latest" in state, "state docs do not name schema v7", errors)
    require("secure selected state paths" in requirements, "requirements lack the secure selected-state contract", errors)
    require("Implemented for API version 2" in requirements, "requirements retain the obsolete Control API version", errors)
    require("uses the secure selected state database" in acceptance, "acceptance matrix lacks the state-default contract", errors)
    require("documented secure default" in traceability, "source traceability lacks the state-default contract", errors)
    require("Preserve secure selected state paths" in documentation_site, "documentation-site guidance retains the old state-path contract", errors)
    require("secure selected state paths" in extension_architecture, "extension architecture retains the old state-path contract", errors)
    require("undocumented or unsafe default state path" in beta_readiness, "beta readiness does not reject unsafe state defaults", errors)
    obsolete_path_claims = [
        "choose no default state path",
        "with no default state path",
        "hidden default state path",
        "hidden default paths",
        "one-shot explicit-path JSON process",
    ]
    active_path_docs = {
        "requirements": requirements,
        "acceptance matrix": acceptance,
        "source traceability": traceability,
        "documentation-site architecture": documentation_site,
        "extension architecture": extension_architecture,
        "beta readiness": beta_readiness,
    }
    for document, content in active_path_docs.items():
        for claim in obsolete_path_claims:
            require(claim not in content, f"{document} retains obsolete state-path claim: {claim}", errors)
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
