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
| 12 | CLI and Developer Workflow Hardening | Complete locally | Add stable CLI exit conventions, structured JSON output, better help/errors/examples, and command consistency. | JSON/help coverage, consistent manifest/local-file I/O classification, built-CLI subprocess checks, and redaction tests pass. |
| 13 | Manifest Schema Maturity | Complete locally | Align parser, schema, examples, manifest version policy, and untrusted-manifest handling. | Parser, validator, schema, examples, and docs agree on accepted and rejected manifest shapes. |
| 14 | State Migrations and Upgrade Safety | Complete locally | Harden state migrations, compatibility, corruption handling, locking, and cold backup/restore evidence. | Fresh, existing, future-version, corrupt, locked, checksum-mismatch, migration-gap, rollback, unrelated database, repeated migration, multi-connection, concurrent acquisition, reopen, and cold-copy cases use real SQLite files. |
| 15 | Local Daemon Reconciliation Loop | Complete locally | Turn `hostwrightd` into explicit foreground dev-mode reconciliation only. | Fake-clock loop, backoff, lock, shutdown, and sleep/wake behavior pass without unattended mutation. |
| 16 | Health Checks and Restart Policy Expansion | Complete locally | Add bounded health execution and crash-loop-aware restart policy state. | Health results, max attempts, backoff, manual disable, preexisting operator hold blocking, crash-loop blocking, and redacted events are tested. |
| 17 | Managed Restart | Complete locally | Add one narrow Hostwright-owned restart path as an explicit stop-then-start sequence. | Ownership, running observed state, plan hash, operation ledger, recovery record, and scripted-runner tests pass. |
| 18 | Rollback and Partial Failure Recovery | Complete locally | Model operation groups, locks, checkpoints, interruption recovery, and manual recovery hints. | Partial failure and crash/interruption records explain what changed and what remains manual. |
| 19 | Cleanup and Garbage Collection Maturity | Complete locally | Improve cleanup classification, ownership mismatch handling, stale ID protection, and partial failure behavior. | Exact observed identifiers, versioned collision-resistant identity, ownership labels, legacy migration, multi-project observation, managed-start ownership, classifications, and exact cleanup pass tests and a disposable live proof. |
| 20 | Observability and Diagnostics | Complete locally | Add redacted diagnostics, local-only telemetry policy, audit trail, event filtering, and improved doctor/status output. | Diagnostic bundles, redaction, event ordering/filtering, and local-only telemetry policy are tested. |
| 21 | API and GUI Readiness Gate | Requirements complete; implementation not started | Define local GUI/control-surface requirements, data contracts, accessibility expectations, command/API boundaries, safety rules, and handoff criteria. | Requirements are documented; a reviewed local API and GUI remain future implementation work. |
| 22 | Networking and Service Discovery | Complete locally; live HTTP blocked | Harden local networking policy and document unsupported discovery/exposure boundaries. | Localhost publish defaults, duplicate/observed port conflicts, unsupported discovery fields, and real Apple container 1.0.0 network metadata parsing are tested. Localhost HTTP proof is blocked by disabled macOS Local Network access for `container-runtime-linux`. |
| 23 | Secure Exposure Research | Research complete; implementation not started | Decide tunnel, VPN, mTLS, reverse proxy, DNS, and cloud exposure boundaries before any implementation. | Research is recorded; provider, reverse-proxy, and mTLS implementation require separate evidence-gated work. |
| 24 | Secrets, Credentials, And Keychain Boundary | Complete for opt-in read boundary | Add local secret references, a test-only in-memory store, an opt-in noninteractive read-only macOS Keychain backend, an unavailable CLI default, and redaction hardening. | `secretEnv`, deterministic in-memory contracts, real add/read/exact-delete/post-delete Keychain evidence, fail-closed unavailable default, and redacted state/diagnostics/plans pass tests. |
| 25 | Supply Chain And Image Trust | Complete for local digest policy | Add local image digest-reference policy and document trust-tool boundaries. | `imagePolicy: require-digest`, digest syntax validation, schema alignment, docs boundary, and overclaim tests pass without registry calls or scanner/signing dependencies. |
| 26 | Apple Silicon Resource Intelligence | Complete locally | Add local resource reports and benchmark-methodology boundaries without scheduler or accelerator claims. | Doctor resource reports, fixture parsing, architecture warnings, unmeasured benchmark dimensions, and docs boundary tests pass. |
| 27 | Apple Silicon Accelerator Boundary Research | Research complete; implementation not started | Decide GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator, and scheduler boundaries before implementation. | Research is recorded; host-native accelerator measurement and execution remain unimplemented. |
| 28 | Stack-File Import And Migration Tooling | Complete locally | Add import-only conversion for a narrow safe stack-file subset. | Golden conversion, unsupported-field, policy-reason, CLI JSON/text, and validation-gate tests pass without runtime/state mutation or Compose parity claims. |
| 29 | External Orchestration Compatibility Research | Research complete; implementation not started | Decide CRI, Kubernetes, Docker API, Compose, attach, forwarding, scheduler, lifecycle, networking, identity, and state compatibility boundaries before implementation. | Research is recorded; any exact-version compatibility implementation belongs in a separately approved project or extension. |
| 30 | Multi-Host Apple Silicon Platform Research | Research complete; implementation not started | Decide multi-host identity, membership, trust, state authority, transport, failure recovery, cloud boundary, and scheduler implications before implementation. | Research is recorded; no transport, membership, replicated state, or two-host proof exists. |
| 31 | Scheduler And Placement Engine | Complete locally | Add deterministic local advisory scheduling without automatic placement or capacity guarantees. | Advisory scheduler tests cover policy blockers, memory overcommit, fairness scoring, accelerator blockers, remote-placement blockers, and unsupported current-support claims. |
| 32 | Policy Engine | Complete locally | Add deterministic local policy decisions before import, compatibility, multi-host, and scheduler work. | Policy evaluator tests cover ports, mounts, images, env/secrets, cleanup, lifecycle, exposure, untrusted manifests, accelerator placeholders, and planner migration. |
| 33 | Plugin And Extension Architecture | Declaration prototype complete; executable host not started | Define safe extension types, trust model, versioning, capability declarations, and non-mutating prototype boundaries. | Declarations are policy checked; no extension loader, process host, installation, or executable capability exists. |
| 34 | Enterprise And Team Workflow | Partial | Define local team profiles, approval records, audit events, and shared policy profiles without cloud dependency. | In-memory models exist, but no explicit profile parser or validate/plan/apply/cleanup/import enforcement path exists. |
| 35 | Packaging Signing Notarization And Distribution | Blocked | Create and verify release artifacts, installer/uninstaller, upgrade path, checksums, SBOM/provenance, signing, and notarization. | Policy documentation exists, but no artifacts or install lifecycle exist and no Developer ID signing identity or notarization credentials are available. |
| 36 | CI Benchmarking And Performance Lab | Partial | Add repeatable CI and local benchmark methodology for supported macOS and Apple container evidence. | Dry-run contracts exist, but no live benchmark runner, runtime measurements, or hardware evidence exists. |
| 37 | Documentation Site And Public Education | Information architecture complete; website implementation not started | Define documentation-site information architecture and source-of-truth boundaries for the separate website repository. | Core source-of-truth rules exist; website implementation remains in the separate repository. |
| 38 | Governance And Contributor Model | Complete locally | Mature OSS governance, contributor workflow, security reporting, review triggers, roadmap process, and release ownership. | Governance docs and templates define issue-to-PR-to-release flow, risky-area review, private-report guidance, and support boundaries. |
| 39 | Beta Readiness | Gate defined; readiness not achieved | Define beta criteria, blockers, deferrals, install/upgrade/docs/security/support gates, and public-claim audit. | The checklist exists; partial phases, live evidence, and release rehearsal remain outstanding. |
| 40 | Apple Silicon Control-Plane Direction Decision | Decision complete; expansion evidence-gated | Keep current core single-host while allowing separately gated extension, control-surface, accelerator, compatibility, and multi-host tracks. | Expansion must not weaken current core or become current-support language before its own evidence passes. |

## Post-Review Completion Program

The status column distinguishes completed implementation from research, requirements, policy gates, and partial prototypes. A phase is not implementation-complete merely because a decision record or fixture contract exists.

Execution order is binding unless a later maintainer-approved issue changes it:

1. Define repository evidence classes and separate deterministic tests from real integration, runtime, hardware, and distribution proof.
2. Completed: repair runtime identity, exact observed identifiers, ownership gates, multi-project observation, legacy upgrade behavior, and live cleanup proof.
3. Completed: consistent CLI file-error classification, migration continuity/concurrency, and interrupted-operation lease diagnostics.
4. Wire explicit local team profiles and approvals into command behavior without default paths or safety-gate bypasses.
5. Run real Apple container and hardware benchmarks with exact disposable-resource cleanup.
6. Build and test distribution artifacts; keep signing and notarization blocked until real credentials and evidence exist.
7. Implement expansion foundations in order: executable extension host, local control API, separate GUI, local secure-exposure provider, host-native accelerator path, exact-version compatibility work, and multi-host proof.
8. Re-run the beta gate from a clean checkout. Version 1 remains blocked on operational soak and real-user evidence.

All evidence follows [Testing And Evidence](reference/testing-evidence.md). Fixtures and scripted test doubles may prove deterministic contracts and failure behavior, but they never count as live runtime, hardware, or distribution success.

## Current Hard Boundaries

- Apple container mutation is limited to create-missing-service, restart-policy-allowed managed start, restart-policy-allowed managed restart, and exact cleanup-eligible managed container delete.
- Live Apple container read-only execution exists behind the RuntimeAdapter path.
- `hostwright apply` requires explicit `--state-db` and `--confirm-plan`.
- `hostwright cleanup` requires explicit `--state-db`, dry-run planning, a matching cleanup token, ownership records, live observation, exact resource identifiers, and a non-running lifecycle.
- No user-facing stop/restart command, image replacement, port mutation, mount mutation, image cleanup, volume cleanup, unmanaged cleanup, aggressive restart loop, DNS, tunnel, cloud, GPU/ANE, privileged helper, launch agent, or installer behavior is implemented.
- `hostwrightd --foreground` can observe, run bounded health checks, plan, and record daemon loop events only; it does not perform unattended runtime mutation.
- Control-surface work is requirements-only: no GUI, web dashboard, daemon API, direct runtime execution, direct SQLite access, telemetry upload, hosted diagnostics, or bypass around existing Hostwright command gates exists.
- Phase 6 state writes require explicit database paths; no default user database path exists.
- State repository reads validate schema without implicit migration; `SQLiteStateStore.migrate()` is the explicit migration path.
- Planning is deterministic and non-mutating.
- Apply executes at most one supported action and refuses every other planned action.
- Manifest parsing remains a restricted Hostwright subset, not general YAML or Compose parity.
- Explicit `version: 1` manifests are supported; omitted version is legacy v1 input; explicit older/newer versions fail closed with no automatic conversion.
- Networking remains local-first: Hostwright-created publishes use `127.0.0.1`, observed host-port conflicts block planning, and DNS/service discovery/reverse proxy/tunnel/cloud exposure remain unsupported.
- Image trust remains local-first: `imagePolicy: require-digest` validates `@sha256` reference syntax only and does not resolve registries, pull images, verify signatures, scan vulnerabilities, generate SBOMs, or prove provenance.
- Resource intelligence remains local and diagnostic: it reports host facts and explicit unmeasured dimensions without capacity guarantees, runtime mutation, image pulls, external telemetry, accelerator scheduling, or Apple container command execution from `doctor`.
- Accelerator behavior remains unsupported: Hostwright does not expose Apple GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator helpers, or accelerator-aware scheduling in current core scope.
- Policy evaluation is local and deterministic: it explains decisions for existing planner checks, cleanup classification, images, env/secrets, lifecycle, exposure, untrusted manifests, and accelerator placeholders without remote policy service, team workflow, silent bypass, runtime mutation, SQLite access, or network calls.
- Extension architecture is declaration-only: `HostwrightPolicy` can evaluate typed capability declarations for built-in or reviewed-local non-mutating paths, but current core has no plugin loader, remote registry, untrusted code execution, runtime-mutation extension, state-write extension, networking provider, tunnel provider, secret backend extension, or accelerator extension.
- Team workflow is local profile data only: `HostwrightPolicy` can evaluate explicit opt-in team profiles, approval records, and override declarations, while audit records use the existing explicit-path event ledger. Current core has no cloud team service, central remote control, hosted audit log, user tracking, enterprise support workflow, remote policy distribution, macOS user/group/ACL management, or shared-secret management.
- Stack-file import is conversion-only: it prints reviewed `hostwright.yaml` text for a narrow safe subset and rejects unsupported networking, secrets, configs, build, deploy, named-volume, shell-healthcheck, cloud, tunnel, and lifecycle semantics without writing files, touching state, observing runtime, pulling images, or claiming Compose parity.
- External orchestration compatibility remains research-only: no CRI shim, Kubernetes node behavior, Docker API shim, Testcontainers target, full Compose parity, attach/exec/log-follow/port-forward stream, or external scheduler API exists in current core scope.
- Multi-host platform work remains research-only: current core has no remote host agent, membership service, peer discovery, state replication, remote mutation, cloud control plane, scheduler API, or remote placement behavior.
- Scheduler behavior is local and advisory: it scores explicit local recommendations from declared inputs and existing policy decisions, but it does not mutate runtime, write state, reserve capacity, perform automatic placement, expose a scheduler API, schedule accelerators, or place work on remote hosts.
- Documentation-site work is source-of-truth planning only: current support claims stay grounded in this repository, while website frontend, hosted docs deployment, analytics, search, and presentation work belong outside the core repository.
- Beta readiness work is checklist and claim-gating only: no beta tag, GitHub Release, version bump, binary artifact, installer, support promise, or production-readiness claim exists until separate maintainer approval and matching evidence.
- Control-plane direction work keeps Hostwright core single-host for beta and first supported release work; Kubernetes-class, CRI, Docker API, full Compose, cloud, multi-host, remote-placement, and accelerator-aware scheduling work require a separate approved track.

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
- Test-only `ScriptedRuntimeAdapter` for deterministic contracts.
- Runtime command specs, command results, command classification, timeout model, redaction policy, and test-only scripted process runner.
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

## Phase 14 Outputs

- Migration records use deterministic checksums while retaining compatibility with the historical Phase 6 v1 checksum.
- Explicit migration refuses unrelated existing SQLite databases, future schema versions, and checksum mismatches.
- Applied migration history must be a contiguous prefix from version 1; missing earlier versions fail before reads, version queries, or migration.
- Repository reads and writes validate already-applied schema instead of applying migrations implicitly.
- SQLite errors classify locked and corrupt/non-SQLite databases as actionable state failures.
- State docs define backup, restore, debug export, downgrade/future-version, corruption recovery, and locking policy.
- Real SQLite integration coverage for multiple connections, isolation and committed visibility, close/reopen persistence, 20 rounds of concurrent operation-group acquisition, cold backup/restore, repeated migrations with data, transaction rollback, read-side-effect prevention, future schemas, migration gaps, checksum mismatch, unrelated databases, corruption, and lock contention.

Phase 14 does not add hidden default state paths, destructive reset commands, automatic repair, online backup/export commands, runtime mutation, daemon behavior, release tags, or GitHub Releases.

## Phase 15 Outputs

- `HostwrightDaemonCore` contains the testable foreground loop, command parsing, shutdown token, sleep/wake model, and single-instance lock interface.
- `hostwrightd --foreground --config <path> --state-db <path>` requires explicit config and state paths.
- The loop observes through the read-only local `RuntimeAdapter`, computes a reconciliation plan, and persists successful desired/observed snapshots plus daemon operation and event records.
- Failed daemon iterations persist failed operation and event records with redacted diagnostic codes.
- Cadence, deterministic jitter, repeated-error backoff, shutdown handling, sleep/wake resume recording, and lock refusal are covered by XCTest.
- The live executable handles SIGINT/SIGTERM by requesting loop shutdown.

Phase 15 does not add launch agent installation, default state paths, privileged helpers, unattended runtime mutation, restart-loop enforcement, image cleanup, volume cleanup, unmanaged cleanup, release tags, or GitHub Releases.

## Phase 16 Outputs

- Desired runtime services carry optional manifest health-check specs into planning.
- Loopback-only health checks run through in-process URL fetches or direct `true`/`false` evaluation after allowlisted command-shape validation, timeouts, and redaction.
- SQLite schema v2 adds append-only health check results and current restart policy state.
- Restart policy planning considers max attempts, backoff, manual-disable, preexisting operator hold, and crash-loop-blocked states before exposing managed start as executable.
- `hostwrightd` records health results, restart policy state, and redacted health/restart events without calling `RuntimeAdapter.execute`.
- `hostwright apply` honors persisted crash-loop/backoff/hold/manual-disable restart state before executing the existing narrow managed start path and resets the attempt budget after a successful managed start.
- XCTest coverage covers runtime health execution, state persistence, restart gating, daemon health persistence, daemon crash-loop blocking, and CLI apply blocking.

Phase 16 does not add a broad restart command, daemon-enforced restart loops, stop/delete behavior, container exec health checks, external telemetry, release tags, or GitHub Releases.

## Phase 17 Outputs

- Reconciliation can plan one `restartManagedService` action for an unhealthy running service when restart policy state allows managed recovery.
- `hostwright apply` executes that action only after explicit state DB, current plan-hash confirmation, exact observed running state, fresh persisted unhealthy health state, and a matching Hostwright ownership record.
- Managed start and managed restart retain the exact observed runtime identifier in the plan hash and require a matching canonical ownership row before execution; legacy identifiers remain supported only through migrated ownership state.
- Runtime execution remains a narrow internal stop-then-start sequence for the exact Hostwright-managed container identifier; no public stop or restart command is added.
- SQLite schema v3 adds append-only restart recovery records with redacted manual recovery hints and completed-step metadata.
- Apply records operation intent before mutation, success/failure operation status after mutation, restart recovery records, restart policy state, and redacted events.
- XCTest coverage covers planner gating, ownership refusal, fresh/stale persisted health handling, status/apply plan-hash parity, successful managed restart, failed managed restart recovery hints/backoff, partial stop-success/start-failure records, runtime command policy, and scripted-runner stop-then-start sequencing.

Phase 17 does not add broad lifecycle management, daemon-enforced restart loops, a public stop/restart command, image replacement, image cleanup, volume cleanup, unmanaged cleanup, release tags, or GitHub Releases.

## Phase 18 Outputs

- SQLite schema v4 adds operation groups and operation group steps for apply recovery state.
- Apply acquires an active operation group before runtime mutation, records a rollback-unsupported step, records forward runtime steps, and finishes the group as succeeded, failed, or interrupted.
- Operation groups carry a group idempotency key, lease fields, current checkpoint, rollback availability flag, and redacted manual recovery hints; expired active leases are marked interrupted before reacquire.
- Operation group steps carry step idempotency keys, forward/rollback direction, started/completed/failed/unsupported status, redacted resource identifiers, and redacted failure hints.
- `hostwright recovery --state-db <path> [--project <name>] [--output text|json]` renders recovery guidance from the explicit state database without observing or mutating the runtime, including legacy managed restart recovery rows when no Phase 18 operation group exists for that operation.
- XCTest coverage covers operation group acquire/release behavior, stale active lease expiration, step append/reload behavior, redaction, apply success/failure/interrupted state, safe retry after an intent-recorded pre-runtime persistence interruption, managed restart stop-success/start-failure recovery steps, read-only recovery behavior, legacy restart recovery rendering, and recovery JSON rendering.

Phase 18 does not add automatic rollback, inverse runtime mutation, multi-action apply, unattended daemon mutation, broad lifecycle commands, image cleanup, volume cleanup, unmanaged cleanup, release tags, or GitHub Releases.

## Phase 19 Outputs

- `hostwright cleanup --dry-run` now classifies ownership-backed and observed-only cleanup assessments as eligible, ambiguous, stale, running, unknown, blocked, or never-delete.
- Confirmation tokens are derived from eligible candidate identity, lifecycle, runtime adapter, and resource identifier so relevant drift invalidates stale cleanup confirmation.
- Confirmed cleanup still deletes only eligible exact Hostwright-owned created/stopped/exited containers through `RuntimeAdapter`.
- Versioned v2 identifiers use a SHA-256 identity digest and exact Hostwright labels, so project/service pairs that collided under legacy hyphen concatenation remain distinct. Current-project labeled orphans remain visible; unrelated labeled projects are ignored.
- SQLite schema v6 backfills legacy observed identifiers and persists exact observed identifiers, Apple container network metadata, and ownership identity versions without changing prior migration checksums.
- Ownership/service mismatches, duplicate observed identifiers, adapter mismatches, missing observations, observed-only resources, running containers, unknown lifecycle state, non-container records, disabled cleanup eligibility, and non-Hostwright identifiers are reported without deletion.
- Cleanup delete success followed by state persistence failure is reported as state unavailable while preserving the actual deletion in command output.
- XCTest coverage covers mixed dry-run classification, observed-only resources, adapter-mismatch blocking, exact eligible-only delete execution, cleanup token confirmation, runtime partial failure, and delete-success/state-failure reporting.

Phase 19 does not add image cleanup, volume cleanup, unmanaged deletion, wildcard deletion, force flags, automatic cleanup, broad garbage collection, release tags, or GitHub Releases.

## Phase 20 Outputs

- `hostwright events --state-db <path>` supports project, event type, service, severity, limit, and ascending/descending sort filters while remaining read-only.
- `hostwright diagnostics --state-db <path> --bundle <path> [--project <name>] [--manifest <path>]` writes a local redacted JSON bundle from existing state rows.
- Diagnostics export includes local-only telemetry policy, state schema metadata, optional explicit manifest summary, redacted events, operations, operation groups, operation steps, health results, restart policy state, restart recovery records, ownership records, and observed snapshots.
- `hostwright status` and `hostwright doctor` report local-only telemetry policy and explicit state-path boundaries.
- XCTest coverage covers event filtering/sorting/limit behavior, diagnostics redaction, no runtime observation during export, missing-state refusal without migration, doctor/status policy output, and state diagnostics export shape.

Phase 20 does not add external telemetry, hosted diagnostics, automatic upload, OSLog integration, production support-bundle workflows, hidden default state paths, runtime mutation, release tags, or GitHub Releases.

## Phase 21 Outputs

- `docs/architecture/control-surface-api-boundary.md` defines the local control-surface requirements and API boundary.
- Approved data surfaces are current Hostwright command contracts for validate/plan/apply/status/logs/events/recovery/cleanup/diagnostics/doctor/errors.
- Control surfaces must not call Apple container, SQLite, `RuntimeAdapter`, state migrations, cleanup deletion, or health execution directly.
- Accessibility requirements cover keyboard navigation, focus, screen-reader status/error states, non-color-only state, long-running operation results, and selectable confirmation hashes/tokens.
- Handoff criteria require fixtures, accessibility acceptance criteria, threat-model review for mutation/export flows, and maintainer approval before design/frontend work starts.
- XCTest coverage guards the boundary and unsupported-current-support wording.

Phase 21 does not add GUI code, website implementation, web dashboard, cloud dashboard, daemon API, direct Apple container execution, direct SQLite access, RuntimeAdapter bypass, new runtime mutation, telemetry upload, hosted diagnostics, release tags, or GitHub Releases.

## Phase 22 Outputs

- Shared local bind-address policy normalizes localhost, recognizes broad bind addresses, and detects host-port conflicts involving wildcard binds.
- Manifest parsing now reports DNS, service discovery, network alias, network mode, and `expose` fields as unsupported networking scope.
- Planning blocks desired host ports that conflict with observed non-target runtime services when live observation is supplied.
- Manifest-to-runtime mapping continues to emit explicit `127.0.0.1` publish bindings for Hostwright-created Apple containers.
- Observed runtime services carry reviewed fixture metadata plus real Apple container 1.0.0 hostname, IPv4/IPv6 address, gateway, MAC address, network name, and MTU fields.
- The Apple container observation parser accepts reviewed fixtures, empty/builder/legacy proof shapes, and exact labeled current-project Apple container 1.0.0 rows while ignoring unrelated labeled projects and failing closed on malformed current-project ownership.
- XCTest coverage covers bind normalization, broad-bind conflict behavior, unsupported discovery fields, observed port conflicts, fixture and real-network parsing, ownership labels, unrelated-project filtering, and malformed-network refusal.
- A live two-project proof parsed Apple container 1.0.0 network metadata and preserved all pre-existing runtime identifiers. End-to-end localhost HTTP remains blocked on this machine because macOS Local Network access for `container-runtime-linux` is disabled; no reachability pass is claimed.

Phase 22 does not add DNS behavior, service discovery, local reverse proxy mutation, tunnel integration, cloud exposure, public exposure defaults, network cleanup, runtime network mutation, release tags, or GitHub Releases.

## Phase 23 Outputs

- `docs/architecture/secure-exposure-research.md` records research-only decisions for Cloudflare Tunnel, Cloudflare Access/mTLS, Tailscale Serve/Funnel, WireGuard, local reverse proxying, mTLS, DNS, and cloud control plane scope.
- Cloudflare and Tailscale provider paths are rejected from current core scope and deferred only to explicit plugin or later prototype work behind policy, secret, DNS, auth, audit, and revocation gates.
- WireGuard and DNS/cloud-control-plane work are rejected from current core scope.
- Public docs continue to state that Hostwright does not currently support tunnels, cloud exposure, DNS management, reverse proxy setup, provider integration, or a cloud control plane.
- XCTest coverage guards the research record and unsupported-current-support wording.

Phase 23 does not add provider integration, provider credentials, tunnels, DNS behavior, reverse proxy mutation, cloud resources, product network calls, runtime mutation, release tags, or GitHub Releases.

## Phase 24 Outputs

- Added `HostwrightSecrets` with `HostwrightSecretReference`, `SecretStore`, a read-only noninteractive `MacOSKeychainSecretStore`, and an unavailable default CLI backend; deterministic tests inject a test-only in-memory store.
- Added service-level `secretEnv` for `keychain://<service>/<account>` references while keeping Compose/Kubernetes `secrets:` unsupported.
- Manifest validation rejects plaintext credential-like keys in `env`, malformed secret references, duplicate keys across `env` and `secretEnv`, and secret references placed under `env`.
- Apply resolves secret references through the injected backend immediately before confirmed create execution; the default unavailable backend fails before mutation.
- Runtime mutation rejects unresolved secret references as a final guard.
- Desired-state persistence, plans, errors, diagnostics, and observability redaction do not store or print resolved synthetic secret values or raw keychain reference labels.
- XCTest coverage covers real uniquely named local Keychain add/read/exact-delete/post-delete behavior, malformed Keychain data, secret reference parsing, in-memory store contracts, manifest validation, mapper redaction, apply resolution/failure, runtime guard, state redaction, observability redaction, and schema alignment.

Phase 24 does not enable the live backend by default, write or delete Keychain items in production code, present Keychain prompts, use access groups or synchronizable items, upload/sync credentials, add cloud identity or registry credential storage, mount secret files, add provider integration, expand runtime mutation, create release tags, or create GitHub Releases.

## Phase 25 Outputs

- Added optional top-level manifest `imagePolicy: allow-tags|require-digest`.
- Preserved `allow-tags` as the default for existing alpha manifests.
- Added local `@sha256:<64 lowercase hex characters>` image reference validation.
- `imagePolicy: require-digest` rejects mutable tag-only image references before planning or mutation.
- Schema and manifest tests cover the accepted and rejected image-policy shapes.
- Added a supply-chain image trust decision record covering OCI digest semantics, Sigstore/cosign, SBOM standards, vulnerability scanning, provenance, and source-build integrity boundaries.

Phase 25 does not add registry lookup, image pull, registry credentials, signature verification, SBOM generation/validation, vulnerability scanning, provenance verification, source-build automation, image replacement, image cleanup, runtime mutation expansion, release tags, or GitHub Releases.

## Phase 26 Outputs

- Added `ResourceIntelligenceReport` models for measurement method, hardware, OS, Apple container version evidence, workload profile, memory pressure, boot latency, polling overhead, sleep/wake, battery, thermal state, architecture warnings, and limits.
- `hostwright doctor --output json` can include a resource report from local ProcessInfo-backed host facts or deterministic test fixtures.
- Live doctor keeps Apple container version unavailable unless supplied by injected report data; it does not run Apple container commands.
- Architecture warnings are evidence-based and non-blocking, including Rosetta-risk wording only when a reported non-arm64 image architecture exists.
- Added fixture parser coverage and tests for unmeasured benchmark dimensions, no-capacity limits, and local-only/no-telemetry boundaries.
- Added a resource-intelligence methodology document with benchmark input requirements, blocked evidence, and rejected claims.

Phase 26 does not add runtime density measurement, VM-overhead benchmarking, boot-latency benchmarking, polling-overhead benchmarking, battery measurement, sleep/wake live proofing, workload memory-pressure benchmarking, automatic placement, capacity guarantees, GPU/ANE/Metal/Core ML/MLX support, accelerator scheduling, image pulls, Apple container command execution from doctor, runtime mutation expansion, release tags, or GitHub Releases.

## Phase 27 Outputs

- `docs/architecture/accelerator-boundary-research.md` records research-only decisions for Apple container accelerator passthrough, PyTorch MPS, MLX, Core ML, ANE, host-native accelerator helpers, read-only host accelerator detection, and scheduler accelerator dimensions.
- Current Apple-container accelerator claims are rejected until an official supported access path, versioned disposable proof, threat model, Phase 32 policy gate, and maintainer approval exist.
- Host-native accelerator helpers are deferred to plugin or later prototype work because they expand local auth, IPC, lifecycle, redaction, audit, data exposure, and cleanup scope.
- Scheduler accelerator dimensions remain blocked placeholders until an approved implementation proves accelerator access and measured capacity.
- Public limitations, security/safety notes, requirements, and acceptance gates keep GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator helpers, and accelerator-aware placement listed as unsupported current behavior.
- XCTest coverage guards the research decision and unsupported-current-support wording.

Phase 27 does not add GPU, ANE, Metal, Core ML, MLX, PyTorch MPS support, host accelerator device exposure, host-native services, read-only accelerator probes, accelerator scheduling, runtime mutation, image pulls, dependencies, release tags, or GitHub Releases.

## Phase 28 Outputs

- Added `HostwrightImport` with `StackFileImporter`, deterministic import diagnostics, policy reason-code propagation, and `HostwrightManifestEmitter`.
- Added `hostwright import-stack <path> [--output text|json]` as an import-only CLI command that prints converted `hostwright.yaml` text and never writes files.
- Supported only a narrow stack-file subset: project/name, services, image, inline-array command, key-value environment maps, string ports, explicit host-path volumes, `healthcheck.test: ["CMD", ...]`, health interval, and restart policy.
- Rejected unsupported or unsafe stack fields including `build`, `deploy`, `depends_on`, networking/discovery, secrets, configs, env files, named volumes, shell health checks, and cloud/tunnel semantics.
- Routed unsupported import diagnostics through local policy reason codes where applicable and then ran the converted manifest through the normal Hostwright validator.
- XCTest coverage covers golden conversion output, deterministic diagnostics, unsupported networking/secrets, named-volume and shell-healthcheck refusal, final manifest validation, CLI text output, CLI JSON output, and CLI JSON errors.

Phase 28 does not add general YAML parsing, Docker Compose parity, runtime compatibility, state writes, file writes, RuntimeAdapter calls, Apple container commands, registry calls, image pulls, DNS, tunnel, cloud, secrets/configs conversion, named volumes, runtime mutation, release tags, or GitHub Releases.

## Phase 29 Outputs

- `docs/architecture/external-orchestration-compatibility-research.md` records research-only decisions for CRI, Kubernetes node behavior, Docker API, Testcontainers target behavior, full Compose parity, attach, exec, log following, port forwarding, scheduler integration, lifecycle, networking, identity, and state semantics.
- CRI and Kubernetes node compatibility are rejected from current core scope because they require kubelet-facing runtime and image services, pod sandbox behavior, streaming setup, log semantics, node status, leases, scheduler accounting, and reconciliation contracts.
- Docker API and Testcontainers compatibility are rejected from current core scope because they require daemon-shaped API versioning, attach/log stream behavior, event streams, broad lifecycle, image, network, volume, and inspect semantics.
- Full Compose parity remains rejected from current core scope; Phase 28 remains an import-only reviewed subset with fail-closed unsupported-field behavior.
- External scheduler integration is deferred; Phase 31 may add advisory local scheduling, not an external orchestrator API.
- Public limitations, requirements, acceptance gates, and build status keep external orchestration compatibility listed as unsupported current behavior.
- XCTest coverage guards the research decision and unsupported-current-support wording.

Phase 29 does not add CRI, Kubernetes, Docker API, Compose parity, Testcontainers behavior, attach, exec, log following, port forwarding, external scheduler integration, runtime mutation, state writes, network calls, image pulls, dependencies, release tags, or GitHub Releases.

## Phase 30 Outputs

- `docs/architecture/multi-host-platform-research.md` records research-only decisions for multi-host Apple silicon identity, membership, local-network discovery, peer trust, transport security, state authority, replication, failure recovery, cloud boundary, and scheduler implications.
- Current core remains single-host because existing safety depends on one local permission envelope, explicit local state paths, local RuntimeAdapter behavior, local deterministic policy, and explicit mutation confirmation.
- Peer-to-peer control, LAN discovery, replicated state, remote control plane, and multi-host scheduler behavior are rejected from current core scope.
- Plugin, control-plane, or separate-project exploration is deferred and requires a separate maintainer-approved issue, threat model, and disposable proof.
- Public limitations, requirements, acceptance gates, and build status keep multi-host orchestration listed as unsupported current behavior.
- XCTest coverage guards the research decision and unsupported-current-support wording.

Phase 30 does not add multi-host orchestration, remote mutation, remote host agents, state replication, membership service, peer discovery, transport or certificate implementation, cloud control plane, DNS, tunnels, scheduler API, remote placement, runtime mutation expansion, state writes, network calls, image pulls, dependencies, release tags, or GitHub Releases.

## Phase 31 Outputs

- `Sources/HostwrightReconciler/AdvisoryScheduler.swift` and `AdvisorySchedulingModels.swift` add a deterministic in-memory advisory scheduler.
- Scheduler inputs include desired runtime state, optional observed runtime state, local resource report facts, explicit memory/workload-class/accelerator/remote-placement requests, and the local policy evaluator.
- Scheduler output is an `AdvisorySchedulingReport` with sorted recommendations, stable reason codes, blockers, warnings, remediations, scores, memory budget summary, and `advisoryOnly = true`.
- Policy integration carries existing local planner blockers and warnings into scheduler explanations without changing `ReconciliationPlan`, plan hashes, CLI output, RuntimeAdapter behavior, or state.
- Memory and overcommit checks use declared memory requests and local physical-memory facts only; missing facts block and missing service memory requests warn instead of inferring capacity.
- Workload class fairness lowers advisory scores when one declared class exceeds the local threshold, but does not enforce operating-system QoS, preemption, or fair share.
- Accelerator and remote-placement requirements are blockers.
- XCTest coverage proves deterministic recommendations, policy/port blockers, memory overcommit, accelerator blockers, fairness scoring, remote-placement blockers, and fail-closed missing memory evidence.

Phase 31 does not add automatic placement, capacity reservation, runtime mutation, RuntimeAdapter changes, SQLite access, state writes, daemon scheduling, scheduler API, external scheduler compatibility, Kubernetes scheduler behavior, multi-host scheduling, remote placement, DNS, tunnels, cloud behavior, registry calls, image pulls, telemetry upload, accelerator-aware scheduling, GPU/ANE/Metal/Core ML/MLX/PyTorch MPS support, third-party dependencies, release tags, or GitHub Releases.

## Phase 32 Outputs

- Added `HostwrightPolicy` with `LocalPolicyEvaluator`, `PolicyDecision`, categories, stable reason codes, severities, remediation text, and deterministic detail keys.
- Planner safety checks for desired identities, ports, exposure, mounts, and secret-like environment values now route through the policy evaluator before becoming reconciler `PlanIssue` values.
- Cleanup dry-run classification reasons now route through policy decisions while preserving exact ownership, adapter, service, lifecycle, dry-run, token, and confirmation gates.
- Policy APIs explain local image-policy failures, unresolved secret references, unsupported lifecycle requests, unsupported untrusted-manifest fields, secure exposure blockers, and accelerator blockers.
- XCTest coverage covers policy evaluation, redaction, cleanup classifications, image digest policy, unsupported exposure/lifecycle/accelerator decisions, and planner policy migration.

Phase 32 does not add remote policy service, team workflow, central policy distribution, silent bypass, runtime mutation from policy, Apple container shell-out from policy, SQLite access from policy, registry calls, image pulls, telemetry upload, DNS, tunnel, cloud, GUI, Kubernetes, CRI, Docker API, Compose parity, GPU/ANE/Metal/Core ML/MLX support, accelerator scheduling, release tags, or GitHub Releases.

## Phase 33 Outputs

- Added typed extension declaration models in `HostwrightPolicy` for extension kind, trust level, declaration API version, requested capabilities, purposes, and declared boundaries.
- Added `ExtensionPolicyEvaluator` for deterministic local `PolicyDecision` output.
- Built-in and reviewed-local non-mutating declarations can receive allow decisions only when required boundaries are declared.
- Third-party, untrusted, unsupported-version, empty, missing-boundary, runtime-mutation, state-write, networking-provider, tunnel-provider, secret-resolution, and accelerator declarations fail closed.
- `docs/architecture/plugin-extension-architecture.md` records the threat model, supported declaration-only scope, blocked capabilities, and future review requirements.
- XCTest coverage verifies allowed reviewed-local declarations, mutation blockers, untrusted tunnel/secret blockers, fail-closed empty declarations, and deterministic ordering.

Phase 33 does not add a plugin loader, remote plugin registry, binary plugin distribution, untrusted code execution, runtime mutation extension path, state-write extension path, networking provider behavior, tunnel/DNS/reverse proxy/cloud behavior, secret backend extension, accelerator extension, GUI code, direct Apple container shell-out, SQLite access outside `HostwrightState`, dependencies, release tags, or GitHub Releases.

## Phase 34 Outputs

- Added local team policy profile models in `HostwrightPolicy` for profile identity, version, opt-in, required safety gates, overrides, and approval records.
- Added `TeamWorkflowPolicyEvaluator` for deterministic local `PolicyDecision` output.
- Profiles fail closed when they are silent, unsupported-version, missing required gates, missing approval records for weakening overrides, or attempting forbidden hard safety-gate bypasses.
- Approved local review records produce warning decisions that document review without bypassing hard-coded safety gates.
- Existing append-only event ledger records persist team workflow audit events with redaction and explicit state paths.
- `docs/reference/team-workflow.md` documents local profiles, approval records, override policy, audit events, shared-machine expectations, and non-goals.

Phase 34 does not add a cloud team service, central remote control, hosted audit log, user tracking, enterprise support workflow, remote policy distribution, macOS user/group/ACL/keychain access group/MDM management, shared-secret management, runtime mutation expansion, direct Apple container shell-out, SQLite access outside `HostwrightState`, dependencies, release tags, or GitHub Releases.

## Phase 35 Outputs

- Added `docs/release/distribution-readiness.md` as the fail-closed artifact matrix and clean-tag checklist for future binary and installer releases.
- Documented signing, notarization, checksums, SBOM, provenance, installer, uninstaller, upgrade, downgrade, rollback, and package-channel evidence required before publication.
- Updated release process, install, security, limitations, requirements, acceptance, traceability, build status, and devlog docs.
- Added release-doc XCTest coverage that guards source-only current truth and blocks unsupported artifact claims.

Phase 35 does not produce binary archives, installer packages, install scripts, signed artifacts, notarized artifacts, SBOMs, provenance statements, Homebrew formulae, package-channel support, launch agents, release tags, GitHub Releases, dependencies, runtime mutation, direct Apple container shell-out, SQLite access outside `HostwrightState`, website work, or GUI code.

## Phase 36 Outputs

- Added `BenchmarkLabReport` models and parser validation for dry-run and fixture-backed benchmark reports.
- Added benchmark fixture coverage for environment facts, disposable-resource policy, measured/unmeasured dimensions, and unsafe policy rejection.
- Added `docs/architecture/benchmark-lab.md` and linked it from resource intelligence, compatibility, limitations, release process, requirements, acceptance, traceability, build status, and devlog docs.
- Added `scripts/lint.sh` to hosted CI after build and test.

Phase 36 does not add live benchmark command execution, Apple container commands, image pulls, runtime mutation, broad cleanup, state writes, cloud telemetry, hosted performance monitoring, benchmark number publication, performance marketing claims, dependencies, release tags, GitHub Releases, website work, or GUI code.

## Phase 37 Outputs

- Added `docs/architecture/documentation-site-public-education.md` with documentation-site information architecture, source-of-truth ownership, tutorial/task outlines, copy rules, release/limitations rules, blocked evidence, and rejected paths.
- Linked the source-of-truth plan from the README, limitations, release process, requirements, acceptance matrix, source traceability, build status, and devlog docs.
- Added core docs guard coverage so site planning cannot quietly become website implementation, hosted docs, analytics, search, or unsupported current-support claims.

Phase 37 does not add website frontend code, hosted docs deployment, website analytics, search, generated site content pipeline, product behavior, runtime mutation, RuntimeAdapter changes, SQLite access, dependencies, release tags, GitHub Releases, or GUI code.

## Phase 38 Outputs

- `GOVERNANCE.md` now defines maintainer authority, risky-area review ownership, decision-record triggers, issue/PR flow, release discipline, and support boundaries.
- `CONTRIBUTING.md`, `SECURITY.md`, the engineering issue template, and the pull request template now point contributors at the same verification and security-review expectations.
- Release docs now require governance and security-review checks before binary/distribution claims.
- Requirements and acceptance gates track governance as explicit release infrastructure instead of implicit maintainer knowledge.
- XCTest coverage guards the governance docs against unsupported support, telemetry, cloud, release-artifact, or bypass claims.

Phase 38 does not add CODEOWNERS enforcement, branch protection, new maintainers, product code, runtime mutation, dependencies, website implementation, GUI code, support SLA, cloud service, release tags, GitHub Releases, binary artifacts, signing, notarization, SBOM, or provenance claims.

## Phase 39 Outputs

- Added `docs/release/beta-readiness.md` with beta scope, required evidence, blockers, deferrals, release-note claim rules, clean-checkout smoke commands, state upgrade/downgrade policy, and maintainer decision checklist.
- Linked beta readiness from README, install, compatibility, limitations, release process, requirements, acceptance, traceability, build status, and devlog docs.
- Added core docs guard coverage so beta planning cannot become a beta tag, production claim, binary distribution claim, support SLA, compatibility expansion, telemetry upload, or unsupported current-support claim.

Phase 39 does not add beta tags, GitHub Releases, version bumps, binary artifacts, installers, Homebrew, signing, notarization, SBOM, provenance, production readiness, support SLA, product code, runtime mutation, RuntimeAdapter changes, SQLite access, dependencies, website/frontend work, telemetry upload, or GUI code.

## Phase 40 Outputs

- Added `docs/architecture/control-plane-direction.md` with the accepted direction: current core remains a single-host Apple silicon control plane through beta and first supported release work.
- Consolidated evidence from accelerator, external compatibility, multi-host, scheduler, benchmark, and beta-readiness phases.
- Rejected Kubernetes-class, CRI, Docker API, full Compose, cloud, multi-host, remote-placement, and accelerator-aware scheduling work from current core.
- Linked the direction from the README, charter, limitations, requirements, acceptance matrix, traceability, build status, and devlog docs.
- Added core docs guard coverage so direction planning cannot become current support or compatibility claims.

Phase 40 does not add cluster behavior, CRI, Kubernetes behavior, Docker API behavior, Compose parity, cloud control, remote host agents, state replication, membership, peer discovery, remote placement, accelerator access, accelerator-aware scheduling, product code, runtime mutation, RuntimeAdapter changes, SQLite changes, dependencies, release tags, GitHub Releases, website work, or GUI code.
