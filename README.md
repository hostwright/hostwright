# Hostwright

Hostwright is a Mac-native desired-state container platform for Apple silicon.

## Current Status

The repository is on the `0.0.2-dev` development line. The release target is `v0.0.2`; it has not reached GA and is not production ready.

GA requires all 15 phases plus two clean release-candidate qualification runs; no partial or blocked phase is hidden behind the version number.

Phase 01 established the breaking contracts and evidence system:

- Manifest v2;
- Control API v2;
- Runtime Provider API v2;
- plugin ABI v1;
- state schema v7;
- Hostwright UUID identity, project-generation provider binding, and durable operation-saga state;
- machine-readable capability truth through `hostwright capabilities --json`;
- deterministic read-only v1/versionless manifest migration preview.

Phase 02 is active. The existing implementation remains narrower than the `v0.0.2` outcome. It includes a restricted manifest parser, deterministic planning, hardened schema-v7 SQLite ledgers and maintenance, Apple `container` observation, a few confirmation-gated lifecycle mutations, bounded logs/events/diagnostics, a foreground daemon loop, local policy/team profiles, a one-shot control process, advisory scheduling models, unsigned developer distribution evidence, and an implemented trusted ZIP/`.pkg`/SBOM/provenance/formula pipeline that still lacks real credentials and public-channel evidence. It does not yet provide an available trusted install channel, complete lifecycle, Containerization, networking, persistent storage, HA, Kubernetes/Docker compatibility, GUI, or GA qualification.

The authoritative scope and every limitation-to-implementation mapping are in the [v0.0.2 implementation plan](docs/roadmap/v0.0.2/IMPLEMENTATION_PLAN.md). The [machine-readable issue manifest](docs/roadmap/v0.0.2/issues.json) tracks one master, 15 epics, and 167 workstreams. No research-only, blocked, fixture-only, mock-only, or dirty result closes an implementation gate.

## Installation Truth

`brew install hostwright` does not exist today, and neither does the planned `hostwright/homebrew-tap` repository. Phase 02 implements the maintained vendor tap plus signed/notarized archives and a `.pkg`; the artifact/formula machinery exists but no credentialed release or tap install has passed. Phase 15 owns Homebrew-core submission. Core acceptance is external, so the vendor tap is the guaranteed fallback once its evidence gate closes.

For current development, build from source:

```bash
git clone https://github.com/hostwright/hostwright.git
cd hostwright
swift build
swift test
scripts/integration.sh
```

Requirements:

- Apple silicon;
- macOS 26 or later for the current package target;
- Swift 6.2-compatible toolchain;
- Apple `container` only for commands that explicitly observe or mutate that runtime.

See [installation](docs/reference/install.md) and [compatibility](docs/reference/compatibility.md) for exact current evidence and target scope.

## Development Commands

```bash
swift run hostwright --version
swift run hostwright capabilities --json
swift run hostwright paths --json
swift run hostwright state integrity --json
swift run hostwright state backup --json
swift run hostwright state backups --json
swift run hostwright init
swift run hostwright migrate preview hostwright.yaml
swift run hostwright validate
swift run hostwright plan
swift run hostwright status
swift run hostwright logs api
swift run hostwright events
swift run hostwright cleanup --dry-run
swift run hostwright doctor
swift run hostwrightd --foreground --config hostwright.yaml --max-iterations 1
```

State-backed commands default to `~/Library/Application Support/Hostwright/state/state.sqlite`; `--state-db` remains an explicit override. Hostwright creates private `0700` directories, requires `0600` sensitive files, and safely migrates a compatible `~/.hostwright/state.sqlite` through a resumable journal. `hostwright state` provides full integrity reports, SQLite online backup, verified catalogs, confirmation-bound atomic restore, reconstruction-only repair, and interrupted-maintenance recovery. See [state-store architecture](docs/architecture/state-store.md), [CLI reference](docs/reference/cli.md), and [local paths](docs/reference/local-paths.md).

The current mutation surface still requires plan/cleanup confirmation tokens. `hostwrightd` is not yet installed as a LaunchAgent and does not yet perform the Phase 08 unattended reconciliation contract.

## Manifest v2

New manifests require an explicit version:

```yaml
version: 2
project: api-local

services:
  api:
    image: ghcr.io/example/api:latest
    ports:
      - "8080:8080"
```

The current parser remains a restricted YAML subset. Versionless and explicit v1 files are legacy input and fail execution with migration guidance. Preview a deterministic, non-writing conversion:

```bash
hostwright migrate preview hostwright.yaml
hostwright migrate preview hostwright.yaml --json
```

The preview only upgrades the version contract today; Phase 04 owns the maintained YAML parser, complete executable workload schema, lifecycle semantics, and full semantic migration.

## Runtime and State Safety

- Runtime operations cross `RuntimeAdapter` / Runtime Provider API boundaries.
- Every new resource receives a Hostwright UUID; Apple names are attributes, not authority.
- A project generation is bound to one mutation provider.
- State schema v7 records UUIDs, provider generations, fencing, saga intent, compensation, and verification fields.
- Local state uses the secure Application Support default unless an explicit CLI or environment override wins.
- Names or similar configuration never authorize deletion.
- Hostwright does not delete unmanaged resources.
- Secrets are resolved only at execution boundaries and must not enter argv, state, logs, diagnostics, crash bundles, or provenance.
- Cluster mutation will stop on quorum loss when multi-Mac support arrives.

Architecture decisions:

- [Resource identity and provider binding](docs/design/adr-0007-resource-identity-provider-binding.md)
- [Durable operation DAG and saga](docs/design/adr-0008-durable-operation-dag-saga.md)
- [v0.0.2 platform contracts](docs/design/adr-0009-v0.0.2-platform-contracts.md)

## Verification

```bash
swift build
swift test list || swift test --list-tests
swift test
scripts/integration.sh
scripts/grep-orchard.sh .
scripts/test.sh
scripts/lint.sh
```

Evidence classes and issue closure rules are documented in [Testing and Evidence](docs/reference/testing-evidence.md). Public claims are limited to the exact tested platform and version scope.

## Roadmap

The 15 phases cover trusted install; Apple providers; complete lifecycle; images/registries/secrets; storage; networking; autonomous recovery and observability; API/security/extensions; scheduler/optimization/accelerators; multi-Mac HA; Kubernetes; Docker ecosystem; GUI/team/cloud; and exhaustive GA qualification.

Permanent boundaries are limited to private Apple APIs, unsupported Intel/old-macOS emulation, unsafe quorum writes, silent telemetry, unauthenticated public exposure, and unmanaged destructive garbage collection. Each technically constrained user outcome has a safe fallback in the roadmap.

## Historical Material

Earlier release notes, research records, and the former phase plan remain available for traceability. They are historical snapshots and do not override current-main documentation, `hostwright capabilities --json`, or the `v0.0.2` roadmap.

- Historical [Control-plane direction](docs/architecture/control-plane-direction.md)
- Historical [Documentation-site source-of-truth plan](docs/architecture/documentation-site-public-education.md)
