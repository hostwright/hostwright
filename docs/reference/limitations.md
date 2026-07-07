# Limitations

Hostwright `v0.1.0-alpha.1` can model and attempt read-only runtime observation through `RuntimeAdapter`, persist desired and observed state to an explicit SQLite database path, compute deterministic desired-vs-observed plans, execute one tightly gated create-missing-service mutation, execute one restart-policy-allowed managed start, execute one restart-policy-allowed managed restart for an exact Hostwright-owned running/unhealthy service, read bounded logs, render and filter state events, write a local redacted diagnostics bundle, run a foreground daemon loop with in-process loopback health probes and restart-state blocking, and delete exact cleanup-eligible Hostwright-owned stopped/created/exited containers through `RuntimeAdapter`.

Hostwright is not production ready.

## Implemented Today

- Dependency-free CLI command routing.
- `hostwright --version`.
- `hostwright init` without overwrite.
- `hostwright validate` for a restricted Hostwright manifest subset.
- Manifest `version: 1` support with versionless alpha manifests treated as legacy version 1 input.
- Fail-closed unsupported-field, unsupported-version, unsafe env-key, and unsafe host-root or parent-traversal mount-source validation for untrusted manifests.
- `hostwright plan` as non-mutating manifest-level dry-run output.
- `--output json` for `plan`, `status`, `events`, `recovery`, `doctor`, and structured errors when JSON mode is requested.
- Stable process exit categories for usage, validation, state unavailable, runtime unavailable, confirmation mismatch, unsafe operation, and partial failure.
- `hostwright status [path] --state-db <path>` with live RuntimeAdapter observation and event/snapshot persistence.
- `hostwright logs <service>` with bounded tail output through RuntimeAdapter and redaction.
- `hostwright events --state-db <path>` for persisted event ledger records, with project/type/service/severity/limit/sort filtering.
- `hostwright diagnostics --state-db <path> --bundle <path>` for a local redacted JSON bundle from existing state rows.
- `hostwright cleanup` dry-run classification and exact token-confirmed deletion of eligible Hostwright-owned stopped/created/exited containers.
- `hostwrightd --foreground --config <path> --state-db <path>` for a local foreground development loop that observes, plans, and records daemon events without runtime mutation.
- In-process loopback health checks from `health.command` for allowlisted probe command shapes and arguments, with redacted result/event persistence.
- Restart policy state with max attempts, backoff, manual-disable from `restart.policy: no`, preexisting operator hold state, and crash-loop blocking before managed start or managed restart is exposed as executable.
- `hostwright doctor` safe local checks.
- Source-only release candidate packaging for `v0.1.0-alpha.1`.
- Swift Package Manager module boundaries.
- RuntimeAdapter contract infrastructure, state scaffolds, reconciler scaffolds, health models, networking scaffolds, and observability scaffolds.
- `MockRuntimeAdapter` and fake runtime process runner for tests only.
- `AppleContainerReadOnlyAdapter` for read-only observation attempts through `RuntimeAdapter`.
- `FoundationRuntimeProcessRunner` guarded by read-only command classification, executable resolution, timeouts, and redaction.
- Fixture-defined Apple container observation parser for empty and running snapshots.
- Verified real empty Apple container JSON list parsing for `container list --all --format json` output of `[]`.
- Verified real Apple builder-container list parsing as ignored non-Hostwright runtime state.
- Verified real created/stopped Hostwright proof container parsing.
- Verified real object-based Apple container image list parsing by `configuration.name`.
- SQLite state store using system `SQLite3`.
- Explicit schema migrations.
- State migration checksums, future-schema refusal, and actionable locked/corrupt database errors.
- Repository state reads validate schema without implicitly creating or migrating databases.
- Desired-state snapshot persistence.
- Observed runtime snapshot persistence.
- Event ledger persistence.
- Operation ledger records for future mutation safety.
- Ownership records for cleanup/apply decisions.
- Health check result records.
- Restart policy state records.
- Restart recovery records for managed restart attempts.
- Operation recovery groups and step records for apply checkpoints, partial failures, interruption diagnostics, and manual recovery hints.
- Local-only telemetry policy reporting in doctor/status/diagnostics output.
- Explicit-path state configuration only.
- Manifest-to-runtime desired-state mapping outside the CLI.
- Typed deterministic drift records, plan issues, planned actions, and plan hash.
- Planning policy checks for duplicate host ports, unsafe broad bind addresses, privileged host ports, unsafe host-root or parent-traversal mount sources, ambiguous mounts, invalid identities, and secret-like environment values.
- Hostwright-created Apple container port publishes are explicitly localhost-scoped by default.
- Drift detection for missing, unmanaged, stopped, exited, failed, image mismatch, port mismatch, mount mismatch, unhealthy, duplicate observed identity, unsupported observed state, and unavailable observation cases.
- `hostwright apply [path] --state-db <path> --confirm-plan <hash>` for one create-missing-service action, one restart-policy-allowed managed start action, or one restart-policy-allowed managed restart action.
- Operation intent persistence before mutation.
- Apply success/failure event persistence.
- Runtime mutation policy for `createMissingService`, `startManagedService`, `restartManagedService`, and `deleteManagedContainer`.
- Disposable live create/start/logs/cleanup proofs for Hostwright-owned proof containers, including stale-hash refusal and exact proof cleanup.
- Cleanup dry-run classifications for eligible, ambiguous, stale, running, unknown, blocked, and never-delete ownership-backed and observed-only resources.
- Source-material preservation and Hostwright naming controls.

## Not Implemented Today

- General runtime mutation.
- Automatic manifest upgrade, downgrade, or compatibility conversion.
- General YAML parsing or full orchestrator schema compatibility.
- Multi-action `hostwright apply`.
- Guaranteed Apple container observation on every machine.
- Broad non-empty Apple container JSON list parsing beyond the verified builder/proof shapes.
- Broad non-empty Apple container image list parsing beyond the verified object shape.
- JSON output for `validate`, `apply`, `logs`, and `cleanup` success paths.
- Shell completion installation or shell profile mutation.
- User-facing Apple container stop/restart commands, remove, broad cleanup, image deletion, volume deletion, log follow, attach, exec, or detailed inspect operations.
- Automatic rollback or inverse runtime mutation after partial failure.
- Runtime mutation beyond create-missing-service, managed start, managed restart, and exact cleanup-eligible container delete.
- Container-exec or interactive health checks.
- Aggressive restart loops or daemon-enforced restart mutation.
- Background daemon service, launch agent installation, keepalive, or unattended runtime mutation.
- Broad cleanup, teardown, garbage collection, image deletion, volume deletion, or unmanaged deletion.
- Default user database path.
- Hidden global state writes.
- Production durability or automatic corruption-recovery guarantees.
- Online state backup, restore, or repair commands.
- External telemetry, hosted diagnostics, automatic bundle upload, OSLog integration, or production support-bundle workflows.
- Launch agent or service installer.
- DNS behavior.
- Tunnel management.
- Cloud control plane.
- Web dashboard.
- Production readiness.
- Binary downloads, installer packages, Homebrew formulae, signing, notarization, SBOM, or binary provenance.

## Explicitly Out Of Scope For The First Supported Release

- CRI shim.
- Kubernetes compatibility.
- Kubernetes API server.
- Kubelet replacement.
- Kubernetes scheduler.
- PodSandbox compatibility.
- CNI support.
- Full Docker Compose parity.
- Docker API shim.
- Testcontainers compatibility.
- Multi-Mac orchestration.
- Local DNS resolver.
- Cloudflare, Tailscale, WireGuard, or other tunnel integration.
- Cloud control plane.
- GPU/ANE scheduling.
- Metal, Core ML, or MLX container support promises.
- Automatic destructive garbage collection.
- Privileged helper unless a future design record and threat model prove it is necessary.

## Parser Limitation

The manifest parser is not a general YAML parser. It accepts only the documented Hostwright manifest subset and fails closed for unsupported YAML features, unsupported manifest versions, unknown Kubernetes/Compose-style fields, unsafe environment keys, and unsafe host-root or parent-traversal mount sources. Expanding beyond that subset requires a dependency/design decision before the manifest surface grows.

## Runtime Truth

The runtime module contains Apple container observation infrastructure and narrow mutation command descriptors. `hostwright plan` renders deterministic desired-state and policy planning output without live runtime observation by default. `hostwright status --state-db <path>` performs live RuntimeAdapter observation and records a status event. Status still does not prove reachability or application-level health beyond the observed runtime state.

The runtime parser accepts the fixture-defined `hostwright.apple-container.observation.v1` schema, the verified real empty JSON array shape returned by `container list --all --format json`, Apple builder container output that is ignored, and the verified `hostwright-proof-web` created/stopped output. Unsupported, malformed, or broader real Apple container JSON output fails closed with redacted errors.

Apply is not general lifecycle management. It uses `container create` only after explicit plan confirmation, idempotency checks, operation intent persistence, local image confirmation, and safe-subset validation. Created port bindings are emitted as explicit `127.0.0.1:host:container` publishes. It uses `container start <id>` only for one observed Hostwright-owned stopped/created/exited service when restart policy allows a managed start. It uses an internal `container stop <id>` then `container start <id>` sequence only for one exact Hostwright-owned running service when restart policy allows managed restart, the explicit state database has a fresh unhealthy health result for the service, and recovery records are written. Cleanup uses `container delete <id>` only after dry-run token confirmation and ownership/live-state eligibility checks.

Recovery is diagnostic and manual. `hostwright recovery` reads operation groups and steps from the explicit state database and reports whether an apply operation completed, failed, or was interrupted. It does not observe Apple container, retry mutation, stop/start/delete resources, or roll back changes automatically.

Diagnostics are local and manual. `hostwright diagnostics` reads existing state rows from the explicit state database and writes a redacted JSON bundle to an explicit file path. It does not observe Apple container, run health checks, create or migrate a missing database, overwrite existing bundle files, upload telemetry, or prove service reachability.

## State Truth

The SQLite store writes only to explicit paths supplied by the caller. Hostwright does not choose a default path under the repository, Application Support, XDG locations, or any global directory.

Hostwright persists adapter-shaped observed state and can consume runtime-shaped observed state in memory for planning. Apply, status, logs, events, diagnostics, cleanup, and foreground `hostwrightd` write or read state only through explicit `--state-db` paths. Hostwright does not add a default state path, background daemon service, unattended mutation, broad cleanup, external telemetry, or production durability guarantees.
