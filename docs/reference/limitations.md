# Limitations

Hostwright is in Phase 3 alignment and test-foundation state. Phase 3 adds source-grounded requirements and acceptance gates. It does not add runtime behavior.

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
- Source-material preservation and Hostwright naming controls.

## Not Implemented Today

- Runtime mutation.
- `hostwright apply`.
- Apple container observation.
- Apple container start, stop, create, delete, restart, cleanup, log, or inspect operations.
- Live RuntimeAdapter process execution.
- SQLite schema, migrations, durable state, or database files.
- Desired-vs-observed drift detection from real runtime state.
- Daemon scheduling loop.
- Health check execution.
- Restart policy execution.
- Status based on observed runtime state.
- Events persisted to a local event ledger.
- Cleanup, teardown, garbage collection, or ownership-based deletion.
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

No current command observes Apple container runtime state. `hostwright plan` and `hostwright status` must be read as manifest-level outputs only. They do not prove that services are running, stopped, healthy, unhealthy, created, deleted, or reachable.

Phase 4 adds runtime contract infrastructure only. It does not execute Apple container commands. Apple container observation begins in Phase 5. Runtime mutation begins only in Phase 8.
