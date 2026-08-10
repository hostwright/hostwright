# Hostwright

Hostwright is a macOS command-line control plane for declaring and managing Apple container workloads on one Apple silicon Mac. It reads strict Manifest v3 YAML, produces plans for review, executes confirmed lifecycle actions through runtime providers, and records local state in SQLite schema v24.

Status: `0.0.2-dev`, targeting `v0.0.2`. Hostwright is not production-ready.

The Phase 10 Manifest v3, Control API 2.2, scheduler admission, and state v23 slices are active implementation boundaries, not aggregate qualification claims. `scheduler.optimization` and `accelerators.host-native` remain unavailable pending converged G13-G15 aggregate, live, hardware, and security evidence; direct guest passthrough remains blocked.

## Requirements

- An Apple silicon Mac. Intel Macs are unsupported.
- macOS 26 or later. `Package.swift` declares macOS 26 as the package target.
- Xcode command-line tools with a Swift 6.2-compatible toolchain for source builds. The package uses Swift tools 6.2.
- Apple `container` for live image, runtime, status, and lifecycle commands. Hostwright has conformance coverage for Apple `container` 1.0.0 and 1.1.0. Validation and manifest planning do not require the runtime.

See [Compatibility](docs/reference/compatibility.md) for the tested matrix and failure behavior.

## Installation

### Vendor tap

The Hostwright-maintained tap installs an unsupported qualification build:

```bash
brew install hostwright/tap/hostwright
hostwright --version
hostwright capabilities --json
```

`brew install hostwright` does not exist today.

### Build from source

```bash
git clone https://github.com/hostwright/hostwright.git
cd hostwright
swift build
swift test
swift run hostwright --version
swift run hostwright capabilities --json
```

SwiftPM fetches the pinned Containerization 0.35.0 and Yams 6.2.2 dependencies during the build. Read [Install and Upgrade](docs/reference/install.md) for tap, source, package, upgrade, and uninstall details.

## Quick start

Start a supported Apple `container` runtime, then save this Manifest v3 file as `hostwright.yaml`:

```yaml
version: 3
project: quickstart
imagePolicy: require-digest

services:
  web:
    image: docker.io/library/python@sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92
    resources:
      requests:
        cpus: 1
        memory: 512MiB
      limits:
        cpus: 1
        memory: 512MiB
    command: ["python3", "-m", "http.server", "8080", "--bind", "0.0.0.0"]
    ports:
      - "18080:8080"
    restart:
      policy: unless-stopped
```

Validate the file, pull its Linux ARM64 image, and inspect the lifecycle plan:

```bash
hostwright runtime providers --json
hostwright validate hostwright.yaml
hostwright image pull \
  docker.io/library/python@sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92 \
  --platform linux/arm64 \
  --runtime-provider apple-cli
hostwright up hostwright.yaml --dry-run --runtime-provider apple-cli
```

At the current Phase 10 boundary, Manifest v3 validation and planning remain experimental. The current-source scheduler qualification is sealed, but confirmed allocation/lifecycle mutation remains unavailable until the persistent Control 2.2 lifecycle handoff, repository-backed runtime/victim-fencing seam, and remaining G13-G15 integration evidence are qualified. A confirmed mutation fails closed with `scheduler-authority-unavailable` and does not touch the runtime.

Copy the plan hash from the dry run into the confirmed command:

```bash
hostwright up hostwright.yaml \
  --confirm-plan <plan-hash> \
  --runtime-provider apple-cli
hostwright status hostwright.yaml --runtime-provider apple-cli
curl http://127.0.0.1:18080
```

`down` and `rm` each require a new dry run and plan hash:

```bash
hostwright down hostwright.yaml --dry-run --runtime-provider apple-cli
hostwright down hostwright.yaml --confirm-plan <down-plan-hash> --runtime-provider apple-cli
hostwright rm hostwright.yaml --dry-run --runtime-provider apple-cli
hostwright rm hostwright.yaml --confirm-plan <rm-plan-hash> --runtime-provider apple-cli
```

In a source checkout, replace `hostwright` with `swift run hostwright`. The [Manifest reference](docs/reference/manifest.md) documents the supported YAML subset.

## Commands and surfaces

| Surface | Purpose |
| --- | --- |
| `hostwright validate`, `plan`, `migrate preview`, `import-stack` | Validate Manifest v3, produce deterministic plans, preview legacy migration, and convert a narrow stack-file subset. |
| `hostwright up`, `down`, `run`, `start`, `stop`, `restart`, `rm`, `update` | Execute plan-hash-gated lifecycle operations. `apply` routes to a confirmed `up` plan for compatibility. |
| `hostwright exec`, `attach`, `copy`, `export`, `inspect`, `stats`, `logs` | Use provider-gated interactive, transfer, inspection, and streaming operations. |
| `hostwright image`, `registry`, `secret`, `volume` | Manage provider images, registry authentication and OCI evidence, typed local secret references, and exact Hostwright-owned named-volume, snapshot, backup, quota, reclaim, and orphan workflows. |
| `hostwright status`, `events`, `metrics`, `traces`, `recovery`, `state`, `cleanup`, `doctor`, `diagnostics` | Observe workloads, inspect bounded correlated local evidence, create consent-bound privacy-safe support bundles, maintain local state, recover fenced operations, and remove verified Hostwright-owned resources. |
| `hostwright-control` | Accept one bounded local JSON request, return one JSON response, and exit. It opens no socket or HTTP listener. |
| `hostwright daemon`, `hostwrightd` | Control the exact current-user `dev.hostwright.daemon` LaunchAgent or run the foreground loop. Both daemon modes level-trigger supported drift through the shared fenced lifecycle saga. |
| `hostwright-dist` | Build, verify, install, upgrade, repair, roll back, and uninstall Hostwright distributions through explicit paths. |

Run `hostwright help` or read the [CLI reference](docs/reference/cli.md) for arguments, JSON contracts, and exit codes.

## Architecture

SwiftPM separates contracts, runtime access, orchestration, state, and process surfaces:

| Boundary | Modules and executables |
| --- | --- |
| Contracts and input | `HostwrightCore`, `HostwrightManifest`, `HostwrightImport`, and `HostwrightPolicy` define identities, contract versions, Manifest v3 decoding, conversion, and local policy. |
| Runtime providers | `HostwrightRuntime` owns `RuntimeAdapter`, capability negotiation, observation, and mutation contracts. `hostwright-containerization-helper` keeps the pinned Containerization framework in an authenticated out-of-process helper. |
| Planning and state | `HostwrightReconciler` builds lifecycle plans and recovery actions. `HostwrightState` persists desired state, observations, ownership, operation records, and schema-v17 through v23 migrations in SQLite. |
| Registry and secrets | `HostwrightRegistry` handles registry authentication and digest-bound OCI evidence. `HostwrightSecrets` handles Keychain and typed secret-provider boundaries. |
| Storage | `HostwrightStorage` defines Storage Provider API v1, the built-in local provider, guarded mounts, snapshots, verified local/S3-compatible backup and restore, capacity policy, reclaim, and orphan recovery. `hostwright-storage-helper` keeps provider execution out of process. |
| User and automation surfaces | `HostwrightCLI`, `HostwrightControl`, `HostwrightDaemonCore`, and their executable targets expose the CLI, one-shot JSON process, foreground daemon loop, and exact per-user LaunchAgent lifecycle. |
| Supporting boundaries | `HostwrightHealth`, `HostwrightNetworking`, `HostwrightObservability`, `HostwrightExtensions`, and `HostwrightDistribution` keep health, network policy, diagnostics, reviewed extensions, and distribution logic outside the core command router. |

Apple runtime behavior crosses `RuntimeAdapter`; the CLI, reconciler, and state store do not invoke Apple `container` as independent runtime paths. State-backed commands use `~/Library/Application Support/Hostwright/state/state.sqlite` unless `--state-db` or `HOSTWRIGHT_STATE_DB` selects another safe path.

Architecture references:

- [Runtime adapter](docs/architecture/runtime-adapter.md)
- [Daemon and LaunchAgent lifecycle](docs/architecture/daemon.md)
- [State store](docs/architecture/state-store.md)
- [Storage](docs/reference/storage.md)
- [Secure workload profiles](docs/reference/workload-profiles.md)
- [Resource identity and provider binding](docs/design/adr-0007-resource-identity-provider-binding.md)
- [Durable operation DAG and saga](docs/design/adr-0008-durable-operation-dag-saga.md)
- [v0.0.2 platform contracts](docs/design/adr-0009-v0.0.2-platform-contracts.md)

## Compatibility and limitations

- Hostwright supports Apple silicon and targets macOS 26 or later.
- The Apple CLI provider supports tested Apple `container` 1.0.0 and 1.1.0 contracts. Unknown or mixed versions fail before mutation.
- The package pins Containerization 0.35.0. Its helper exposes a smaller local-image subset and reports image mutations as unavailable.
- Hostwright runs on one Mac. It has no multi-host control plane or high-availability state authority.
- The manifest parser accepts the documented Hostwright YAML subset. It rejects unsupported YAML, unknown Kubernetes or Compose fields, and unsafe paths.
- Hostwright has no Kubernetes or CRI compatibility, Docker API, full Compose compatibility, GUI, or cloud service.
- Hostwright supports exact Hostwright-owned named volumes, guarded mounts, snapshots, verified online backup/restore, quota and pressure accounting, reclaim policy, orphan quarantine/GC, UUID-owned project networks, project DNS/service aliases, explicit localhost or LAN ingress with TLS/mTLS policy, guarded host access, and authenticated service tunnels. Unsupported providers or unqualified exposure modes fail before mutation.
- `hostwright-control` has no persistent listener. `hostwright daemon` installs only the exact per-user LaunchAgent after explicit invocation; `hostwrightd` has no network API and reconciles only through the existing local lifecycle/provider boundaries.
- Cleanup and image pruning require exact ownership and confirmation. Hostwright does not delete unmanaged resources or run global garbage collection.
- Hostwright is not production-ready and has no support SLA.

Read [Limitations](docs/reference/limitations.md) and [Compatibility](docs/reference/compatibility.md) before relying on a runtime or provider combination.

## Development and verification

```bash
swift build
swift test list || swift test --list-tests
swift test
scripts/integration.sh
scripts/check-docs.sh
scripts/grep-orchard.sh .
scripts/test.sh
scripts/lint.sh
```

Live runtime verification requires Apple silicon, macOS 26 or later, and a supported Apple `container` version. Source-only checks can run without the runtime.

See [Contributing](CONTRIBUTING.md) and [Governance](GOVERNANCE.md) before changing runtime, state, distribution, or public contracts.

## Security and support

Hostwright gates lifecycle mutation with exact plan hashes and gates cleanup with a separate token. It resolves secrets at execution boundaries, scopes created port publishes to loopback, keeps diagnostics local, and refuses unmanaged deletion. Privacy-safe support bundles require a preview and exact confirmation, can use macOS CMS encryption, never upload automatically, and delete only with a retained exact ownership receipt. Review every bundle before sharing it.

- Read [Security and Safety Notes](docs/reference/security-safety.md) for runtime, state, secret, registry, cleanup, and diagnostics boundaries.
- Read [Privacy-Safe Support Bundles](docs/reference/support-bundles.md) for preview, encryption, recovery, retention, and exact deletion.
- Follow the [Security Policy](SECURITY.md) to report a vulnerability.
- Use the [local team workflow](docs/reference/team-workflow.md) for profile-bound approvals.
- Use [GitHub Issues](https://github.com/hostwright/hostwright/issues) for reproducible bugs and usage questions.
