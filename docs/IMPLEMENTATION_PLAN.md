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
| 9 | Operability, Restart, Logs, and Safe Cleanup | Complete | Make managed workloads operable and observable without broad lifecycle management. | Live status, bounded logs, event rendering, restart-policy-gated start, and ownership-based cleanup pass tests. |
| 10 | Hardening and First Supported Release | Complete locally | Prepare `v0.1.0-alpha.1` as an honest source-only GitHub pre-release candidate. | Build, tests, docs, examples, compatibility, release notes, security checklist, and reviewer approval pass. |
| 11 | Release Feedback and Alpha Stabilization | Complete | Address pre-alpha review blockers after external review. | Pipe draining, localhost publishing, redaction, cleanup failure handling, append-only ledgers, idempotency retry, command-token validation, and error preservation are covered by tests. |
| 12 | CLI and Developer Workflow Hardening | Complete locally | Add stable CLI exit conventions, structured JSON output, better help/errors/examples, and command consistency. | CLI parsing, JSON success/error shapes, exit codes, redaction, help docs, and full local verification pass. |
| 13 | Manifest Schema Maturity | Complete locally | Align parser, schema, examples, manifest version policy, and untrusted-manifest handling. | Parser, validator, schema, examples, and docs agree on accepted and rejected manifest shapes. |
| 14 | State Migrations and Upgrade Safety | Planned | Harden state migrations, compatibility, corruption handling, and locking. | Fresh, existing, future-version, corrupt, locked, and repeated migration cases are tested. |
| 15 | Local Daemon Reconciliation Loop | Planned | Turn `hostwrightd` into explicit foreground dev-mode reconciliation only. | Fake-clock loop, backoff, lock, shutdown, and sleep/wake behavior pass without unattended mutation. |
| 16 | Health Checks and Restart Policy Expansion | Planned | Add bounded health execution and crash-loop-aware restart policy state. | Health results, max attempts, backoff, operator hold, manual disable, and redacted events are tested. |
| 17 | Managed Restart | Planned | Add one narrow Hostwright-owned restart path as an explicit stop-then-start sequence. | Ownership, running observed state, plan hash, operation ledger, recovery record, fake-runner tests, and disposable live proof pass. |
| 18 | Rollback and Partial Failure Recovery | Planned | Model operation groups, locks, checkpoints, interruption recovery, and manual recovery hints. | Partial failure and crash/interruption records explain what changed and what remains manual. |
| 19 | Cleanup and Garbage Collection Maturity | Planned | Improve cleanup classification, ownership mismatch handling, stale ID protection, and partial failure behavior. | Dry-run classifications and exact delete boundaries pass without image, volume, or unmanaged deletion. |
| 20 | Observability and Diagnostics | Planned | Add redacted diagnostics, local-only telemetry policy, audit trail, event filtering, and improved doctor/status output. | Diagnostic bundles, redaction, event ordering/filtering, and local-only telemetry policy are tested. |

## Current Hard Boundaries

- Apple container mutation is limited to create-missing-service, restart-policy-allowed managed start, and exact cleanup-eligible managed container delete.
- Live Apple container read-only execution exists behind the RuntimeAdapter path.
- `hostwright apply` requires explicit `--state-db` and `--confirm-plan`.
- `hostwright cleanup` requires explicit `--state-db`, dry-run planning, a matching cleanup token, ownership records, live observation, exact resource identifiers, and a non-running lifecycle.
- No stop/restart command, image replacement, port mutation, mount mutation, image cleanup, volume cleanup, unmanaged cleanup, restart enforcement, DNS, tunnel, cloud, GPU/ANE, privileged helper, or installer behavior is implemented.
- No daemon loop is implemented.
- Phase 6 state writes require explicit database paths; no default user database path exists.
- Planning is deterministic and non-mutating.
- Apply executes at most one supported action and refuses every other planned action.
- Manifest parsing remains a restricted Hostwright subset, not general YAML or Compose parity.
- Explicit `version: 1` manifests are supported; omitted version is legacy v1 input; explicit older/newer versions fail closed with no automatic conversion.

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
- Policy checks for duplicate desired host ports, unsafe broad exposure, privileged host ports, unsafe host-root or parent-traversal mount sources, ambiguous mounts, invalid identities, and secret-like environment values.
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

## Phase 10 Outputs

- Central version source of truth is `0.1.0-alpha.1`.
- `hostwright --version` reports `0.1.0-alpha.1`.
- Release process docs define `phase-*` as internal checkpoints and `v*` as public release tags.
- `docs/release/v0.1.0-alpha.1-notes.md` drafts the GitHub pre-release body.
- Compatibility, install/build, security/safety, limitations, and CLI docs explain the source-only alpha boundary.
- Release artifact policy is source-only: no binaries, installer, Homebrew formula, signing, notarization, SBOM, or provenance claim.
- Tests cover version output, release docs, public overclaim checks, and example/schema alignment.

Phase 10 does not create the public `v0.1.0-alpha.1` tag or a GitHub Release. Those happen only after the release-hardening branch is merged to `main` and final verification passes.

## Phase 12 Outputs

- Stable process exit categories for usage, validation, state unavailable, runtime unavailable, confirmation mismatch, unsafe operation, and partial failure.
- `--output text|json` for `plan`, `status`, `events`, and `doctor`; text remains the default.
- JSON error envelopes for usage, manifest, state, and runtime failures where the CLI can identify the requested JSON mode.
- Expanded CLI help with output-mode examples and explicit state-path reminders.
- XCTest coverage for output-mode parsing, JSON success shapes, JSON errors, exit codes, event ordering, status shapes, and redaction.

Phase 12 does not add runtime mutation, default state database paths, shell completion installation, background behavior, release tags, or GitHub Releases.

## Phase 13 Outputs

- Optional manifest `version: 1` support with versionless alpha manifests treated as legacy v1 input.
- Explicit older/newer manifest versions fail closed; no automatic upgrade or downgrade conversion is implemented.
- Unsupported top-level, service, health, restart, Kubernetes-style, and Compose-style fields report contextual manifest errors.
- Manifest validation rejects unsafe host-root or parent-traversal mount sources, unsafe environment keys, and empty service command tokens.
- Schema, examples, starter manifest, manifest reference, security notes, limitations, requirements, and acceptance matrix now describe the same supported subset.
- XCTest coverage for version policy, unsupported fields, unsafe untrusted-manifest shapes, schema/example alignment, and starter manifest validity.

Phase 13 does not add a YAML dependency, general YAML parsing, full Compose parity, registry/network validation, runtime mutation, default state paths, release tags, or GitHub Releases.
