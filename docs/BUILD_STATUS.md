# Build Status

## Local Environment

- macOS 26.5
- Apple silicon (`arm64`)
- Swift 6.3.3 through full Xcode developer tools

## Verified On 2026-07-12

- `swift build` succeeds after the runtime identity and ownership repair.
- `swift test list` lists 300 XCTest cases across Hostwright test targets.
- `swift test` executes 300 XCTest cases across CLI, core, daemon, health, import, manifest, networking, observability, policy, reconciler, runtime, secrets, and state targets with 0 failures.
- XCTest count is unit/contract and local-integration coverage, not a live-runtime, hardware-benchmark, or distribution-artifact success rate. Evidence classes are defined in `docs/reference/testing-evidence.md`.
- `scripts/grep-orchard.sh .` succeeds and reports historical references only in `docs/source-material/` and `docs/naming/`.
- `scripts/test.sh` succeeds and runs `swift build`, `swift test`, and the built-CLI local integration gate.
- `scripts/integration.sh` exercises the built executable, real team-profile files, profile-aware plan/import JSON, redacted profile errors, missing approval refusal, real file failures, overwrite refusal, and no hidden SQLite writes.
- Real local loopback HTTP and file-lock contention XCTest cases pass without conditional skips.
- Real macOS Keychain XCTest cases add uniquely named non-synchronizable items, read through the production backend without UI, delete exact service/account pairs, verify post-delete absence, and have no conditional skip.
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
- Phase 38 adds governance, contributor, security-reporting, review-trigger, issue-template, pull-request-template, release-governance, and docs guard coverage without adding CODEOWNERS enforcement, branch protection, new maintainers, product code, runtime mutation, dependencies, website implementation, GUI code, support SLA, cloud service, release tags, GitHub Releases, binary artifacts, signing, notarization, SBOM, or provenance claims.
- Phase 21 adds local control-surface requirements, API boundary, accessibility requirements, handoff criteria, and docs guard coverage without adding GUI code, website implementation, web dashboard, cloud dashboard, daemon API, direct Apple container execution, direct SQLite access, RuntimeAdapter bypass, runtime mutation expansion, telemetry upload, hosted diagnostics, release tags, or GitHub Releases.
- Phase 33 adds typed extension declarations and local extension policy decisions without adding a plugin loader, remote plugin registry, binary plugin distribution, untrusted code execution, runtime mutation extension path, state-write extension path, networking provider behavior, tunnel/DNS/reverse proxy/cloud behavior, secret backend extension, accelerator extension, GUI code, dependencies, release tags, or GitHub Releases.
- Phase 34 is complete locally: explicit strict-only profile and approval files are hash-bound across validate, plan, import, apply, cleanup, runtime confirmation, operation records, and redacted append-only audit events.
- Phase 35 is blocked: distribution policy exists, but no release artifact, installer lifecycle, signing, notarization, SBOM, or provenance evidence exists.
- Phase 36 is partial: dry-run and fixture-backed benchmark contracts exist, but no live benchmark runner or measured hardware evidence exists.
- Phase 37 adds documentation-site source-of-truth and public education boundaries without adding website frontend code, hosted docs deployment, analytics, search, product behavior, runtime mutation, dependencies, release tags, GitHub Releases, or GUI code.
- Phase 39 adds a beta readiness checklist and public-claim gate without adding beta tags, GitHub Releases, version bumps, binary artifacts, installers, support promises, production-readiness claims, product behavior, runtime mutation, dependencies, telemetry upload, website/frontend work, or GUI code.
- Phase 40 adds an Apple silicon control-plane direction decision that keeps current core single-host and rejects Kubernetes-class, CRI, Docker API, full Compose, cloud, multi-host, remote-placement, and accelerator-aware scheduling work from current core without adding product behavior, dependencies, release tags, or GitHub Releases.
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
- The runtime identity live proof used the same existing local image without pulling and created two concurrent projects whose legacy identifiers were identical. Their v2 identifiers were distinct, exact ownership labels matched, Apple container 1.0.0 network metadata parsed through `RuntimeAdapter`, both bounded processes exited naturally, token-confirmed cleanup deleted both exact resources, and the pre-existing Apple builder remained.
- Localhost HTTP data-plane proof is blocked, not passed: the host listener accepted and reset connections while macOS Local Network access for `container-runtime-linux` was disabled. This matches [apple/container issue #1702](https://github.com/apple/container/issues/1702). No runtime, firewall, privacy, or system-service setting was changed.

## Current Implementation Truth

- The completion audit classifies Phase 34 as complete locally, Phase 36 as partial, Phase 35 as blocked, and research/requirements phases separately from product implementation. Phases 12 and 19 are complete locally after their file-error/recovery and exact-identity/live-cleanup repairs.

- Phase 5 adds read-only Apple container observation infrastructure behind `RuntimeAdapter`.
- Phase 6 adds SQLite-backed local state for explicit database paths.
- Phase 7 adds deterministic non-mutating desired-vs-observed planning, typed drift records, typed plan issues, typed planned actions, and a deterministic plan hash.
- Phase 8A adds parser and fixture support for the verified real empty Apple container JSON list output.
- Phase 8B adds a create-only apply gate that requires explicit state DB path, explicit plan hash confirmation, operation intent persistence before mutation, and RuntimeAdapter execution.
- Phase 9 adds live `status --state-db`, bounded `logs`, event rendering, one restart-policy-allowed managed start action, and ownership-based cleanup for exact stopped/created/exited containers.
- Phase 10 prepares the source-only `v0.1.0-alpha.1` pre-release docs, version output, compatibility matrix, install/build instructions, security/safety notes, release checklist, and release notes draft.
- Phase 12 adds stable CLI exit categories, consistent manifest/local-file I/O diagnostics, `--output text|json` for `plan`, `status`, `events`, and `doctor`, JSON error envelopes, built-CLI subprocess checks, and matching CLI XCTest coverage.
- Phase 13 adds optional manifest `version: 1`, fail-closed explicit older/newer version policy, contextual unsupported-field errors, unsafe env-key and unsafe mount-source validation, versioned examples, and schema/example alignment tests.
- Phase 14 adds migration checksums, contiguous-history validation, future-schema refusal, corrupt/locked state error classification, explicit read-vs-migrate boundaries, and real multi-connection, concurrent acquisition, reopen, rollback, and cold backup/restore evidence.
- Phase 15 adds `hostwrightd --foreground --config <path> --state-db <path>` for non-mutating daemon observation/planning with event and operation persistence, cadence, jitter, backoff, shutdown, lock, and sleep/wake test seams.
- Phase 16 adds bounded host-side health check execution, append-only health result persistence, restart policy state with max attempts/backoff/operator hold/manual-disable/crash-loop blocking, redacted health/restart events, and apply/daemon planning gates that avoid aggressive restart loops.
- Phase 17 adds one restart-policy-gated managed restart path for exact Hostwright-owned running/unhealthy services, using live runtime lifecycle observation, a fresh persisted unhealthy health result from the explicit state DB, status/apply plan-hash parity, internal stop-then-start runtime execution, operation ledger records, partial restart failure records, and redacted events.
- Phase 18 adds operation recovery groups and steps, apply checkpoints, active-operation locking with expired-lock interruption, safe same-plan retry after proven pre-runtime persistence interruption, rollback-unavailable step records, redacted manual recovery hints and lease owner/expiry diagnostics, legacy managed-restart recovery rendering, and read-only `hostwright recovery` output for failed or interrupted apply inspection.
- Phase 19 adds cleanup dry-run classifications for eligible, ambiguous, stale, running, unknown, blocked, and never-delete ownership-backed and observed-only resources, collision-resistant v2 identifiers and labels, exact observed identifiers, legacy upgrade hints, multi-project filtering, exact managed lifecycle ownership gates, exact eligible-only cleanup, hardened confirmation tokens, and delete-success/state-persistence failure reporting.
- Phase 20 adds read-only event filters, local redacted diagnostics bundles from explicit state DB paths, local-only telemetry policy reporting in status/doctor/diagnostics output, and XCTest coverage for diagnostics redaction and no runtime observation during export.
- Phase 21 documents local control-surface data contracts and safety boundaries for a future separate design/frontend owner; it does not add a control surface or new API runtime.
- Phase 22 adds local bind-address policy helpers, observed host-port conflict blockers, unsupported DNS/discovery/networking-field errors, versioned network fixtures, and reviewed Apple container 1.0.0 network metadata parsing. Localhost HTTP remains an explicitly blocked evidence lane on this host.
- Phase 24 adds an opt-in read-only noninteractive macOS Keychain backend with real add/read/exact-delete/post-delete evidence while keeping the default CLI backend unavailable and all production Keychain writes/deletes unsupported.
- Phase 26 adds ProcessInfo-backed resource intelligence reports in doctor JSON, fixture-backed parser coverage, evidence-based non-arm64 image architecture warnings, and docs that keep benchmark dimensions explicit as unmeasured without capacity or accelerator claims.
- Phase 27 adds a research-only accelerator boundary decision record and docs guard for Apple GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator helpers, and scheduler accelerator dimensions.
- Phase 32 adds `HostwrightPolicy` with deterministic local policy decisions for planner checks, cleanup classification, image policy, env/secrets, lifecycle, untrusted manifests, secure exposure, and accelerator placeholders while preserving existing runtime/state boundaries.
- Phase 33 adds `ExtensionPolicyEvaluator` for deterministic local extension declaration decisions while preserving no runtime execution, no state writes, no plugin loading, and no external integration behavior.
- Phase 34 adds strict versioned local profile/approval parsing, canonical SHA-256 bindings, explicit command wiring, exact mutation approvals, and redacted append-only team audit events without remote behavior or a hidden profile path.
- Phase 35 adds release distribution readiness docs and release-doc guard tests for signed binary, notarized installer, checksum, SBOM, provenance, install, upgrade, downgrade, uninstall, rollback, and package-channel evidence before any public artifact claim.
- Phase 36 adds `BenchmarkLabReport` models, parser validation, and fixture tests for environment facts, disposable-resource policy, benchmark observations, and no-mutation/no-telemetry limits.
- Phase 37 adds documentation-site information architecture and source-of-truth rules for the separate `hostwright.dev` repository while keeping website presentation out of this core repo.
- Phase 39 adds beta readiness docs and docs guard coverage for clean-checkout source install proof, full local gate, hosted CI, docs alignment, examples, state upgrade evidence, telemetry/support policy review, maintainer approval, blockers, and deferrals before any beta tag.
- Phase 40 adds a control-plane direction record and docs guard coverage for the single-host core direction, rejected current-core platform expansion paths, and evidence gates before any separate experimental platform work.
- Phase 28 adds `HostwrightImport` and `hostwright import-stack <path> [--output text|json]` for deterministic conversion of a narrow safe stack-file subset into reviewed `hostwright.yaml` text, with fail-closed unsupported-field diagnostics and normal manifest validation.
- Phase 29 adds a research-only external orchestration compatibility decision record that rejects current-core CRI, Kubernetes node behavior, Docker API, Testcontainers target behavior, full Compose parity, attach, exec, log-follow, and port-forward compatibility claims while deferring any external scheduler API to a separate approved issue.
- Phase 30 adds a research-only multi-host platform decision record that keeps current core single-host and defers remote host agents, membership, state replication, cloud control plane, scheduler API, and remote placement to a separate approved issue or project boundary.
- Phase 31 adds local advisory scheduler reports in `HostwrightReconciler` for declared memory requests, local policy blockers, workload class scoring, fairness warnings, overcommit blockers, accelerator blockers, and remote-placement blockers without changing `ReconciliationPlan`, CLI output, RuntimeAdapter, state, daemon behavior, or runtime mutation.
- Phase 38 adds explicit maintainer authority, risky-area review triggers, issue and pull request flow, private security-reporting guidance, release governance gates, and support boundaries as documentation and template controls only.
- No Apple container command was called by Phase 6 or Phase 7.
- `FoundationRuntimeProcessRunner` has real subprocess coverage for output draining and timeout behavior; scripted process results remain test-only failure-injection evidence.
- `AppleContainerReadOnlyAdapter` reports missing `container` as runtime unavailable and rejects mutation through the adapter contract.
- `AppleContainerObservationParser` accepts the fixture-defined `hostwright.apple-container.observation.v1` schema, verified real empty and builder shapes, state-backed legacy rows, and exact labeled Apple container 1.0.0 rows with reviewed network metadata. It ignores unrelated labeled projects and fails closed on malformed current-project ownership or unsupported fields.
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
- `swift test` executes 300 XCTest cases after the evidence contract, real loopback HTTP/file-lock/Keychain tests, real SQLite integration, runtime identity/ownership coverage, CLI recovery diagnostics, and operational team workflow binding tests were added.

The old top-level smoke/precondition posture has been replaced with XCTest assertions. Some test file names still include `Smoke.swift`, but the contents are XCTest cases.

## CI Limitation

Hosted CI runs build, XCTest including the live exact-cleanup Keychain cases, the built-CLI local integration gate, package-metadata lint, and naming scans. It does not run live Apple container, hardware benchmark, signing, notarization, install, or multi-host evidence.

## Core Repo Boundary

The root `hostwright_naming_convention/` archive and original root source files are treated as private source material. Bulky internal documents and generated brand-source images are no longer kept in the current public tree; `docs/source-material/README.md` keeps checksum provenance for private-archive review.

The local `site/` folder is not part of the core repository. The public website/docs site belongs in the separate `hostwright.dev` repository.
