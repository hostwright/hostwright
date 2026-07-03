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
| 6 | SQLite State and Event Ledger | Complete | Add durable local state for desired state, snapshots, events, and operation records. | Migrations, transactions, crash recovery, and redaction behavior are tested. |
| 7 | Real Planning and Drift Detection | Complete | Compare desired state with observed state and produce deterministic plans. | Tests cover missing, stopped, unmanaged, unhealthy, changed, and duplicate resources. |
| 8 | First Runtime Mutation and `apply` | Complete | Implement minimal safe convergence through `RuntimeAdapter`. | Disposable Apple container create-only proof passed and partial failures are recoverable. |
| 9 | Operability, Restart, Logs, and Safe Cleanup | Complete locally | Make managed workloads operable and observable without broad lifecycle management. | Live status, bounded logs, event rendering, restart-policy-gated start, and ownership-based cleanup pass tests. |
| 10 | Hardening and First Supported Release | Planned | Prove the narrow release contract. | Build, tests, docs, examples, benchmarks, security checklist, and reviewer approval pass. |

## Current Hard Boundaries After Phase 9

- Apple container mutation is limited to create-missing-service, restart-policy-allowed managed start, and exact cleanup-eligible managed container delete.
- Live Apple container read-only execution exists behind the RuntimeAdapter path.
- `hostwright apply` requires explicit `--state-db` and `--confirm-plan`.
- `hostwright cleanup` requires explicit `--state-db`, dry-run planning, a matching cleanup token, ownership records, live observation, exact resource identifiers, and a non-running lifecycle.
- No stop/restart command, image replacement, port mutation, mount mutation, image cleanup, volume cleanup, unmanaged cleanup, restart enforcement, DNS, tunnel, cloud, GPU/ANE, privileged helper, or installer behavior is implemented.
- No daemon loop is implemented.
- Phase 6 state writes require explicit database paths; no default user database path exists.
- Planning is deterministic and non-mutating.
- Apply executes at most one supported action and refuses every other planned action.

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

## Phase 7 Outputs

- Manifest-to-runtime desired-state mapping outside the CLI.
- Typed drift records, plan issues, planned action kinds, and deterministic plan hash.
- Policy checks for duplicate desired host ports, unsafe broad exposure, privileged host ports, unsafe root mounts, ambiguous mounts, invalid identities, and secret-like environment values.
- Drift detection for missing desired services, unmanaged observed services, stopped/exited/failed services, image drift, port drift, mount drift, unhealthy/unknown health, duplicate observed identities, unsupported unknown observed lifecycle state, and unavailable observation.
- Non-mutating CLI plan rendering with no live runtime observation by default.
- XCTest coverage for planner drift, policy, determinism, redaction, and mutation-unavailable boundaries.

## Phase 8B Outputs

- `hostwright apply [path] --state-db <path> --confirm-plan <hash>`.
- Recomputed observed plan hash confirmation before mutation.
- Operation intent, desired state, observed state, and apply-start event persistence before mutation.
- RuntimeAdapter-backed create-only execution.
- Success/failure operation status and event persistence.
- Ownership record persistence when a runtime resource identifier is available.
- Fake-runner XCTest coverage for create success, failure, missing local image, unsupported subsets, redaction, and boundary behavior.
- Live disposable proof using `hostwright-proof-web:phase8b`, `hostwright apply`, real Apple container create output, state DB verification, stale-hash refusal, and exact proof cleanup.

Phase 8 remains intentionally narrow as historical context. It proved one create-only convergence path, not start, stop, delete, restart, cleanup, health execution, daemon reconciliation, DNS, tunnels, cloud, GPU/ANE behavior, or production readiness.

## Phase 9 Outputs

- `hostwright status [path] --state-db <path>` observes through `RuntimeAdapter`, persists observed state and `status.observed` events, and renders desired vs observed status honestly.
- `hostwright logs <service> [path] [--tail <n>] [--state-db <path>]` reads bounded log output through `RuntimeAdapter`, redacts output, and optionally records `logs.read` events.
- `hostwright events --state-db <path> [--project <name>]` renders persisted event ledger records deterministically.
- `hostwright cleanup [path] --state-db <path> --dry-run` plans exact cleanup candidates from ownership records plus live observation.
- `hostwright cleanup [path] --state-db <path> --confirm-cleanup <token>` deletes only exact eligible Hostwright-owned stopped/created/exited containers.
- `hostwright apply` can execute exactly one `createMissingService` or one restart-policy-allowed `startManagedService` action after current plan hash confirmation.
- Runtime command policy rejects attach, interactive, broad delete, force, stop, restart, remove, prune, pull, push, build, exec, run, image delete, and volume delete paths.

Phase 9 remains intentionally narrow. It does not implement stop, restart command, image replacement, port mutation, mount mutation, daemon restart loops, image cleanup, volume cleanup, DNS, tunnels, cloud, GPU/ANE behavior, or production readiness.

## Next Planned Phase

Phase 10 should harden the first supported release contract: docs, examples, compatibility checks, benchmark baseline, security checklist, live proof notes, CI verification, and release review.
