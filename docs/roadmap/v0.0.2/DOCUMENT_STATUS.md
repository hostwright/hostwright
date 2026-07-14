# Documentation Status and Source of Truth

The v0.0.2 truth reset separates current contracts from immutable history. A file’s existence does not make every sentence a current support claim.

## Current and Normative

- `README.md`: current development entry point.
- `docs/roadmap/v0.0.2/IMPLEMENTATION_PLAN.md`: scope, architecture, limitation register, phase sequence, evidence, SLOs, and fallbacks.
- `docs/roadmap/v0.0.2/issues.json`: exhaustive issue identity, hierarchy, labels, milestone, and ownership.
- `Sources/HostwrightCore/HostwrightIdentity.swift`: development and target release versions.
- `Sources/HostwrightCore/ContractVersions.swift`: public contract versions.
- `Sources/HostwrightCore/CapabilityCatalog.swift` and `hostwright capabilities --json`: exact build capability state.
- `schemas/hostwright-yaml.schema.json`: executable manifest schema contract.
- `schemas/hostwright-evidence.schema.json` and `docs/reference/testing-evidence.md`: evidence contract.
- `docs/reference/install.md`, `compatibility.md`, `manifest.md`, `cli.md`, `local-paths.md`, and `security-safety.md`: current behavior and constraints.
- `docs/release/RELEASE_PROCESS.md`: active v0.0.2 release ladder and gate.
- ADRs 0007–0009: v0.0.2 identity, saga, scope, and compatibility decisions.

When these disagree, executable contract tests and capability output expose the failure; the disagreement must be fixed before merge.

## Immutable Historical Release Material

`docs/release/IMMUTABLE_RELEASES.json` records checksums for release-note artifacts whose original claims must not be rewritten. Current index/reference docs may annotate their status without editing the artifact.

The first locked artifact is `docs/release/v0.1.0-alpha.1-notes.md`. It is a historical candidate record, not the current target.

## Historical but Editable for Annotation

These records preserve why earlier work was built and what evidence existed, but their scope, “non-goal,” phase number, release target, and “deferred/rejected” language are superseded:

- `docs/IMPLEMENTATION_PLAN.md`;
- `docs/BUILD_STATUS.md` below its v0.0.2 banner;
- `docs/requirements/REQUIREMENTS.md`, `ACCEPTANCE_MATRIX.md`, and `SOURCE_TRACEABILITY.md` until their IDs are migrated into the v0.0.2 workstreams;
- `docs/devlog/` and `docs/learning/`;
- earlier research and boundary documents under `docs/architecture/`;
- distribution/beta readiness documents that describe the former phase program;
- ADRs 0005 and 0006, now explicitly superseded.

Historical files can still contain valuable implementation detail and tests may preserve exact phrases. They cannot override the active plan or make an unsupported feature a permanent non-goal.

## Website Repository

`hostwright/hostwright.dev` is a separate repository. CI checks it out independently, typechecks, builds, scans internal links, and verifies the v0.0.2 contract markers. Website presentation can differ, but version, installation, limitation, compatibility, and roadmap claims must agree with the current core sources above.

## Enforcement

- `scripts/check-current-truth.py` verifies release/contract values, Manifest v2 examples/schema, state schema v7, active docs, and immutable historical hashes.
- `scripts/roadmap-governance.py` validates the 183-issue ledger and clean evidence closure rules.
- `scripts/check-docs.sh` validates current repository links and executes each checked-in quickstart manifest.
- `.github/workflows/docs-site.yml` validates both repositories together.

Changing a current contract requires code, golden tests, migration evidence, docs, capability output, and any affected website content in the same reviewed delivery sequence.
