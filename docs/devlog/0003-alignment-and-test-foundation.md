# Devlog 0003: Alignment And Test Foundation

## Goal

Adopt the maintainer-approved 10-phase first-release roadmap and add a source-grounded requirements framework before risky implementation begins.

## Why Phase 3 Exists

Phase 0 created the repository foundation. Phase 1 created Swift package boundaries. Phase 2 added a non-mutating CLI and restricted manifest parser. That is enough structure to start drifting if future work is not tied back to the source documents.

Phase 3 prevents that drift by creating stable requirement IDs, source traceability, and acceptance gates. It is intentionally short. It does not implement runtime behavior, SQLite, `apply`, Apple container calls, or RuntimeAdapter process execution.

## What Changed

- `docs/IMPLEMENTATION_PLAN.md` now uses the canonical 10-phase roadmap.
- `docs/requirements/REQUIREMENTS.md` defines stable requirement IDs by subsystem.
- `docs/requirements/SOURCE_TRACEABILITY.md` maps source-document claims to requirement IDs.
- `docs/requirements/ACCEPTANCE_MATRIX.md` defines verification gates for future phases.
- `docs/reference/limitations.md` now states current and first-release limitations more explicitly.
- Site copy was audited and corrected where future behavior read like current support.

## What This Prevents

- Runtime work starting before the adapter boundary is testable.
- SQLite being added without a schema and migration gate.
- `apply` being implemented before durable intent, safety gates, and failure recovery exist.
- Public docs or site copy implying production readiness or unsupported compatibility.
- Source material becoming disconnected from implementation decisions.

## Concepts Learned

- Requirements are not prose wishes; they need stable IDs and verification paths.
- Traceability makes later implementation review easier because every risky feature has a source and gate.
- Acceptance criteria must say how something will be proven, not only what should exist.
- Copy can be an engineering risk when it claims behavior before the code exists.

## Commands To Run

```bash
swift build
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

## Risks

- The current tests are still smoke/precondition tests because the local toolchain does not expose XCTest or Swift Testing.
- The restricted manifest parser remains a temporary subset parser and needs a dependency/design decision before the manifest grows.
- Requirements can become stale if future phases do not update the matrix when behavior changes.

## Unknowns

- Exact Apple container structured output and metadata available for read-only observation.
- Final SQLite dependency or wrapper strategy.
- Whether site build checks should become part of the local core test gate before public release.

## Phase 4 Next Action

Harden the RuntimeAdapter contract. Phase 4 should add typed runtime models, a mock adapter, and a controlled process-execution design. It must not call Apple container mutation commands.
