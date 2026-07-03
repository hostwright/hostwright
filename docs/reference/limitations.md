# Limitations

Hostwright can model and attempt read-only runtime observation through `RuntimeAdapter`, persist desired and observed state to an explicit SQLite database path, compute non-mutating desired-vs-observed plans, and execute one tightly gated create-missing-service mutation through `RuntimeAdapter` when all confirmation and local-image gates pass.

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
- Verified real empty Apple container JSON list parsing for `container list --all --format json` output of `[]`.
- Verified real Apple builder-container list parsing as ignored non-Hostwright runtime state.
- Verified real created/stopped Hostwright proof container parsing.
- Verified real object-based Apple container image list parsing by `configuration.name`.
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
- `hostwright apply [path] --state-db <path> --confirm-plan <hash>` for create-only apply.
- Operation intent persistence before mutation.
- Apply success/failure event persistence.
- Runtime mutation policy for `createMissingService` only.
- One disposable live create proof for `hostwright-proof-web`, including stale-hash refusal and exact proof cleanup.
- Source-material preservation and Hostwright naming controls.

## Not Implemented Today

- General runtime mutation.
- Multi-action `hostwright apply`.
- Guaranteed Apple container observation on every machine.
- Broad non-empty Apple container JSON list parsing beyond the verified builder/proof shapes.
- Broad non-empty Apple container image list parsing beyond the verified object shape.
- Apple container start, stop, delete, restart, cleanup, log, or detailed inspect operations.
- Runtime mutation beyond create-missing-service.
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

The manifest parser is not a general YAML parser. It accepts only the documented Hostwright manifest subset and fails closed for unsupported YAML features. Expanding beyond that subset requires a dependency/design decision before the manifest surface grows.

## Runtime Truth

The runtime module contains read-only Apple container observation infrastructure, but the CLI still does not perform live runtime observation by default. `hostwright plan` renders deterministic desired-state and policy planning output. `hostwright status` remains manifest-level output only. Neither command proves that services are running, stopped, healthy, unhealthy, created, deleted, or reachable unless explicit observed state is supplied through library APIs.

The runtime parser accepts the fixture-defined `hostwright.apple-container.observation.v1` schema, the verified real empty JSON array shape returned by `container list --all --format json`, Apple builder container output that is ignored, and the verified `hostwright-proof-web` created/stopped output. Unsupported, malformed, or broader real Apple container JSON output fails closed with redacted errors.

Create-only apply is not general lifecycle management. It uses `container create` only after explicit plan confirmation, operation intent persistence, local image confirmation, and safe-subset validation. The live proof created exactly one disposable `hostwright-proof-web` container and then removed that exact proof container and image.

## State Truth

The SQLite store writes only to explicit paths supplied by the caller. Hostwright does not choose a default path under the repository, Application Support, XDG locations, or any global directory.

Hostwright persists adapter-shaped observed state and can consume runtime-shaped observed state in memory for planning. Apply writes state only to explicit `--state-db` paths. It does not add a default state path, cleanup, a daemon loop, or production durability guarantees.
