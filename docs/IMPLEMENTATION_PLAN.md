# Implementation Plan

This is the canonical first-release roadmap for Hostwright.

The maintainer approved a compressed 10-phase plan after the Phase 0/1/2 foundation work. Phase 3 is intentionally a short alignment and test-foundation control gate. It is not a broad documentation expansion and it does not add runtime behavior.

## Phase Status

| Phase | Name | Status | Goal | Acceptance gate |
| --- | --- | --- | --- | --- |
| 0 | Repo Foundation | Complete | Normalize the repo, preserve source material, establish Hostwright naming, and create public project documents. | Source checksums are logged and public-facing naming uses Hostwright. |
| 1 | SwiftPM Skeleton | Complete | Establish dependency-free Swift Package Manager module boundaries. | `swift build` and `swift test` pass in the local environment or exact blockers are recorded. |
| 2 | CLI and Manifest Foundation | Complete | Provide useful non-mutating CLI commands and a minimal `hostwright.yaml` manifest model. | `init`, `validate`, `plan`, `status`, and `doctor` work without runtime mutation. |
| 3 | Alignment and Test Foundation Gate | Complete | Create requirements, source traceability, and acceptance gates for future implementation. | Every future risky phase has source-backed requirements and acceptance checks before implementation begins. |
| 4 | RuntimeAdapter Contract | Complete | Harden the runtime boundary with typed models, mock adapter behavior, and process-execution design. | Runtime assumptions are testable without calling Apple container mutation commands. |
| 5 | Read-Only Apple Observation | Complete | Begin safe Apple container integration through read-only observation only. | Runtime observation reports facts honestly and never creates, starts, stops, deletes, or mutates resources. |
| 6 | SQLite State and Event Ledger | Current | Add durable local state for desired state, snapshots, events, and operation records. | Migrations, transactions, crash recovery, and redaction behavior are tested. |
| 7 | Real Planning and Drift Detection | Planned | Compare desired state with observed state and produce deterministic plans. | Tests cover missing, stopped, unmanaged, unhealthy, changed, and duplicate resources. |
| 8 | First Runtime Mutation and `apply` | Planned | Implement minimal safe convergence through `RuntimeAdapter`. | Disposable Apple container integration tests pass and partial failures are recoverable. |
| 9 | Health, Restart, Status, Logs, Cleanup | Planned | Make managed workloads operable and observable. | Health, restart backoff, events, logs, status, and ownership-based cleanup pass tests. |
| 10 | Hardening and First Supported Release | Planned | Prove the narrow release contract. | Build, tests, docs, examples, benchmarks, security checklist, and reviewer approval pass. |

## Hard Boundaries Through Phase 6

- No Apple container mutation is implemented.
- Live Apple container execution exists only behind the Phase 5 read-only RuntimeAdapter path.
- No `apply` command is implemented.
- No cleanup, restart enforcement, DNS, tunnel, cloud, GPU/ANE, privileged helper, or installer behavior is implemented.
- No daemon loop is implemented.
- No drift planner is implemented.
- Phase 6 state writes require explicit database paths; no default user database path exists.

## Phase 3 Outputs

- `docs/requirements/REQUIREMENTS.md`
- `docs/requirements/SOURCE_TRACEABILITY.md`
- `docs/requirements/ACCEPTANCE_MATRIX.md`
- Updated limitations and build status.
- A Phase 3 devlog.
- Copy-only website corrections were audited locally, but the website worktree is outside the core repository and belongs in the separate `hostwright.dev` repository.

## Phase 4 Outputs

- Typed runtime models.
- Expanded `RuntimeAdapter` protocol.
- `MockRuntimeAdapter` for deterministic tests.
- Runtime command specs, command results, command classification, timeout model, redaction policy, and fake process runner.
- Runtime/reconciler smoke checks for contract behavior.
- Updated runtime-adapter architecture documentation, requirements, limitations, build status, devlog, and maintainer notes.

## Phase 5 Outputs

- `AppleContainerReadOnlyAdapter` behind `RuntimeAdapter`.
- Guarded read-only process execution policy.
- Apple container command descriptors isolated in `HostwrightRuntime`.
- Fixture-backed observation parser coverage.
- Runtime mutation remains unavailable.

## Phase 6 Outputs

- SQLite state store using explicit database paths only.
- Schema migrations for projects, desired services, observed snapshots, observed services, event ledger, operation ledger, and ownership records.
- Transactional repository APIs for desired state, observed state, events, operations, and ownership.
- Redaction before persistence for env, event payloads, operation payloads, ownership metadata, and observed summaries.
- Temp-database smoke checks.

## Next Planned Phase

Phase 7 should implement real planning and drift detection from desired state plus persisted/read-only observed state. It must not implement runtime mutation or `apply`.
