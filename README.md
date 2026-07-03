# Hostwright

Hostwright is a Mac-native desired-state control plane for Apple container workloads.

Tagline: Desired-state container control for Apple silicon Macs.

## Current Status

This repository contains the Hostwright core foundation: source-material preservation, documentation boundaries, a dependency-free Swift Package Manager package, CLI commands, a restricted `hostwright.yaml` manifest parser/validator, typed runtime contracts, deterministic planning, explicit SQLite state paths, read-only Apple container observation, and one narrow create-only apply gate.

Hostwright is not production ready. It does not implement general lifecycle management, multi-action apply, restart policy execution, cleanup, daemon reconciliation, DNS, tunnels, Kubernetes compatibility, a Docker API, or full Docker Compose parity.

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

The current canonical manifest shape is:

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

`RuntimeAdapter` defines the runtime boundary, runtime state models, command classification, timeout model, redaction policy, fake process runner, and mock adapter behavior.

Apple container read-only observation and create-only apply are implemented through this boundary. General mutation, restart, cleanup, and daemon reconciliation are not implemented.

## Source Material

The original planning, architecture, security, networking, production, naming, and brand-source materials are preserved under `docs/source-material/originals/` and `assets/brand/originals/`. The original root files are also preserved untouched from the initial normalization pass.
