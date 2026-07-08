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
| 14 | State Migrations and Upgrade Safety | Complete locally | Harden state migrations, compatibility, corruption handling, and locking. | Fresh, existing, future-version, corrupt, locked, checksum-mismatch, rollback, unrelated database, and repeated migration cases are tested. |
| 15 | Local Daemon Reconciliation Loop | Complete locally | Turn `hostwrightd` into explicit foreground dev-mode reconciliation only. | Fake-clock loop, backoff, lock, shutdown, and sleep/wake behavior pass without unattended mutation. |
| 16 | Health Checks and Restart Policy Expansion | Complete locally | Add bounded health execution and crash-loop-aware restart policy state. | Health results, max attempts, backoff, manual disable, preexisting operator hold blocking, crash-loop blocking, and redacted events are tested. |
| 17 | Managed Restart | Complete locally | Add one narrow Hostwright-owned restart path as an explicit stop-then-start sequence. | Ownership, running observed state, plan hash, operation ledger, recovery record, and fake-runner tests pass. |
| 18 | Rollback and Partial Failure Recovery | Complete locally | Model operation groups, locks, checkpoints, interruption recovery, and manual recovery hints. | Partial failure and crash/interruption records explain what changed and what remains manual. |
| 19 | Cleanup and Garbage Collection Maturity | Complete locally | Improve cleanup classification, ownership mismatch handling, stale ID protection, and partial failure behavior. | Dry-run classifications and exact delete boundaries pass without image, volume, or unmanaged deletion. |
| 20 | Observability and Diagnostics | Complete locally | Add redacted diagnostics, local-only telemetry policy, audit trail, event filtering, and improved doctor/status output. | Diagnostic bundles, redaction, event ordering/filtering, and local-only telemetry policy are tested. |
| 21 | API and GUI Readiness Gate | Deferred | Revisit after core contracts for networking, policy, import, compatibility, multi-host research, and scheduling are in place. | No Phase 21 work starts until the maintainer explicitly opens it. |
| 22 | Networking and Service Discovery | Complete locally | Harden local networking policy and document unsupported discovery/exposure boundaries. | Localhost publish defaults, duplicate/observed port conflicts, unsupported discovery fields, and fixture-only network metadata are tested. |
| 23 | Secure Exposure Research | Complete locally | Decide tunnel, VPN, mTLS, reverse proxy, DNS, and cloud exposure boundaries before any implementation. | Decision record rejects or defers every secure exposure path and tests guard unsupported current-support claims. |
| 24 | Secrets, Credentials, And Keychain Boundary | Complete locally | Add local secret references, fake Keychain backend, unavailable live backend, and redaction hardening. | `secretEnv`, fake backend resolution, fail-closed unavailable backend, and redacted state/diagnostics/plans pass tests. |
| 25 | Supply Chain And Image Trust | Complete locally | Add local image digest-reference policy and document trust-tool boundaries. | `imagePolicy: require-digest`, digest syntax validation, schema alignment, docs boundary, and overclaim tests pass without registry calls or scanner/signing dependencies. |

## Current Hard Boundaries

- Apple container mutation is limited to create-missing-service, restart-policy-allowed managed start, restart-policy-allowed managed restart, and exact cleanup-eligible managed container delete.
- Live Apple container read-only execution exists behind the RuntimeAdapter path.
- `hostwright apply` requires explicit `--state-db` and `--confirm-plan`.
- `hostwright cleanup` requires explicit `--state-db`, dry-run planning, a matching cleanup token, ownership records, live observation, exact resource identifiers, and a non-running lifecycle.
- No user-facing stop/restart command, image replacement, port mutation, mount mutation, image cleanup, volume cleanup, unmanaged cleanup, aggressive restart loop, DNS, tunnel, cloud, GPU/ANE, privileged helper, launch agent, or installer behavior is implemented.
- `hostwrightd --foreground` can observe, run bounded health checks, plan, and record daemon loop events only; it does not perform unattended runtime mutation.
- Phase 6 state writes require explicit database paths; no default user database path exists.
- State repository reads validate schema without implicit migration; `SQLiteStateStore.migrate()` is the explicit migration path.
- Planning is deterministic and non-mutating.
- Apply executes at most one supported action and refuses every other planned action.
- Manifest parsing remains a restricted Hostwright subset, not general YAML or Compose parity.
- Explicit `version: 1` manifests are supported; omitted version is legacy v1 input; explicit older/newer versions fail closed with no automatic conversion.
- Networking remains local-first: Hostwright-created publishes use `127.0.0.1`, observed host-port conflicts block planning, and DNS/service discovery/reverse proxy/tunnel/cloud exposure remain unsupported.
- Image trust remains local-first: `imagePolicy: require-digest` validates `@sha256` reference syntax only and does not resolve registries, pull images, verify signatures, scan vulnerabilities, generate SBOMs, or prove provenance.

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

## Phase 14 Outputs

- Migration records use deterministic checksums while retaining compatibility with the historical Phase 6 v1 checksum.
- Explicit migration refuses unrelated existing SQLite databases, future schema versions, and checksum mismatches.
- Repository reads and writes validate already-applied schema instead of applying migrations implicitly.
- SQLite errors classify locked and corrupt/non-SQLite databases as actionable state failures.
- State docs define backup, restore, debug export, downgrade/future-version, corruption recovery, and locking policy.
- XCTest coverage for repeated migrations with data, transaction rollback, read-side-effect prevention, future schemas, checksum mismatch, unrelated databases, corrupt databases, and lock contention.

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
- Runtime execution remains a narrow internal stop-then-start sequence for the exact Hostwright-managed container identifier; no public stop or restart command is added.
- SQLite schema v3 adds append-only restart recovery records with redacted manual recovery hints and completed-step metadata.
- Apply records operation intent before mutation, success/failure operation status after mutation, restart recovery records, restart policy state, and redacted events.
- XCTest coverage covers planner gating, ownership refusal, fresh/stale persisted health handling, status/apply plan-hash parity, successful managed restart, failed managed restart recovery hints/backoff, partial stop-success/start-failure records, runtime command policy, and fake-runner stop-then-start sequencing.

Phase 17 does not add broad lifecycle management, daemon-enforced restart loops, a public stop/restart command, image replacement, image cleanup, volume cleanup, unmanaged cleanup, release tags, or GitHub Releases.

## Phase 18 Outputs

- SQLite schema v4 adds operation groups and operation group steps for apply recovery state.
- Apply acquires an active operation group before runtime mutation, records a rollback-unsupported step, records forward runtime steps, and finishes the group as succeeded, failed, or interrupted.
- Operation groups carry a group idempotency key, lease fields, current checkpoint, rollback availability flag, and redacted manual recovery hints; expired active leases are marked interrupted before reacquire.
- Operation group steps carry step idempotency keys, forward/rollback direction, started/completed/failed/unsupported status, redacted resource identifiers, and redacted failure hints.
- `hostwright recovery --state-db <path> [--project <name>] [--output text|json]` renders recovery guidance from the explicit state database without observing or mutating the runtime, including legacy managed restart recovery rows when no Phase 18 operation group exists for that operation.
- XCTest coverage covers operation group acquire/release behavior, stale active lease expiration, step append/reload behavior, redaction, apply success/failure/interrupted state, pre-runtime persistence interruption, managed restart stop-success/start-failure recovery steps, read-only recovery behavior, legacy restart recovery rendering, and recovery JSON rendering.

Phase 18 does not add automatic rollback, inverse runtime mutation, multi-action apply, unattended daemon mutation, broad lifecycle commands, image cleanup, volume cleanup, unmanaged cleanup, release tags, or GitHub Releases.

## Phase 19 Outputs

- `hostwright cleanup --dry-run` now classifies ownership-backed and observed-only cleanup assessments as eligible, ambiguous, stale, running, unknown, blocked, or never-delete.
- Confirmation tokens are derived from eligible candidate identity, lifecycle, runtime adapter, and resource identifier so relevant drift invalidates stale cleanup confirmation.
- Confirmed cleanup still deletes only eligible exact Hostwright-owned created/stopped/exited containers through `RuntimeAdapter`.
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

## Phase 22 Outputs

- Shared local bind-address policy normalizes localhost, recognizes broad bind addresses, and detects host-port conflicts involving wildcard binds.
- Manifest parsing now reports DNS, service discovery, network alias, network mode, and `expose` fields as unsupported networking scope.
- Planning blocks desired host ports that conflict with observed non-target runtime services when live observation is supplied.
- Manifest-to-runtime mapping continues to emit explicit `127.0.0.1` publish bindings for Hostwright-created Apple containers.
- Observed runtime services can carry versioned fixture network attachment metadata: name, kind, address, gateway, and interface.
- The Apple container observation parser continues to accept reviewed fixtures and verified empty/builder/proof real shapes; non-empty real network output fails closed until reviewed.
- XCTest coverage covers bind normalization, broad-bind conflict behavior, unsupported discovery fields, observed port conflicts, network fixture parsing, and non-empty real network-output refusal.

Phase 22 does not add DNS behavior, service discovery, local reverse proxy mutation, tunnel integration, cloud exposure, public exposure defaults, network cleanup, runtime network mutation, release tags, or GitHub Releases.

## Phase 23 Outputs

- `docs/architecture/secure-exposure-research.md` records research-only decisions for Cloudflare Tunnel, Cloudflare Access/mTLS, Tailscale Serve/Funnel, WireGuard, local reverse proxying, mTLS, DNS, and cloud control plane scope.
- Cloudflare and Tailscale provider paths are rejected from current core scope and deferred only to explicit plugin or later prototype work behind policy, secret, DNS, auth, audit, and revocation gates.
- WireGuard and DNS/cloud-control-plane work are rejected from current core scope.
- Public docs continue to state that Hostwright does not currently support tunnels, cloud exposure, DNS management, reverse proxy setup, provider integration, or a cloud control plane.
- XCTest coverage guards the research record and unsupported-current-support wording.

Phase 23 does not add provider integration, provider credentials, tunnels, DNS behavior, reverse proxy mutation, cloud resources, product network calls, runtime mutation, release tags, or GitHub Releases.

## Phase 24 Outputs

- Added `HostwrightSecrets` with `HostwrightSecretReference`, `SecretStore`, `FakeKeychainSecretStore`, and an unavailable default Keychain backend.
- Added service-level `secretEnv` for `keychain://<service>/<account>` references while keeping Compose/Kubernetes `secrets:` unsupported.
- Manifest validation rejects plaintext credential-like keys in `env`, malformed secret references, duplicate keys across `env` and `secretEnv`, and secret references placed under `env`.
- Apply resolves secret references through the injected backend immediately before confirmed create execution; the default unavailable backend fails before mutation.
- Runtime mutation rejects unresolved secret references as a final guard.
- Desired-state persistence, plans, errors, diagnostics, and observability redaction do not store or print resolved fake secret values or raw keychain reference labels.
- XCTest coverage covers secret reference parsing, fake backend behavior, manifest validation, mapper redaction, apply resolution/failure, runtime guard, state redaction, observability redaction, and schema alignment.

Phase 24 does not add live Keychain access, Keychain prompts, access groups, synchronizable items, credential upload/sync, cloud identity, registry credential storage, mounted secret files, provider integration, runtime mutation expansion, release tags, or GitHub Releases.

## Phase 25 Outputs

- Added optional top-level manifest `imagePolicy: allow-tags|require-digest`.
- Preserved `allow-tags` as the default for existing alpha manifests.
- Added local `@sha256:<64 lowercase hex characters>` image reference validation.
- `imagePolicy: require-digest` rejects mutable tag-only image references before planning or mutation.
- Schema and manifest tests cover the accepted and rejected image-policy shapes.
- Added a supply-chain image trust decision record covering OCI digest semantics, Sigstore/cosign, SBOM standards, vulnerability scanning, provenance, and source-build integrity boundaries.

Phase 25 does not add registry lookup, image pull, registry credentials, signature verification, SBOM generation/validation, vulnerability scanning, provenance verification, source-build automation, image replacement, image cleanup, runtime mutation expansion, release tags, or GitHub Releases.
