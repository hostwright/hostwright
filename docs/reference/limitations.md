# Limitations

Hostwright is in Phase 7 deterministic planning and drift detection state. It can model and attempt read-only runtime observation through `RuntimeAdapter`, persist desired and observed state to an explicit SQLite database path, and compute non-mutating desired-vs-observed plans.

## Implemented Today

- Dependency-free CLI command routing.
- `hostwright --version`.
- `hostwright init` without overwrite.
- `hostwright validate` for a restricted Hostwright manifest subset.
- `hostwright plan` as non-mutating manifest-level dry-run output.
- `hostwright status` as manifest-level status only.
- `hostwright doctor` safe local checks.
- Swift Package Manager module boundaries.
- RuntimeAdapter contract infrastructure, state scaffolds, reconciler scaffolds, health models, networking scaffolds, and observability scaffolds.
- `MockRuntimeAdapter` and fake runtime process runner for tests only.
- `AppleContainerReadOnlyAdapter` for read-only observation attempts through `RuntimeAdapter`.
- `FoundationRuntimeProcessRunner` guarded by read-only command classification, executable resolution, timeouts, and redaction.
- Fixture-defined Apple container observation parser for empty and running snapshots.
- SQLite state store using system `SQLite3`.
- Explicit schema migrations.
- Desired-state snapshot persistence.
- Observed runtime snapshot persistence.
- Event ledger persistence.
- Operation ledger records for future mutation safety.
- Ownership records for future cleanup/apply decisions.
- Explicit-path state configuration only.
- Manifest-to-runtime desired-state mapping outside the CLI.
- Typed deterministic drift records, plan issues, planned actions, and plan hash.
- Planning policy checks for duplicate host ports, unsafe broad bind addresses, privileged host ports, unsafe root mounts, ambiguous mounts, invalid identities, and secret-like environment values.
- Drift detection for missing, unmanaged, stopped, exited, failed, image mismatch, port mismatch, mount mismatch, unhealthy, duplicate observed identity, unsupported observed state, and unavailable observation cases.
- Source-material preservation and Hostwright naming controls.

## Not Implemented Today

- Runtime mutation.
- `hostwright apply`.
- Guaranteed Apple container observation on every machine.
- Apple container start, stop, create, delete, restart, cleanup, log, or detailed inspect operations.
- Apple container mutation of any kind.
- Runtime mutation based on drift plans.
- Daemon scheduling loop.
- Health check execution.
- Restart policy execution.
- Status based on observed runtime state.
- Cleanup, teardown, garbage collection, or ownership-based deletion.
- Default user database path.
- Hidden global state writes.
- Production durability, backup, or corruption-recovery guarantees.
- Launch agent or service installer.
- DNS behavior.
- Tunnel management.
- Cloud control plane.
- Web dashboard.
- Production readiness.

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

The Phase 2 parser is not a general YAML parser. It accepts only the documented Hostwright manifest subset and fails closed for unsupported YAML features. Expanding beyond that subset requires a dependency/design decision before the manifest surface grows.

## Runtime Truth

The runtime module contains read-only Apple container observation infrastructure, but the CLI still does not perform live runtime observation by default. `hostwright plan` renders deterministic desired-state and policy planning output. `hostwright status` remains manifest-level output only. Neither command proves that services are running, stopped, healthy, unhealthy, created, deleted, or reachable unless explicit observed state is supplied through library APIs.

The Phase 5 parser accepts only the fixture-defined `hostwright.apple-container.observation.v1` schema. Unsupported or malformed output fails closed with redacted errors. Runtime mutation begins only in Phase 8.

## State Truth

The Phase 6 SQLite store writes only to explicit paths supplied by the caller. Hostwright does not choose a default path under the repository, Application Support, XDG locations, or any global directory.

Phase 6 persists adapter-shaped observed state. Phase 7 can consume runtime-shaped observed state in memory for planning, but it does not add a default state path, a state-backed CLI observation flow, Phase 8 apply, cleanup, a daemon loop, or production durability guarantees.
