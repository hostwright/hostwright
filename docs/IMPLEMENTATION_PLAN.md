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
| 5 | Read-Only Apple Observation | Planned | Begin safe Apple container integration through read-only observation only. | Runtime observation reports facts honestly and never creates, starts, stops, deletes, or mutates resources. |
| 6 | SQLite State and Event Ledger | Planned | Add durable local state for desired state, snapshots, events, and operation records. | Migrations, transactions, crash recovery, and redaction behavior are tested. |
| 7 | Real Planning and Drift Detection | Planned | Compare desired state with observed state and produce deterministic plans. | Tests cover missing, stopped, unmanaged, unhealthy, changed, and duplicate resources. |
| 8 | First Runtime Mutation and `apply` | Planned | Implement minimal safe convergence through `RuntimeAdapter`. | Disposable Apple container integration tests pass and partial failures are recoverable. |
| 9 | Health, Restart, Status, Logs, Cleanup | Planned | Make managed workloads operable and observable. | Health, restart backoff, events, logs, status, and ownership-based cleanup pass tests. |
| 10 | Hardening and First Supported Release | Planned | Prove the narrow release contract. | Build, tests, docs, examples, benchmarks, security checklist, and reviewer approval pass. |

## Hard Boundaries Before Phase 5

- No Apple container mutation is implemented.
- No live Apple container command execution is implemented.
- No SQLite schema, migration, or database file is created.
- No `apply` command is implemented.
- No cleanup, restart enforcement, DNS, tunnel, cloud, GPU/ANE, privileged helper, or installer behavior is implemented.

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

## Next Planned Phase

Phase 5 should implement read-only Apple container observation behind `RuntimeAdapter`. It must not create, start, stop, delete, apply, clean up, or otherwise mutate runtime state.
