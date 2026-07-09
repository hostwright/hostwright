# Hostwright

Hostwright is a Mac-native desired-state control plane for Apple container workloads.

Tagline: Desired-state container control for Apple silicon Macs.

## Current Status

This repository contains the Hostwright core foundation: source-material preservation, documentation boundaries, a dependency-free Swift Package Manager package, CLI commands, a restricted `hostwright.yaml` manifest parser/validator, typed runtime contracts, deterministic planning, explicit SQLite state paths, Apple container observation, a narrow confirmed apply gate, bounded logs, event rendering, foreground daemon reconciliation with in-process loopback health probes and restart-state blocking, managed restart recovery records, and ownership-gated cleanup for exact stopped/created/exited containers.

Hostwright `v0.1.0-alpha.1` is a source-only alpha release candidate. Hostwright is not production ready. It does not implement general lifecycle management, multi-action apply, daemon restart loops, user-facing stop/restart commands, image replacement, image/volume cleanup, unattended daemon mutation, DNS, tunnels, Kubernetes compatibility, a Docker API, or full Docker Compose parity.

## Release Candidate

- First public release target: `v0.1.0-alpha.1`.
- Release title: `Hostwright v0.1.0-alpha.1`.
- Release type: GitHub pre-release.
- Artifact policy: source-only.
- Binary downloads, installers, Homebrew formulae, signing, and notarization are not provided for this alpha.

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

Build from the public alpha tag after it exists:

```bash
git clone https://github.com/hostwright/hostwright.git
cd hostwright
git checkout v0.1.0-alpha.1
swift build
swift test
```

Run the CLI:

```bash
swift run hostwright --version
swift run hostwright init
swift run hostwright validate
swift run hostwright plan
swift run hostwright status --state-db /tmp/hostwright.sqlite
swift run hostwright logs api --state-db /tmp/hostwright.sqlite
swift run hostwright events --state-db /tmp/hostwright.sqlite
swift run hostwright cleanup --state-db /tmp/hostwright.sqlite --dry-run
swift run hostwright doctor
swift run hostwrightd --foreground --config hostwright.yaml --state-db /tmp/hostwright.sqlite --max-iterations 1
```

`hostwright` mutates runtime only through explicit `apply --state-db <path> --confirm-plan <hash>` and `cleanup --state-db <path> --confirm-cleanup <token>` gates. `hostwrightd` does not install a launch agent and does not perform unattended runtime mutation.

More detail:

- Install/build instructions: `docs/reference/install.md`.
- Compatibility matrix: `docs/reference/compatibility.md`.
- Security and safety notes: `docs/reference/security-safety.md`.
- Release process: `docs/release/RELEASE_PROCESS.md`.
- Beta readiness gate: `docs/release/beta-readiness.md`.
- Control-plane direction: `docs/architecture/control-plane-direction.md`.
- Documentation-site source-of-truth plan: `docs/architecture/documentation-site-public-education.md`.

## Manifest

The current canonical manifest shape is:

```yaml
version: 1
project: api-local

services:
  api:
    image: ghcr.io/example/api:latest
    ports:
      - "8080:8080"
```

The current parser is a restricted Hostwright manifest subset parser, not a general YAML parser. Versionless alpha manifests are accepted as legacy version 1 input, but new examples use `version: 1`.

## Runtime Boundary

`RuntimeAdapter` defines the runtime boundary, runtime state models, command classification, timeout model, redaction policy, fake process runner, and mock adapter behavior.

Apple container observation, bounded logs, create, restart-policy-gated managed start, restart-policy-gated managed restart, exact cleanup-eligible container delete, and foreground daemon observation/planning are implemented through this boundary. General lifecycle management, image/volume cleanup, user-facing stop/restart commands, and unattended daemon mutation are not implemented.

## Source Material

Original planning, architecture, security, networking, production, naming, and brand-source materials were used to seed the repository. Bulky internal source files and generated brand-source images are no longer kept in the current public tree; maintainers should use the private archive and the checksum log in `docs/source-material/README.md` when provenance review is needed.
