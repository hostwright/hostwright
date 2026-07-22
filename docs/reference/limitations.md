# Limitations

Current product truth is the `0.0.2-dev` capability report plus the [v0.0.2 all-in limitation register and implementation plan](../roadmap/v0.0.2/IMPLEMENTATION_PLAN.md). Run `hostwright capabilities --json` for the exact build. Every useful missing or partial capability below now has a phase/workstream owner; it is not dismissed as a non-goal.

Phase 02 qualification is complete. The immutable unsupported `v0.0.2-dev.11` and `v0.0.2-dev.12` releases passed signed/notarized ZIP and `.pkg`, SBOM, provenance, attestation, vendor-tap, clean macOS 26 lifecycle, state, doctor, abrupt-power, and exact-cleanup gates. `brew install hostwright/tap/hostwright` is available; unqualified `brew install hostwright` is not.

Phase 03 qualification is complete for Apple `container` 1.0.0 and 1.1.0 plus the exact Containerization 0.35.0 helper. The two providers now share capability negotiation, deterministic observation, normalized outcomes, the declared local-image lifecycle subset, provider fencing/migration, and restart/upgrade recovery. Containerization is not linked into the main process and does not add image pull/build/load, general stop/remove/run, exec/attach, streaming, storage, networking, or the complete Phase 04 lifecycle. This evidence does not make Hostwright GA or production ready.

Permanent exclusions are limited to private Apple APIs, unsupported Intel/old-macOS emulation, unsafe writes without cluster quorum, silent telemetry, unauthenticated public exposure, and destructive garbage collection of unmanaged resources. Homebrew-core and direct guest accelerator constraints have implemented fallback tracks.

Phase 02 issue #116 is implemented: production callers share bounded direct-argv process execution with root-owned PATH resolution, minimal environment, descriptor-pinned working directories, cancellation, I/O/time limits, and inherited session process-group cleanup. This is process lifecycle control, not native hostile-code isolation. A reviewed-local executable retains ambient same-user authority and can deliberately establish a new session; WASI/XPC isolation remains Phase 09 work under issues #203 and #204.

Phase 02 issue #113 is implemented: state-backed commands use a secure macOS Application Support default, deterministic override precedence, private path ownership/modes, truthful `paths`/`doctor` reporting, and resumable legacy-state migration. Explicit-only/default-path statements retained below are pre-v0.0.2 history, not current behavior. Installed distribution lifecycle is covered by issue #118 below; autonomous installed-service management remains a later phase.

Phase 02 issue #114 is implemented: `hostwright state` now provides full integrity classification, SQLite online backup, a verified private catalog, confirmation-bound atomic restore, reconstruction-only projection repair, cross-process access fencing, and checkpoint recovery. It supports live WAL sources for backup and requires exclusive normalization before filesystem replacement. It does not claim arbitrary page salvage, repair of authoritative rows, or protection from deliberate same-user direct database writes.

Phase 02 issue #115 is implemented for Hostwright-mediated single-Mac SQLite access: private database/sidecar validation, pre/post-open identity checks, Hostwright application ownership, WAL/FULL and portable DELETE/EXTRA profiles, serialized Hostwright writers, bounded readers/locks, strict managed transactions, cancellation and storage-pressure rollback, foreign-database refusal, and process-termination recovery are executable. This does not provide a same-user sandbox, arbitrary page salvage, distributed state, or release-wide lifecycle/soak qualification; those boundaries remain explicit rather than being reported as SQLite support.

Phase 02 issue #118 implements the explicit-prefix installed distribution lifecycle: verified trusted/developer artifact install, strict SemVer upgrade, exact-generation repair, structured status, explicit schema-1 adoption, durable checkpoint recovery, verified one-generation rollback, downgrade refusal, ownership-scoped preserve/remove uninstall, deterministic mid-mutation cancellation, narrow stop/restore handling for an exact existing Homebrew launchd record, and exact `dev.hostwright.cli` Apple Installer receipt cleanup. It does not choose or create an implicit system prefix, create/register/autostart a LaunchAgent, stop a running unmanaged `hostwrightd`, edit `PATH`, delete backup catalogs/config/cache/logs, or remove Apple container resources. Remove-data uninstall affects only the bound verified SQLite database and existing SQLite sidecars after a current confirmation plan. See [Installed Distribution Lifecycle](installed-lifecycle.md).

The remainder of this file preserves the detailed pre-v0.0.2 capability inventory because tests, threat boundaries, and earlier evidence refer to its exact wording. It is historical implementation evidence, not the active release scope or schedule. Where it says “not implemented,” consult the v0.0.2 plan for the owning phase.

## Retained Pre-v0.0.2 Capability Inventory

Hostwright `v0.1.0-alpha.1` can model and attempt read-only runtime observation through `RuntimeAdapter`, persist desired and observed state to an explicit SQLite database path, compute deterministic desired-vs-observed plans, produce local advisory scheduling recommendations from declared inputs, expose a one-shot local JSON process for five existing command contracts, execute one tightly gated create-missing-service mutation, execute one restart-policy-allowed managed start, execute one restart-policy-allowed managed restart for an exact Hostwright-owned running/unhealthy service, read bounded logs, render and filter state events, write a local redacted diagnostics bundle, run a foreground daemon loop with in-process loopback health probes and restart-state blocking, and delete exact cleanup-eligible Hostwright-owned stopped/created/exited containers through `RuntimeAdapter`.

Hostwright is not production ready.

## Implemented Today

- Dependency-free CLI command routing.
- `hostwright --version`.
- `hostwright init` without overwrite.
- `hostwright validate` for a restricted Hostwright manifest subset.
- Manifest `version: 1` support with versionless alpha manifests treated as legacy version 1 input.
- Manifest `imagePolicy: require-digest` support for local `@sha256:<64 lowercase hex characters>` image reference validation before planning or mutation.
- Manifest `secretEnv` support for local `keychain://<service>/<account>` secret references, with a test-only in-memory store, an opt-in noninteractive read-only macOS Keychain backend, live exact-cleanup tests, and no live Keychain default.
- Fail-closed unsupported-field, unsupported-version, unsupported DNS/discovery/networking-field, unsafe env-key, and unsafe host-root or parent-traversal mount-source validation for untrusted manifests.
- `hostwright import-stack <path>` conversion for a narrow safe stack-file subset, printing converted `hostwright.yaml` text without writing files, observing runtime, touching state, or claiming Compose compatibility.
- `hostwright plan` as non-mutating manifest-level dry-run output.
- `--output json` for `import-stack`, `plan`, `status`, `events`, `recovery`, `doctor`, and structured errors when JSON mode is requested.
- Stable process exit categories for usage, validation, state unavailable, runtime unavailable, confirmation mismatch, unsafe operation, and partial failure.
- Local deterministic policy decisions for planner safety, cleanup classification, image policy, env/secret boundaries, lifecycle blockers, untrusted manifests, secure exposure blockers, and accelerator placeholders.
- Local extension declaration policy decisions plus `hostwright extension check` for one explicit reviewed-local, read-only, digest-bound, bounded version-1 process handshake with strict response binding and exact private-stage cleanup.
- Explicit local team profiles, strict-only digest/review requirements, exact mutation approval bindings, and redacted append-only local audit records.
- Local advisory scheduler reports for declared memory requests, workload class, port/policy blockers, fairness scoring, overcommit blockers, accelerator blockers, and remote-placement blockers. Reports are in-memory recommendations only and are not CLI placement commands.
- Local control-surface requirements plus `hostwright-control`, a bounded one-request JSON process for plan, status, events, recovery, and doctor with launch-fixed explicit paths and no mutation operation. GUI/design implementation remains future work.
- `hostwright status [path] --state-db <path>` with live RuntimeAdapter observation and event/snapshot persistence.
- `hostwright logs <service>` with bounded tail output through RuntimeAdapter and redaction.
- `hostwright events --state-db <path>` for persisted event ledger records, with project/type/service/severity/limit/sort filtering.
- `hostwright diagnostics --state-db <path> --bundle <path>` for a local redacted JSON bundle from existing state rows.
- `hostwright cleanup` dry-run classification and exact token-confirmed deletion of eligible Hostwright-owned stopped/created/exited containers.
- `hostwrightd --foreground --config <path> --state-db <path>` for a local foreground development loop that observes, plans, and records daemon events without runtime mutation.
- In-process loopback health checks from `health.command` for allowlisted probe command shapes and arguments, with redacted result/event persistence.
- Restart policy state with max attempts, backoff, manual-disable from `restart.policy: no`, preexisting operator hold state, and crash-loop blocking before managed start or managed restart is exposed as executable.
- `hostwright doctor` safe local checks.
- `hostwright doctor --output json` resource intelligence reports with local ProcessInfo-backed hardware and thermal facts, fixture-backed parser coverage, explicit unmeasured benchmark dimensions, architecture warnings only when evidence exists, and local-only/no-capacity limits.
- Doctor schema-v2 readiness for platform, Apple CLI/service status, selected-state path/integrity/permissions, local interfaces, signing/Gatekeeper trust, pressure, and tools. Runtime execution is limited to bounded RuntimeAdapter version/system-status probes; existing state is inspected immutably without creation or migration.
- `hostwright benchmark` for explicit local schema-v2 hardware reports using 3-10 bounded Hostwright-owned resources, real RuntimeAdapter version/stats probes, raw samples, optional attended sleep/wake detection, and exact cleanup. Historical schema-v1 fixtures remain contract evidence only.
- Source-only public release policy for `v0.1.0-alpha.1`.
- Developer-only `hostwright-dist` unsigned macOS ARM64 archive evidence with exact manifest/checksum/SPDX/provenance verification and atomic temp-prefix install/upgrade/downgrade/rollback/uninstall. Signing, notarization, installer, and publication stages remain blocked.
- Beta readiness checklist documentation for future beta tag approval, with current beta release publication still blocked.
- Apple silicon control-plane direction documentation that keeps current core single-host and blocks platform-expansion claims until separate evidence and maintainer approval exist.
- Documentation-site information architecture and source-of-truth boundaries for a separate `hostwright.dev` repository.
- Swift Package Manager module boundaries.
- RuntimeAdapter contract infrastructure, state scaffolds, reconciler scaffolds, health models, networking scaffolds, and observability scaffolds.
- Test-only scripted runtime adapter, process runner, executable resolver, and in-memory secret store under `Tests/HostwrightTestSupport`.
- `AppleContainerReadOnlyAdapter` for read-only observation attempts through `RuntimeAdapter`.
- `SecureRuntimeProcessRunner` guarded by command classification, root-owned named resolution, minimal environment, descriptor-pinned working directory, bounded I/O/time, cancellation, process-group cleanup, and redaction.
- Fixture-defined Apple container observation parser for empty and running snapshots, including reviewed network attachment metadata in the versioned fixture schema.
- Exact labeled Apple container 1.0.0 observation for the current project, including owned orphans, unrelated-project filtering, and hostname, IPv4/IPv6, gateway, MAC, network-name, and MTU metadata.
- Collision-resistant versioned runtime identifiers, exact ownership labels, schema-v6 legacy identifier backfill, and exact-ID managed start/restart/cleanup gates.
- Verified real empty Apple container JSON list parsing for `container list --all --format json` output of `[]`.
- Verified real Apple builder-container list parsing as ignored non-Hostwright runtime state.
- Verified real created/stopped Hostwright proof container parsing.
- Verified real object-based Apple container image list parsing by `configuration.name`.
- SQLite state store using system `SQLite3`.
- Explicit schema migrations.
- State migration checksums, future-schema refusal, and actionable locked/corrupt database errors.
- Repository state reads validate schema without implicitly creating or migrating databases.
- Desired-state snapshot persistence.
- Observed runtime snapshot persistence.
- Event ledger persistence.
- Operation ledger records for future mutation safety.
- Ownership records for cleanup/apply decisions.
- Health check result records.
- Restart policy state records.
- Restart recovery records for managed restart attempts.
- Operation recovery groups and step records for apply checkpoints, partial failures, interruption diagnostics, and manual recovery hints.
- Local-only telemetry policy reporting in doctor/status/diagnostics output.
- Explicit-path state configuration only.
- Manifest-to-runtime desired-state mapping outside the CLI.
- Typed deterministic drift records, plan issues, planned actions, and plan hash.
- Planning policy checks for duplicate desired host ports, observed host-port conflicts, unsafe broad bind addresses, privileged host ports, unsafe host-root or parent-traversal mount sources, ambiguous mounts, invalid identities, and secret-like environment values through the local policy evaluator.
- Hostwright-created Apple container port publishes are explicitly localhost-scoped by default.
- Drift detection for missing, unmanaged, stopped, exited, failed, image mismatch, port mismatch, mount mismatch, unhealthy, duplicate observed identity, unsupported observed state, and unavailable observation cases.
- `hostwright apply [path] --state-db <path> --confirm-plan <hash>` for one create-missing-service action, one restart-policy-allowed managed start action, or one restart-policy-allowed managed restart action.
- Operation intent persistence before mutation.
- Apply success/failure event persistence.
- Runtime mutation policy for `createMissingService`, `startManagedService`, `restartManagedService`, and `deleteManagedContainer`.
- Disposable live create/start/logs/cleanup proofs for Hostwright-owned proof containers, including stale-hash refusal and exact proof cleanup.
- Cleanup dry-run classifications for eligible, ambiguous, stale, running, unknown, blocked, and never-delete ownership-backed and observed-only resources.
- Source-material preservation and Hostwright naming controls.
- Governance, contribution, security reporting, review-trigger, and pull request template guidance for maintainer-reviewed changes.

## Not Implemented Today

- General runtime mutation.
- Automatic manifest upgrade, downgrade, or runtime compatibility conversion.
- General YAML parsing, broad stack-file import, or full orchestrator schema compatibility.
- Default CLI activation of live macOS Keychain access; production Keychain writes/deletes; Keychain prompts; Keychain access groups; synchronizable Keychain items; registry credential storage; credential sync; credential upload; or cloud identity integration.
- Registry image resolution, tag-to-digest lookup, automatic image pulls, signature verification, OCI referrer inspection, SBOM generation/validation, vulnerability scanning, dependency provenance, or source-build integrity automation.
- Runtime density measurement, VM-per-container overhead measurement, sustained battery-efficiency testing, sustained thermal testing, automatic sleep/wake proofing, or production workload-capacity benchmarking.
- Hosted-CI Apple container benchmarks, benchmark number publication, performance comparison claims, production capacity claims, or hosted performance monitoring.
- Production capacity planning, automatic placement decisions, daemon-enforced scheduling, or resource reservations.
- Documentation-site frontend, hosted docs deployment, website search, website analytics, generated site content pipeline, marketing campaign, or website repository implementation in this core repository.
- Apple GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator helpers, host accelerator device exposure, or accelerator-aware scheduling.
- Multi-action `hostwright apply`.
- Guaranteed Apple container observation on every machine.
- Broad non-empty Apple container JSON list parsing beyond verified builder, state-backed legacy, and exact labeled Apple container 1.0.0 shapes.
- Localhost HTTP reachability evidence on the current proof host; the Apple container listener accepts then resets while macOS Local Network access for `container-runtime-linux` is disabled.
- Broad non-empty Apple container image list parsing beyond the verified object shape.
- JSON output for `validate`, `apply`, `logs`, and `cleanup` success paths.
- Shell completion installation or shell profile mutation.
- User-facing Apple container stop/restart commands, remove, broad cleanup, image deletion, volume deletion, log follow, attach, exec, or detailed inspect operations.
- Automatic rollback or inverse runtime mutation after partial failure.
- Runtime mutation beyond create-missing-service, managed start, managed restart, and exact cleanup-eligible container delete.
- Container-exec or interactive health checks.
- Aggressive restart loops or daemon-enforced restart mutation.
- Background daemon service, launch agent installation, keepalive, or unattended runtime mutation.
- Broad cleanup, teardown, garbage collection, image deletion, volume deletion, or unmanaged deletion.
- Hidden global state writes.
- GA durability SLO, generalized file-pressure/disk-fault qualification, and long-soak evidence; authoritative-row or arbitrary-page salvage remains forbidden.
- Remote policy service, team policy workflow, central policy distribution, silent policy bypass, policy-driven runtime mutation, or automatic policy remediation.
- Generic plugin loading, extension discovery/installation/persistence/distribution, capability payloads or invocation, operating-system sandboxing, restriction of reviewed code's ambient user privileges, containment after deliberate native session escape, remote plugin registry, untrusted extension execution, runtime-mutation extensions, state-write extensions, networking-provider extensions, tunnel-provider extensions, secret-backend extensions, or accelerator extensions.
- Cloud team service, central remote control, hosted audit log, user tracking, enterprise support workflow, remote policy distribution, macOS user/group/ACL management, MDM integration, or shared-secret management.
- External telemetry, hosted diagnostics, automatic bundle upload, OSLog integration, or production support-bundle workflows.
- Launch agent or service installer.
- DNS behavior.
- Service discovery, network alias, reverse proxy, or public exposure management.
- Tunnel management.
- Cloudflare Tunnel, Tailscale Serve/Funnel, WireGuard, mTLS provisioning, or reverse proxy setup.
- Cloud control plane.
- Kubernetes-class Apple silicon control plane.
- Web dashboard.
- GUI implementation, persistent daemon API, socket/HTTP listener, background control service, remote control surface, or mutation endpoint in `hostwright-control`.
- Production readiness.
- Beta release tag, beta GitHub Release, beta compatibility claim, or maintainer-approved beta support boundary.
- Public binary downloads, `.pkg` installers, system install scripts, Homebrew formulae, package-channel support, launch agents, privileged helpers, or system-prefix installation.
- Developer ID signing proof, notarization submission proof, stapling proof, Gatekeeper verification proof, signed/trusted provenance, dependency or image SBOM claims, vulnerability scanning, or binary release publication.
- Enforced CODEOWNERS, branch protection, support SLA, enterprise support workflow, hosted diagnostics, telemetry upload, or cloud support service.

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
- Attach, exec, log-follow, or port-forward compatibility.
- External scheduler API compatibility.
- Multi-Mac orchestration.
- Remote host agents, membership service, peer discovery, state replication, remote mutation, remote placement, or scheduler API.
- Local DNS resolver.
- Cloudflare, Tailscale, WireGuard, or other tunnel integration.
- Cloud control plane.
- GPU/ANE scheduling.
- Metal, Core ML, or MLX container support promises.
- PyTorch MPS container support, host-native accelerator helpers, or accelerator device exposure.
- Accelerator-aware placement from resource intelligence.
- Platform expansion inside current core without a separate threat model, conformance plan, state-authority design, disposable proof path, and maintainer approval.
- Automatic destructive garbage collection.
- Privileged helper unless a future design record and threat model prove it is necessary.

## Parser Limitation

The manifest parser is not a general YAML parser. It accepts only the documented Hostwright manifest subset and fails closed for unsupported YAML features, unsupported manifest versions, unknown Kubernetes/Compose-style fields, unsafe environment keys, and unsafe host-root or parent-traversal mount sources. Expanding beyond that subset requires a dependency/design decision before the manifest surface grows.

The stack-file importer is also not a general YAML or Compose parser. It converts only the reviewed import subset and fails closed for unsupported networking, discovery, build, deploy, secret, config, named-volume, shell-healthcheck, lifecycle, cloud, and tunnel semantics. Import output is text for operator review; it does not write manifests, observe runtime, pull images, inspect registries, or run compatibility shims.

External orchestration compatibility remains research-only. Phase 29 rejects current-core CRI shims, Kubernetes node behavior, Docker API shims, Testcontainers target behavior, full Compose parity, attach, exec, log-follow, and port-forward compatibility because those contracts require protocol, stream, lifecycle, state-authority, identity, networking, logging, and scheduler behavior outside Hostwright's local `RuntimeAdapter` scope. Any prototype requires a separate maintainer-approved issue.

Multi-host platform work remains research-only. Phase 30 keeps current core single-host and rejects current-core remote host agents, membership service, peer discovery, state replication, remote mutation, remote placement, cloud control plane, and scheduler API behavior because those contracts require host identity, transport trust, state authority, quorum or other replication semantics, failure recovery, audit, and scheduler policy outside the current local state model. Any prototype requires a separate maintainer-approved issue.

Manifest image trust is limited to local reference policy. `imagePolicy: require-digest` rejects tag-only service images unless they include a `sha256` digest. Hostwright does not query registries, resolve tags, verify signatures, inspect SBOMs, scan vulnerabilities, or prove provenance.

## Runtime Truth

The runtime module contains Apple container observation infrastructure and narrow mutation command descriptors. `hostwright plan` renders deterministic desired-state and policy planning output without live runtime observation by default. `hostwright status --state-db <path>` performs live RuntimeAdapter observation and records a status event. Status still does not prove reachability or application-level health beyond the observed runtime state.

The runtime parser accepts the fixture-defined `hostwright.apple-container.observation.v1` schema, the verified real empty JSON array shape returned by `container list --all --format json`, ignored Apple builder output, state-backed legacy rows, and exact labeled Apple container 1.0.0 rows with reviewed network fields. Unsupported, malformed, mismatched-current-project, or broader real Apple container JSON output fails closed with redacted errors.

Apply is not general lifecycle management. It uses `container create` only after explicit plan confirmation, idempotency checks, operation intent persistence, local image confirmation, and safe-subset validation. Created port bindings are emitted as explicit `127.0.0.1:host:container` publishes. It uses `container start <id>` only for one observed Hostwright-owned stopped/created/exited service when restart policy allows a managed start. It uses an internal `container stop <id>` then `container start <id>` sequence only for one exact Hostwright-owned running service when restart policy allows managed restart, the explicit state database has a fresh unhealthy health result for the service, and recovery records are written. Cleanup uses `container delete <id>` only after dry-run token confirmation and ownership/live-state eligibility checks.

Recovery is diagnostic and manual. `hostwright recovery` reads operation groups and steps from the explicit state database and reports whether an apply operation completed, failed, or was interrupted. It does not observe Apple container, retry mutation, stop/start/delete resources, or roll back changes automatically.

Diagnostics are local and manual. `hostwright diagnostics` reads existing state rows from the explicit state database and writes a redacted JSON bundle to an explicit file path. It does not observe Apple container, run health checks, create or migrate a missing database, overwrite existing bundle files, upload telemetry, or prove service reachability.

`hostwright doctor` is local and diagnostic. It runs bounded Apple CLI version and structured system-status probes only through `RuntimeAdapter`, verifies the running executable through public signing tools, reads public host/network/pressure facts, and immutably inspects an existing checkpointed state database. It does not list or inspect workload containers, create proof containers, pull images, create/migrate/repair state, request Local Network authorization, upload telemetry, or prove runtime density, VM overhead, boot latency, battery behavior, sleep/wake behavior, workload memory pressure, or production capacity. The extended resource report retains explicit `unmeasured` observations for dimensions that were not measured.

`hostwright benchmark` is separate from doctor and is explicitly mutating. It requires live confirmation, a pre-existing local image, bounded sample count, explicit source evidence, and a non-existing report path. It creates only unique labeled benchmark resources through `RuntimeAdapter`, never pulls an image, and deletes only exact identifiers after terminal-state quiescence. A missing battery or unattended sleep/wake interval blocks the report; any command, version, identity, ownership, or cleanup failure fails it. One report does not prove capacity, efficiency, compatibility beyond its exact versions, or performance on another host.

Policy evaluation is local and deterministic. Team workflow command wiring may persist bound audit records through explicit `HostwrightState` paths, but policy code itself does not execute Apple container commands, write SQLite, contact registries, resolve DNS, configure tunnels, distribute team policy, or weaken required gates. `HostwrightExtensions` is separate from policy and can run only the fixed reviewed-local handshake; it receives no RuntimeAdapter, SQLite, state, secret, networking, accelerator, or mutation authority.

`hostwright-control` is also separate from runtime and state modules. It validates one strict request, fixes all file paths at process launch, and delegates only to existing Hostwright CLI JSON contracts. Its operations do not mutate runtime. State-backed status can still observe runtime and perform the existing explicit-database schema migration, snapshot, and audit writes; events and recovery read an existing explicit database. The process opens no listener and exposes no apply, cleanup, logs, diagnostics export, benchmark, extension execution, arbitrary command, or default path.

Advisory scheduling is local and diagnostic. It produces deterministic in-memory recommendations, scores, reason codes, and remediation text from declared inputs and existing policy decisions, but it does not execute Apple container commands, write state, reserve capacity, mutate manifests, update runtime placement, expose a scheduler API, place workloads remotely, or schedule accelerators.

Accelerator work is research-only. Current Hostwright core does not expose Apple GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator helpers, host accelerator devices, or accelerator-aware scheduler behavior. Any future change requires a separate implementation issue, official supported access path or host-native design, versioned disposable proof, threat model, Phase 32 policy gate, and maintainer approval.

## State Truth

The SQLite store writes only to explicit paths supplied by the caller. Hostwright does not choose a default path under the repository, Application Support, XDG locations, or any global directory.

Hostwright persists adapter-shaped observed state and can consume runtime-shaped observed state in memory for planning. Apply, status, logs, events, diagnostics, cleanup, and foreground `hostwrightd` write or read state only through explicit `--state-db` paths. Hostwright does not add a default state path, background daemon service, unattended mutation, broad cleanup, external telemetry, or production durability guarantees.
