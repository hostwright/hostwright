# Build Status

## Local Environment

- macOS 26.5
- Apple silicon (`arm64`)
- Swift 6.3.3 through full Xcode developer tools

## Verified On 2026-07-08

- `swift build` succeeds after the Phase 31 scheduler and placement engine changes.
- `swift test list` lists 238 real XCTest cases across Hostwright test targets.
- `swift test` executes 238 real XCTest test cases across CLI, core, daemon, health, import, manifest, networking, observability, policy, reconciler, runtime, and state targets with 0 failures.
- `scripts/grep-orchard.sh .` succeeds and reports historical references only in `docs/source-material/` and `docs/naming/`.
- `scripts/test.sh` succeeds and runs `swift build` plus `swift test`.
- `scripts/lint.sh` succeeds.
- Apple container 1.0.0 is installed locally at `/usr/local/bin/container`.
- `container system status` reports the container system service as running.
- Phase 26 read-only resource proof ran `swift run hostwright doctor --output json` and reported `localProcessInfoSnapshot`, `physicalMemoryBytes=25769803776`, `activeProcessorCount=12`, thermal state `nominal`, Apple container executable `/usr/local/bin/container`, Apple container version `unavailable` in doctor because doctor does not run Apple container commands, and no capacity guarantee.
- Phase 26 read-only Apple container checks reported `container CLI version 1.0.0` and an existing local `docker.io/library/python:alpine` image with an `arm64` variant. No Phase 26 image pull was performed.
- Phase 27 was research-only. It added an accelerator boundary decision record and docs guard test without running live accelerator probes, Apple container commands, image pulls, runtime mutation, or host-native services.
- Phase 32 added a local deterministic policy engine and policy docs without remote policy service, team workflow, silent bypass, Apple container command execution from policy, SQLite access from policy, runtime mutation, registry calls, image pulls, telemetry upload, or accelerator implementation.
- Phase 28 adds import-only stack-file conversion and docs without Docker Compose parity, runtime compatibility claims, file writes, RuntimeAdapter calls, Apple container commands, SQLite access, registry calls, image pulls, DNS/tunnel/cloud behavior, or runtime mutation.
- Phase 29 was research-only. It added an external orchestration compatibility decision record and docs guard test without adding CRI, Kubernetes node behavior, Docker API, Compose parity, Testcontainers behavior, attach, exec, log following, port forwarding, external scheduler integration, runtime mutation, state writes, network calls, image pulls, dependencies, release tags, or GitHub Releases.
- Phase 30 was research-only. It added a multi-host platform decision record and docs guard test without adding multi-host orchestration, remote mutation, remote host agents, state replication, membership service, peer discovery, transport or certificate implementation, cloud control plane, DNS/tunnel behavior, scheduler API, remote placement, runtime mutation expansion, state writes, network calls, image pulls, dependencies, release tags, or GitHub Releases.
- Phase 31 adds a local advisory scheduler model and docs guard test without adding automatic placement, resource reservation, runtime mutation, RuntimeAdapter changes, SQLite access, state writes, daemon scheduling, scheduler API, external scheduler compatibility, Kubernetes scheduler behavior, multi-host scheduling, remote placement, DNS/tunnel/cloud behavior, registry calls, image pulls, telemetry upload, third-party dependencies, accelerator-aware scheduling, release tags, or GitHub Releases.
- `container list --all --format json` returned the verified empty runtime shape `[]`.
- A disposable local image `hostwright-proof-web:phase8b` was built from the Apple tutorial-style `python:alpine` flow.
- `hostwright apply` created exactly one Apple container named `hostwright-proof-web` through `RuntimeAdapter`.
- A stale repeat apply using the old plan hash was rejected before any second mutation.
- Exact proof cleanup removed `hostwright-proof-web` and `hostwright-proof-web:phase8b` without `--all` or `--force`.
- Phase 9 live proof used existing local image `docker.io/library/python:alpine` without pulling images.
- `hostwright apply` created `hostwright-phase9proof-web`.
- A second confirmed `hostwright apply` started `hostwright-phase9proof-web` through `startManagedService`; the container exited/stopped after `python3 --version`.
- `hostwright logs web ... --tail 20` returned `Python 3.14.6`.
- `hostwright cleanup --dry-run` produced token `cleanup-8ecbbdd9ef3cdd74`.
- `hostwright cleanup --confirm-cleanup cleanup-8ecbbdd9ef3cdd74` deleted exactly `hostwright-phase9proof-web`.
- `container list --all` after cleanup showed only Apple builder runtime state.
- Phase 17 live proof used existing local image `docker.io/library/python:alpine` without pulling images.
- `hostwright apply` created and started exactly one disposable Apple container named `hostwright-phase17proof-api`.
- `hostwrightd --foreground --max-iterations 1` recorded an unhealthy direct `false` health check without runtime mutation.
- `hostwright apply` restarted `hostwright-phase17proof-api` through `restartManagedService`, implemented as internal stop-then-start through `RuntimeAdapter`.
- The exact proof container was stopped and then deleted through `hostwright cleanup --dry-run` plus token confirmation; `container list --all` after cleanup showed only Apple builder runtime state.
- Phase 22 live proof used existing local image `docker.io/library/python:alpine` without pulling images.
- `hostwright apply` created exactly one disposable Apple container named `hostwright-phase22proof-netproof`.
- `container list --all --format json` reported the proof publish as `127.0.0.1:19022:80/tcp`.
- `hostwright cleanup --dry-run` plus token confirmation deleted exactly `hostwright-phase22proof-netproof`.

## Current Implementation Truth

- Phase 5 adds read-only Apple container observation infrastructure behind `RuntimeAdapter`.
- Phase 6 adds SQLite-backed local state for explicit database paths.
- Phase 7 adds deterministic non-mutating desired-vs-observed planning, typed drift records, typed plan issues, typed planned actions, and a deterministic plan hash.
- Phase 8A adds parser and fixture support for the verified real empty Apple container JSON list output.
- Phase 8B adds a create-only apply gate that requires explicit state DB path, explicit plan hash confirmation, operation intent persistence before mutation, and RuntimeAdapter execution.
- Phase 9 adds live `status --state-db`, bounded `logs`, event rendering, one restart-policy-allowed managed start action, and ownership-based cleanup for exact stopped/created/exited containers.
- Phase 10 prepares the source-only `v0.1.0-alpha.1` pre-release docs, version output, compatibility matrix, install/build instructions, security/safety notes, release checklist, and release notes draft.
- Phase 12 adds stable CLI exit categories, `--output text|json` for `plan`, `status`, `events`, and `doctor`, JSON error envelopes, and matching CLI XCTest coverage.
- Phase 13 adds optional manifest `version: 1`, fail-closed explicit older/newer version policy, contextual unsupported-field errors, unsafe env-key and unsafe mount-source validation, versioned examples, and schema/example alignment tests.
- Phase 14 adds migration checksums, future-schema refusal, corrupt/locked state error classification, explicit read-vs-migrate boundaries, and state backup/restore/export policy docs.
- Phase 15 adds `hostwrightd --foreground --config <path> --state-db <path>` for non-mutating daemon observation/planning with event and operation persistence, cadence, jitter, backoff, shutdown, lock, and sleep/wake test seams.
- Phase 16 adds bounded host-side health check execution, append-only health result persistence, restart policy state with max attempts/backoff/operator hold/manual-disable/crash-loop blocking, redacted health/restart events, and apply/daemon planning gates that avoid aggressive restart loops.
- Phase 17 adds one restart-policy-gated managed restart path for exact Hostwright-owned running/unhealthy services, using live runtime lifecycle observation, a fresh persisted unhealthy health result from the explicit state DB, status/apply plan-hash parity, internal stop-then-start runtime execution, operation ledger records, partial restart failure records, and redacted events.
- Phase 18 adds operation recovery groups and steps, apply checkpoints, active-operation locking with expired-lock interruption, rollback-unavailable step records, redacted manual recovery hints, legacy managed-restart recovery rendering, and read-only `hostwright recovery` output for failed or interrupted apply inspection.
- Phase 19 adds cleanup dry-run classifications for eligible, ambiguous, stale, running, unknown, blocked, and never-delete ownership-backed and observed-only resources, keeps confirmed deletion limited to exact eligible Hostwright-owned non-running containers, hardens cleanup confirmation tokens against eligible-candidate drift, and reports delete-success/state-persistence failures as state failures.
- Phase 20 adds read-only event filters, local redacted diagnostics bundles from explicit state DB paths, local-only telemetry policy reporting in status/doctor/diagnostics output, and XCTest coverage for diagnostics redaction and no runtime observation during export.
- Phase 22 adds local bind-address policy helpers, observed host-port conflict blockers, unsupported DNS/discovery/networking-field errors, versioned network attachment fixture parsing, and fail-closed handling for non-empty real Apple container network output.
- Phase 26 adds ProcessInfo-backed resource intelligence reports in doctor JSON, fixture-backed parser coverage, evidence-based non-arm64 image architecture warnings, and docs that keep benchmark dimensions explicit as unmeasured without capacity or accelerator claims.
- Phase 27 adds a research-only accelerator boundary decision record and docs guard for Apple GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator helpers, and scheduler accelerator dimensions.
- Phase 32 adds `HostwrightPolicy` with deterministic local policy decisions for planner checks, cleanup classification, image policy, env/secrets, lifecycle, untrusted manifests, secure exposure, and accelerator placeholders while preserving existing runtime/state boundaries.
- Phase 28 adds `HostwrightImport` and `hostwright import-stack <path> [--output text|json]` for deterministic conversion of a narrow safe stack-file subset into reviewed `hostwright.yaml` text, with fail-closed unsupported-field diagnostics and normal manifest validation.
- Phase 29 adds a research-only external orchestration compatibility decision record that rejects current-core CRI, Kubernetes node behavior, Docker API, Testcontainers target behavior, full Compose parity, attach, exec, log-follow, and port-forward compatibility claims while deferring any external scheduler API to a separate approved issue.
- Phase 30 adds a research-only multi-host platform decision record that keeps current core single-host and defers remote host agents, membership, state replication, cloud control plane, scheduler API, and remote placement to a separate approved issue or project boundary.
- Phase 31 adds local advisory scheduler reports in `HostwrightReconciler` for declared memory requests, local policy blockers, workload class scoring, fairness warnings, overcommit blockers, accelerator blockers, and remote-placement blockers without changing `ReconciliationPlan`, CLI output, RuntimeAdapter, state, daemon behavior, or runtime mutation.
- No Apple container command was called by Phase 6 or Phase 7.
- `FoundationRuntimeProcessRunner` exists for policy-approved read-only command specs and supported mutation specs; automated tests still use fake process execution.
- `AppleContainerReadOnlyAdapter` reports missing `container` as runtime unavailable and rejects mutation through the adapter contract.
- `AppleContainerObservationParser` accepts the fixture-defined `hostwright.apple-container.observation.v1` schema with reviewed network attachment metadata, the verified real empty JSON array shape `[]`, Apple builder container list output, and the verified created/stopped proof container output. Non-empty real Apple container network output fails closed until reviewed.
- `AppleContainerImageListParser` accepts the verified real object-based image list shape with `configuration.name`.
- `SQLiteStateStore` uses system `SQLite3`, schema migrations, transactions, and repository APIs for desired services, observed snapshots, events, operations, ownership records, health results, restart policy state, restart recovery records, operation recovery groups/steps, and diagnostics export.
- Phase 6 state tests use explicit temporary database paths only.
- Phase 7 planner tests use in-memory desired and observed runtime models only.
- No default user database path, hidden global database write, unattended daemon mutation, launch agent, multi-action apply, user-facing stop/restart/remove command, image deletion, volume deletion, broad cleanup, aggressive restart loop, or CLI Apple container shell-out bypass was implemented.
- Live mutation proofs were run only for exact disposable Hostwright-owned proof containers and then cleaned up.

## SwiftPM Fixture Resources

The runtime text fixtures under `Tests/HostwrightRuntimeTests/Fixtures/` are declared as `HostwrightRuntimeTests` resources in `Package.swift`:

- `apple-container-list-empty.txt`
- `apple-container-list-empty-real-json.txt`
- `apple-container-list-builder-real-json.txt`
- `apple-container-list-proof-created-real-json.txt`
- `apple-container-list-running.txt`
- `apple-container-list-redaction.txt`
- `apple-container-image-list-real-json.txt`

SwiftPM copies them during `swift test`, and the unhandled-resource warning is gone.

## XCTest Status

XCTest is available through a real SwiftPM test target in the current full Xcode toolchain.

Important diagnostic correction:

- `swift -e 'import XCTest'` can still fail and is not the correct gate.
- A minimal SwiftPM XCTest probe passed after Xcode was fixed.
- `swift test list` is the local proof that Hostwright now exposes real XCTest cases.
- `swift test` executes 238 XCTest cases after the Phase 31 scheduler and placement engine update.

The old top-level smoke/precondition posture has been replaced with XCTest assertions. Some test file names still include `Smoke.swift`, but the contents are XCTest cases.

## CI Limitation

The local `.github/workflows/ci.yml` template was not run and the hosted runner label was not verified because this session was local-only and used no network commands.

## Core Repo Boundary

The root `hostwright_naming_convention/` archive and original root source files are treated as private source material. Bulky internal documents and generated brand-source images are no longer kept in the current public tree; `docs/source-material/README.md` keeps checksum provenance for private-archive review.

The local `site/` folder is not part of the core repository. The public website/docs site belongs in the separate `hostwright.dev` repository.
