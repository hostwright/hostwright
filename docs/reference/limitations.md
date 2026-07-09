# Limitations

Hostwright `v0.1.0-alpha.1` can model and attempt read-only runtime observation through `RuntimeAdapter`, persist desired and observed state to an explicit SQLite database path, compute deterministic desired-vs-observed plans, produce local advisory scheduling recommendations from declared inputs, execute one tightly gated create-missing-service mutation, execute one restart-policy-allowed managed start, execute one restart-policy-allowed managed restart for an exact Hostwright-owned running/unhealthy service, read bounded logs, render and filter state events, write a local redacted diagnostics bundle, run a foreground daemon loop with in-process loopback health probes and restart-state blocking, and delete exact cleanup-eligible Hostwright-owned stopped/created/exited containers through `RuntimeAdapter`.

Hostwright is not production ready.

## Implemented Today

- Dependency-free CLI command routing.
- `hostwright --version`.
- `hostwright init` without overwrite.
- `hostwright validate` for a restricted Hostwright manifest subset.
- Manifest `version: 1` support with versionless alpha manifests treated as legacy version 1 input.
- Manifest `imagePolicy: require-digest` support for local `@sha256:<64 lowercase hex characters>` image reference validation before planning or mutation.
- Manifest `secretEnv` support for local `keychain://<service>/<account>` secret references, with fake backend tests and no live Keychain default.
- Fail-closed unsupported-field, unsupported-version, unsupported DNS/discovery/networking-field, unsafe env-key, and unsafe host-root or parent-traversal mount-source validation for untrusted manifests.
- `hostwright import-stack <path>` conversion for a narrow safe stack-file subset, printing converted `hostwright.yaml` text without writing files, observing runtime, touching state, or claiming Compose compatibility.
- `hostwright plan` as non-mutating manifest-level dry-run output.
- `--output json` for `import-stack`, `plan`, `status`, `events`, `recovery`, `doctor`, and structured errors when JSON mode is requested.
- Stable process exit categories for usage, validation, state unavailable, runtime unavailable, confirmation mismatch, unsafe operation, and partial failure.
- Local deterministic policy decisions for planner safety, cleanup classification, image policy, env/secret boundaries, lifecycle blockers, untrusted manifests, secure exposure blockers, and accelerator placeholders.
- Local extension declaration policy decisions for built-in or reviewed-local non-mutating capability declarations, with fail-closed trust, version, boundary, runtime-mutation, state-write, networking, tunnel, secret-resolution, and accelerator decisions.
- Local team policy profile decisions for explicit opt-in profiles, required gates, local approval records, and policy override declarations.
- Local advisory scheduler reports for declared memory requests, workload class, port/policy blockers, fairness scoring, overcommit blockers, accelerator blockers, and remote-placement blockers. Reports are in-memory recommendations only and are not CLI placement commands.
- Local control-surface requirements and API boundary documentation for a future separate GUI/design owner.
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
- Phase 36 benchmark lab report models and fixture parser for dry-run methodology records, disposable-resource policy, environment facts, and unmeasured dimensions.
- Source-only release candidate packaging for `v0.1.0-alpha.1`.
- Release distribution readiness documentation for future signed and notarized artifacts, with current binary and installer publication still blocked.
- Beta readiness checklist documentation for future beta tag approval, with current beta release publication still blocked.
- Documentation-site information architecture and source-of-truth boundaries for a separate `hostwright.dev` repository.
- Swift Package Manager module boundaries.
- RuntimeAdapter contract infrastructure, state scaffolds, reconciler scaffolds, health models, networking scaffolds, and observability scaffolds.
- `MockRuntimeAdapter` and fake runtime process runner for tests only.
- `AppleContainerReadOnlyAdapter` for read-only observation attempts through `RuntimeAdapter`.
- `FoundationRuntimeProcessRunner` guarded by read-only command classification, executable resolution, timeouts, and redaction.
- Fixture-defined Apple container observation parser for empty and running snapshots, including reviewed network attachment metadata in the versioned fixture schema.
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
- Live macOS Keychain access, Keychain prompts, Keychain access groups, synchronizable Keychain items, registry credential storage, credential sync, credential upload, or cloud identity integration.
- Registry image resolution, tag-to-digest lookup, automatic image pulls, signature verification, OCI referrer inspection, SBOM generation/validation, vulnerability scanning, dependency provenance, or source-build integrity automation.
- Runtime density measurement, VM-per-container overhead measurement, boot-latency benchmarking, polling-overhead benchmarking, battery-impact measurement, sleep/wake runtime proofing, or workload memory-pressure benchmarking as automatic product behavior.
- Live benchmark command execution, CI Apple container benchmark execution, benchmark number publication, Apple container version drift live probing, performance comparison claims, production capacity claims, or hosted performance monitoring.
- Production capacity planning, automatic placement decisions, daemon-enforced scheduling, or resource reservations.
- Documentation-site frontend, hosted docs deployment, website search, website analytics, generated site content pipeline, marketing campaign, or website repository implementation in this core repository.
- Apple GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator helpers, host accelerator device exposure, or accelerator-aware scheduling.
- Multi-action `hostwright apply`.
- Guaranteed Apple container observation on every machine.
- Broad non-empty Apple container JSON list parsing beyond the verified builder/proof shapes.
- Non-empty real Apple container network attachment parsing until a reviewed fixture defines the schema.
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
- Default user database path.
- Hidden global state writes.
- Production durability or automatic corruption-recovery guarantees.
- Remote policy service, team policy workflow, central policy distribution, silent policy bypass, policy-driven runtime mutation, or automatic policy remediation.
- Plugin loader, remote plugin registry, binary plugin distribution, untrusted extension execution, runtime-mutation extensions, state-write extensions, networking-provider extensions, tunnel-provider extensions, secret-backend extensions, or accelerator extensions.
- Cloud team service, central remote control, hosted audit log, user tracking, enterprise support workflow, remote policy distribution, macOS user/group/ACL management, MDM integration, or shared-secret management.
- Online state backup, restore, or repair commands.
- External telemetry, hosted diagnostics, automatic bundle upload, OSLog integration, or production support-bundle workflows.
- Launch agent or service installer.
- DNS behavior.
- Service discovery, network alias, reverse proxy, or public exposure management.
- Tunnel management.
- Cloudflare Tunnel, Tailscale Serve/Funnel, WireGuard, mTLS provisioning, or reverse proxy setup.
- Cloud control plane.
- Web dashboard.
- GUI implementation, daemon API, or local control-surface runtime.
- Production readiness.
- Beta release tag, beta GitHub Release, beta compatibility claim, or maintainer-approved beta support boundary.
- Binary downloads, installer packages, Homebrew formulae, signing, notarization, SBOM, vulnerability scanning, or binary provenance.
- Install scripts, uninstaller behavior, upgrade/downgrade smoke tests, rollback proof, package-channel support, Developer ID signing proof, notarization submission proof, stapling proof, Gatekeeper verification proof, or binary release publication.
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

The runtime parser accepts the fixture-defined `hostwright.apple-container.observation.v1` schema, the verified real empty JSON array shape returned by `container list --all --format json`, Apple builder container output that is ignored, and the verified `hostwright-proof-web` created/stopped output. Unsupported, malformed, or broader real Apple container JSON output fails closed with redacted errors.

Apply is not general lifecycle management. It uses `container create` only after explicit plan confirmation, idempotency checks, operation intent persistence, local image confirmation, and safe-subset validation. Created port bindings are emitted as explicit `127.0.0.1:host:container` publishes. It uses `container start <id>` only for one observed Hostwright-owned stopped/created/exited service when restart policy allows a managed start. It uses an internal `container stop <id>` then `container start <id>` sequence only for one exact Hostwright-owned running service when restart policy allows managed restart, the explicit state database has a fresh unhealthy health result for the service, and recovery records are written. Cleanup uses `container delete <id>` only after dry-run token confirmation and ownership/live-state eligibility checks.

Recovery is diagnostic and manual. `hostwright recovery` reads operation groups and steps from the explicit state database and reports whether an apply operation completed, failed, or was interrupted. It does not observe Apple container, retry mutation, stop/start/delete resources, or roll back changes automatically.

Diagnostics are local and manual. `hostwright diagnostics` reads existing state rows from the explicit state database and writes a redacted JSON bundle to an explicit file path. It does not observe Apple container, run health checks, create or migrate a missing database, overwrite existing bundle files, upload telemetry, or prove service reachability.

`hostwright doctor` resource intelligence is also local and diagnostic. It records host facts and explicit `unmeasured` observations for benchmark dimensions that were not measured. It does not run Apple container commands, create proof containers, pull images, write state, upload telemetry, or prove runtime density, VM overhead, boot latency, battery behavior, sleep/wake behavior, workload memory pressure, or production capacity.

Policy evaluation is local and diagnostic. It produces deterministic decisions, reason codes, and remediation text for current gates, extension declarations, and team profile declarations, but it does not execute Apple container commands, write state, contact registries, resolve DNS, configure tunnels, distribute team policy, load plugins, run extension code, or apply overrides automatically.

Advisory scheduling is local and diagnostic. It produces deterministic in-memory recommendations, scores, reason codes, and remediation text from declared inputs and existing policy decisions, but it does not execute Apple container commands, write state, reserve capacity, mutate manifests, update runtime placement, expose a scheduler API, place workloads remotely, or schedule accelerators.

Accelerator work is research-only. Current Hostwright core does not expose Apple GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator helpers, host accelerator devices, or accelerator-aware scheduler behavior. Any future change requires a separate implementation issue, official supported access path or host-native design, versioned disposable proof, threat model, Phase 32 policy gate, and maintainer approval.

## State Truth

The SQLite store writes only to explicit paths supplied by the caller. Hostwright does not choose a default path under the repository, Application Support, XDG locations, or any global directory.

Hostwright persists adapter-shaped observed state and can consume runtime-shaped observed state in memory for planning. Apply, status, logs, events, diagnostics, cleanup, and foreground `hostwrightd` write or read state only through explicit `--state-db` paths. Hostwright does not add a default state path, background daemon service, unattended mutation, broad cleanup, external telemetry, or production durability guarantees.
