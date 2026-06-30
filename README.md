# Hostwright

Hostwright is a Mac-native desired-state control plane for Apple container workloads.

Tagline: Desired-state container control for Apple silicon Macs.

## Current Status

This repository is in Phase 4 RuntimeAdapter contract infrastructure state. It contains the normalized project structure, source-material preservation log, documentation boundaries, a dependency-free Swift Package Manager skeleton, non-mutating CLI commands, a restricted `hostwright.yaml` manifest parser/validator, and typed runtime contract models with mock adapter coverage.

Hostwright is not production ready. It does not yet mutate runtime state, apply plans, observe Apple container workloads, execute live runtime commands, install a daemon, manage DNS, create tunnels, implement Kubernetes compatibility, expose a Docker API, or provide full Docker Compose parity.

## First Supported Release Boundary

The first supported release is scoped to one local Mac:

- Swift CLI named `hostwright`.
- Swift daemon concept named `hostwrightd`.
- Manifest named `hostwright.yaml`.
- RuntimeAdapter boundary for all runtime operations.
- Apple container CLI adapter first, after local behavior is verified.
- SQLite-backed local state store design.
- Desired-state reconciliation design.
- Health checks, restart policy, drift detection, status/events/logs interfaces.
- `hostwright doctor` design.
- Safe cleanup and dry-run behavior.
- macOS 26+ and Apple silicon compatibility gate.
- Conservative validation for images, ports, volumes, env, and runtime assumptions.

## Explicit Non-Goals

Hostwright is not:

- a CRI shim;
- a Kubernetes API server;
- a kubelet replacement;
- a Kubernetes scheduler;
- a Docker API shim;
- full Docker Compose parity;
- Testcontainers compatibility;
- a cloud control plane;
- multi-Mac orchestration;
- local DNS or tunnel management;
- GPU/ANE/Metal/Core ML/MLX container support;
- a privileged helper or installer.

## Local Development

Build and test:

```bash
swift build
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

Run the CLI:

```bash
swift run hostwright -- --version
swift run hostwright -- init
swift run hostwright -- validate
swift run hostwright -- plan
swift run hostwright -- status
swift run hostwright -- doctor
swift run hostwrightd
```

`hostwright` commands are non-mutating except `init`, which creates `hostwright.yaml` only when absent. `hostwrightd` does not install a launch agent or start a runtime loop.

## Manifest

Phase 2 uses this canonical manifest shape:

```yaml
project: api-local

services:
  api:
    image: ghcr.io/example/api:latest
    ports:
      - "8080:8080"
```

The current parser is a restricted Hostwright manifest subset parser, not a general YAML parser.

## Runtime Boundary

Phase 4 defines the `RuntimeAdapter` contract, runtime state models, command classification, timeout model, redaction policy, fake process runner, and mock adapter behavior. These are contract and test foundations only.

Apple container read-only observation begins in a later phase. Runtime mutation and `apply` begin only after observation, state, planning, and safety gates are implemented.

## Source Material

The original planning, architecture, security, networking, production, naming, and brand-source materials are preserved under `docs/source-material/originals/` and `assets/brand/originals/`. The original root files are also preserved untouched during Phase 0.
