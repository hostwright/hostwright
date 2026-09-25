# Hostwright

Hostwright manages Apple container workloads on one Apple silicon Mac. Declare services in a YAML manifest, review a plan, and confirm it through the CLI or native desktop app. Hostwright tracks resource ownership and operations in a local SQLite database.

**Status:** development builds on the `0.0.2-dev` line. The `v0.0.2` release is still undergoing qualification.

## Requirements

- Apple silicon and macOS 26 or later.
- Apple `container` 1.0.0 or 1.1.0 for the CLI runtime provider. The native provider uses pinned Containerization 0.35.0 and requires local images.
- A Swift 6.2-compatible toolchain for source builds.

See [compatibility](docs/reference/compatibility.md) for provider differences and the release qualification matrix. Validation and manifest planning work without a running container runtime.

## Installation

The vendor tap installs an unsupported qualification prerelease:

```bash
brew install hostwright/tap/hostwright
hostwright --version
```

The unqualified `brew install hostwright` command is not available. For package installation, upgrades, and removal, see [installation](docs/reference/install.md).

To build from source:

```bash
git clone https://github.com/hostwright/hostwright.git
cd hostwright
swift build --jobs 1
swift run hostwright --version
```

Source builds are useful for development. Runtime mutations require the signed CLI, daemon, and companion identities described in [daemon setup](docs/architecture/daemon.md).

## Quick start

This quickstart requires a signed candidate built from current source, using Manifest v3. The public tap currently installs dev.12, which uses older contracts and cannot run these commands. Candidate installation is part of the [release process](docs/release/RELEASE_PROCESS.md).

Start Apple `container` and save this file as `hostwright.yaml`:

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

Bootstrap the local identities once. In a separate terminal under the same macOS account, change to the directory containing `hostwright.yaml` before starting the daemon:

```bash
hostwright daemon bootstrap-identities --json
hostwrightd --foreground --config "$PWD/hostwright.yaml"
```

Validate the manifest, pull its image, and review the plan:

```bash
hostwright validate hostwright.yaml
hostwright image pull \
  docker.io/library/python@sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92 \
  --platform linux/arm64 --runtime-provider apple-cli
hostwright up hostwright.yaml --dry-run --runtime-provider apple-cli
```

Copy the plan hash into the confirmation command:

```bash
hostwright up hostwright.yaml --confirm-plan <plan-hash> --runtime-provider apple-cli
hostwright status hostwright.yaml --runtime-provider apple-cli
curl http://127.0.0.1:18080
```

To stop and remove the workload, review and confirm each operation:

```bash
hostwright down hostwright.yaml --dry-run --runtime-provider apple-cli
hostwright down hostwright.yaml --confirm-plan <down-plan-hash> --runtime-provider apple-cli
hostwright rm hostwright.yaml --dry-run --runtime-provider apple-cli
hostwright rm hostwright.yaml --confirm-plan <rm-plan-hash> --runtime-provider apple-cli
```

The [Compose import guide](docs/guides/stack-import.md) covers conversion of existing stack files. The [manifest reference](docs/reference/manifest.md) documents supported fields.

## Commands and surfaces

| Task | Commands |
| --- | --- |
| Validate and plan | `validate`, `plan`, `migrate preview`, `import-stack` |
| Run workloads | `up`, `down`, `start`, `stop`, `restart`, `rm`, `update` |
| Inspect workloads | `status`, `logs`, `events`, `inspect`, `stats`, `exec`, `attach` |
| Manage local resources | `image`, `registry`, `secret`, `volume`, `runtime` |
| Operate and recover | `daemon`, `state`, `recovery`, `doctor`, `diagnostics`, `cleanup` |

`Hostwright.app` provides manifest selection, service status, logs, and confirmed up/down/restart actions. `hostwright-dist` manages installed packages. Use `hostwright help` and the [CLI reference](docs/reference/cli.md) for arguments and provider restrictions.

## Architecture

The CLI and desktop connect to authenticated Control API 2.2 over a private Unix socket. The planner and scheduler validate intent; a durable lifecycle coordinator records operations, checks ownership and authority, calls the selected runtime provider, and verifies the result.

- [Runtime providers](docs/architecture/runtime-adapter.md) isolate Apple CLI and Containerization access.
- [State storage](docs/architecture/state-store.md) owns SQLite schema v24, migrations, leases, and recovery.
- [Daemon](docs/architecture/daemon.md) describes foreground operation and the current-user LaunchAgent.
- [Process execution](docs/reference/process-execution.md) covers command validation, cancellation, output limits, and cleanup.

## Compatibility and limitations

The release targets one Mac, local CPU/memory admission, a narrow Compose import workflow, and the native desktop app. Multi-Mac orchestration, Kubernetes, Docker-client compatibility, accelerators, and automatic desktop updates are deferred. Provider support varies; run `hostwright capabilities --json` and `hostwright runtime providers --json` before relying on a feature.

See [limitations](docs/reference/limitations.md), [compatibility](docs/reference/compatibility.md), and the [release plan](docs/roadmap/v0.0.2/IMPLEMENTATION_PLAN.md). Development evidence does not establish production readiness or a support SLA.

## Development and verification

```bash
scripts/test.sh pr
scripts/check-docs.sh
```

The [contributing guide](CONTRIBUTING.md) explains the full suite and attended qualification lanes. Keep live workloads and evidence outside the source checkout.

## Security and support

Mutations require a reviewed plan and current ownership. Diagnostics stay local; support bundles require preview and confirmation. Review their contents before sharing.

- [State recovery](docs/reference/local-recovery.md)
- [Support bundles](docs/reference/support-bundles.md)
- [Security reporting](SECURITY.md)
- [Bug reports](https://github.com/hostwright/hostwright/issues)
