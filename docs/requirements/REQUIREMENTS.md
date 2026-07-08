# Requirements

This file gives Hostwright stable requirement IDs for the first supported release. Requirements are source-grounded in the preserved source documents and naming archive.

Status values:

- Implemented: present in the current repo.
- Partially implemented: a boundary, stub, or narrow subset exists.
- Planned: required for first supported release but not built yet.
- Deferred: intentionally later than first supported release.
- Rejected: explicitly out of scope.

## Naming

| ID | Requirement | Source document | Current status | Implementation file if any | Test coverage if any | Release phase |
| --- | --- | --- | --- | --- | --- | --- |
| HW-NAME-001 | Public project name must be Hostwright. | Naming Convention Folder | Implemented | `Sources/HostwrightCore/HostwrightIdentity.swift`, `docs/naming/` | `scripts/grep-orchard.sh .` | 0 |
| HW-NAME-002 | CLI name must be `hostwright`. | Naming Convention Folder | Implemented | `Package.swift`, `Sources/HostwrightCore/HostwrightIdentity.swift` | SwiftPM build; CLI smoke tests | 1 |
| HW-NAME-003 | Daemon name must be `hostwrightd`. | Naming Convention Folder | Implemented for foreground dev mode | `Package.swift`, `Sources/HostwrightDaemon/main.swift`, `Sources/HostwrightDaemonCore/` | SwiftPM build; daemon XCTest cases | 1, 15 |
| HW-NAME-004 | Manifest filename must be `hostwright.yaml`. | Naming Convention Folder | Implemented | `Sources/HostwrightCore/HostwrightIdentity.swift` | CLI and manifest smoke tests | 2 |
| HW-NAME-005 | Old codename references must remain only in source-material or naming-history contexts. | Naming Convention Folder | Partially implemented | `scripts/grep-orchard.sh`, `docs/source-material/README.md`, `docs/naming/` | `scripts/grep-orchard.sh .` | 0 |

## CLI

| ID | Requirement | Source document | Current status | Implementation file if any | Test coverage if any | Release phase |
| --- | --- | --- | --- | --- | --- | --- |
| HW-CLI-001 | CLI must route command intent without owning business logic. | Final Production Arsenal | Partially implemented | `Sources/HostwrightCLI/` | CLI smoke tests | 2 |
| HW-CLI-002 | `hostwright --version` must print a development or release version. | Phase 2 maintainer scope; naming archive command surface | Implemented | `Sources/HostwrightCLI/main.swift` | CLI smoke tests | 2 |
| HW-CLI-003 | `hostwright init` must create `hostwright.yaml` without overwriting by default. | Agent Engineering Manual | Implemented | `Sources/HostwrightCLI/main.swift` | CLI smoke tests | 2 |
| HW-CLI-004 | `hostwright validate` must validate manifest shape without registry or runtime calls. | Agent Engineering Manual | Implemented for restricted subset | `Sources/HostwrightCLI/main.swift`, `Sources/HostwrightManifest/` | CLI and manifest smoke tests | 2 |
| HW-CLI-005 | `hostwright plan` must be non-mutating and show when runtime observation is not connected. | Agent Engineering Manual | Implemented with Phase 7 deterministic planning output | `Sources/HostwrightCLI/main.swift`, `Sources/HostwrightReconciler/` | CLI and reconciler XCTest cases | 2, 7 |
| HW-CLI-006 | `hostwright status` must not claim runtime state unless observed. | Agent Engineering Manual | Implemented for manifest-level and live RuntimeAdapter status paths with parser and local-only telemetry metadata | `Sources/HostwrightCLI/main.swift`, `Sources/HostwrightCLI/StatusCommand.swift` | CLI XCTest cases | 2, 9, 20 |
| HW-CLI-007 | `hostwright doctor` must run safe local checks. | Final Production Arsenal; Document 2 | Implemented for local checks, telemetry policy, and resource intelligence reporting | `Sources/HostwrightHealth/DoctorModels.swift`, `Sources/HostwrightHealth/ResourceIntelligenceModels.swift`, `Sources/HostwrightCLI/main.swift` | CLI and health smoke tests | 2, 26 |
| HW-CLI-008 | `hostwright apply` must validate, plan, persist intent, apply idempotently, and emit events. | Agent Engineering Manual | Partially implemented for one create-missing-service action, one restart-policy-allowed managed start action, or one restart-policy-allowed managed restart action | `Sources/HostwrightCLI/ApplyCommand.swift`, `Sources/HostwrightCLI/CLICommand.swift` | CLI XCTest cases for plan-hash refusal, intent persistence, create success/failure, managed start, and managed restart recovery | 8, 9, 17 |
| HW-CLI-009 | Operability commands must expose status, logs, events, recovery, diagnostics, and cleanup without bypassing RuntimeAdapter or explicit state paths. | Agent Engineering Manual; Final Production Arsenal | Implemented for current scope | `Sources/HostwrightCLI/StatusCommand.swift`, `Sources/HostwrightCLI/LogsCommand.swift`, `Sources/HostwrightCLI/EventsCommand.swift`, `Sources/HostwrightCLI/RecoveryCommand.swift`, `Sources/HostwrightCLI/DiagnosticsCommand.swift`, `Sources/HostwrightCLI/CleanupCommand.swift` | CLI XCTest cases | 9, 18, 20 |

## Manifest

| ID | Requirement | Source document | Current status | Implementation file if any | Test coverage if any | Release phase |
| --- | --- | --- | --- | --- | --- | --- |
| HW-MANIFEST-001 | Manifest must be named `hostwright.yaml`. | Naming Convention Folder | Implemented | `HostwrightIdentity.manifestFileName` | CLI smoke tests | 2 |
| HW-MANIFEST-002 | Manifest must define a local project and services. | Agent Engineering Manual | Implemented with optional `version: 1` policy | `Sources/HostwrightManifest/ManifestModel.swift` | Manifest smoke tests | 2, 13 |
| HW-MANIFEST-003 | Manifest parser must fail closed on unsupported Phase 2 shapes. | Phase 2 maintainer scope | Implemented with contextual unsupported-field errors | `Sources/HostwrightManifest/ManifestParser.swift` | Manifest smoke tests | 2, 13 |
| HW-MANIFEST-004 | Full YAML parser dependency decision must be made before expanding beyond the restricted subset. | Final Production Arsenal | Satisfied for Phase 13: no YAML dependency added; parser remains restricted | `Sources/HostwrightManifest/ManifestParser.swift`, `docs/reference/manifest.md` | Manifest smoke tests and docs review | 4, 13 |
| HW-MANIFEST-005 | Manifest must eventually support image digest and architecture policy. | Document 2 | Partially implemented for local digest-reference policy; architecture policy remains planned | `Sources/HostwrightManifest/ImageReferencePolicy.swift`, `Sources/HostwrightManifest/ManifestModel.swift`, `schemas/hostwright-yaml.schema.json`, `docs/architecture/supply-chain-image-trust.md` | Manifest smoke tests and schema alignment tests | 7, 25 |

## Validation

| ID | Requirement | Source document | Current status | Implementation file if any | Test coverage if any | Release phase |
| --- | --- | --- | --- | --- | --- | --- |
| HW-VALID-001 | Validate project and service names. | Agent Engineering Manual | Implemented | `ManifestValidator.swift` | Manifest smoke tests | 2 |
| HW-VALID-002 | Validate every service has an image. | Agent Engineering Manual | Implemented | `ManifestValidator.swift` | Manifest smoke tests | 2 |
| HW-VALID-003 | Validate port syntax before any runtime action. | Agent Engineering Manual; Document 3 | Implemented for string ports | `ManifestValidator.swift`, `HostwrightNetworking/NetworkingModels.swift` | Manifest and networking smoke tests | 2 |
| HW-VALID-004 | Validate volumes conservatively and block unsafe host mounts before mutation. | Document 2 | Implemented for host-root and parent-traversal mount-source rejection plus planning policy | `ManifestValidator.swift`, `Sources/HostwrightReconciler/PlanningPolicy.swift` | Manifest and reconciler XCTest cases | 7, 13 |
| HW-VALID-005 | Validate secrets/env paths to prevent credential leakage. | Document 2 | Implemented for env-key shape, plaintext credential-like env rejection, `secretEnv` reference shape, desired env planning/redaction; observed env drift remains deferred | `ManifestValidator.swift`, `Sources/HostwrightSecrets/SecretStore.swift`, `Sources/HostwrightReconciler/PlanningPolicy.swift`, `Sources/HostwrightReconciler/PlanRenderer.swift` | Manifest, secrets, CLI, and reconciler XCTest cases | 7, 13, 24 |
| HW-VALID-006 | Validate unsupported runtime and networking features explicitly. | Agent Engineering Manual; Document 3 | Implemented for restricted manifest parser, unsupported-field errors, and limitations docs | `docs/reference/limitations.md`, `ManifestParser.swift` | Docs review; manifest smoke tests | 3, 13 |

## RuntimeAdapter

| ID | Requirement | Source document | Current status | Implementation file if any | Test coverage if any | Release phase |
| --- | --- | --- | --- | --- | --- | --- |
| HW-RUNTIME-001 | Every runtime operation must go through `RuntimeAdapter`. | Agent Engineering Manual; Final Production Arsenal | Implemented for read-only observation, logs, create, managed start, managed restart, and cleanup delete | `Sources/HostwrightRuntime/RuntimeAdapter.swift`, `Sources/HostwrightRuntime/RuntimeModels.swift`, `Sources/HostwrightRuntime/AppleContainerReadOnlyAdapter.swift`, `Sources/HostwrightRuntime/AppleContainerApplyAdapter.swift` | Runtime and reconciler XCTest cases; boundary scans | 4, 8, 9, 17 |
| HW-RUNTIME-002 | No reconciler or CLI code may call Apple container directly. | Agent Engineering Manual; Final Production Arsenal | Implemented for runtime behavior | Runtime behavior is isolated in `HostwrightRuntime`; current CLI process lookup remains documented as a non-runtime doctor/toolchain exception. | Boundary scans; code review | 4, 8 |
| HW-RUNTIME-003 | Adapter must expose typed observation, planning, events, and errors. | Agent Engineering Manual | Implemented as contract infrastructure | `RuntimeAdapter.swift`, `RuntimeModels.swift`, `MockRuntimeAdapter.swift` | Runtime smoke tests | 4 |
| HW-RUNTIME-004 | Runtime subprocess execution must have timeouts, stderr capture, cancellation, and typed errors. | Agent Engineering Manual | Implemented for supported read-only commands plus create, managed start, managed restart, and cleanup delete command kinds | `RuntimeCommand.swift`, `RuntimeRedaction.swift`, `FoundationRuntimeProcessRunner.swift`, `RuntimeExecutableResolver.swift` | Runtime XCTest cases with fake runner; build coverage for live runner | 4, 8, 9, 17 |
| HW-RUNTIME-005 | Apple container observation must begin read-only before mutation. | Final Production Arsenal | Implemented as read-only adapter infrastructure with verified empty, builder, and proof-container real output shapes | `AppleContainerReadOnlyAdapter.swift`, `AppleContainerCommand.swift`, `AppleContainerObservationParser.swift` | Runtime XCTest cases with fixture-defined and verified real-shape fixtures | 5, 8 |
| HW-RUNTIME-006 | Runtime mutation must not begin until state, planning, and safety gates exist. | Agent Engineering Manual; Document 2 | Partially implemented as narrow create, managed start, managed restart, and cleanup-delete gates only | `RuntimeAdapter.swift`, `RuntimeCommand.swift`, `AppleContainerApplyAdapter.swift`, `MockRuntimeAdapter.swift` | Runtime XCTest cases for accepted supported specs and rejected mutating/forbidden/unknown specs | 8, 9, 17 |

## State / SQLite

| ID | Requirement | Source document | Current status | Implementation file if any | Test coverage if any | Release phase |
| --- | --- | --- | --- | --- | --- | --- |
| HW-STATE-001 | Desired state must be stored durably in SQLite. | Agent Engineering Manual; Final Production Arsenal | Implemented for explicit local database paths | `Sources/HostwrightState/SQLiteStateStore.swift`, `Sources/HostwrightState/StateRepositories.swift` | State smoke tests with temp SQLite database | 6 |
| HW-STATE-002 | State store must include migrations and transaction boundaries. | Agent Engineering Manual; Final Production Arsenal | Implemented with checksums, compatibility checks, and explicit migration boundary | `Sources/HostwrightState/MigrationRunner.swift`, `Sources/HostwrightState/SQLiteConnection.swift` | Migration and repository smoke tests | 6, 14 |
| HW-STATE-003 | Event, operation, and recovery records must survive process restart. | Agent Engineering Manual; Document 2 | Implemented as persistence records only | `Sources/HostwrightState/StateRepositories.swift`, `Sources/HostwrightState/StateRecords.swift` | State smoke tests reload persisted records | 6, 18 |
| HW-STATE-004 | Secrets must not be stored in plaintext state. | Document 2 | Implemented for Phase 6 repository writes | `Sources/HostwrightState/StateRepositories.swift`, `Sources/HostwrightState/StateJSON.swift` | State smoke tests assert fake secrets are redacted | 6 |
| HW-STATE-005 | Ownership ledger must distinguish Hostwright-owned resources from user-owned resources. | Agent Engineering Manual; Document 2 | Implemented and used as cleanup authority for Phase 9 exact container delete | `Sources/HostwrightState/StateRepositories.swift`, `Sources/HostwrightState/StateRecords.swift`, `Sources/HostwrightCLI/CleanupCommand.swift` | Ownership and cleanup XCTest cases | 6, 9 |
| HW-STATE-006 | State schema upgrades must fail closed for future, corrupt, locked, or incompatible databases. | Phase 14 maintainer scope | Implemented for explicit-path SQLite state | `Sources/HostwrightState/MigrationRunner.swift`, `Sources/HostwrightState/SQLiteConnection.swift`, `Sources/HostwrightState/StateStoreError.swift` | State XCTest cases for future schema, corrupt DB, locked DB, checksum mismatch, and unrelated DB refusal | 14 |
| HW-STATE-007 | State backup, restore, export, locking, and downgrade policy must be documented before daemon work. | Phase 14 maintainer scope | Implemented as operator policy docs only | `docs/architecture/state-store.md`, `docs/reference/install.md`, `docs/reference/limitations.md` | Docs review; acceptance matrix | 14 |

## Reconciler / Planner

| ID | Requirement | Source document | Current status | Implementation file if any | Test coverage if any | Release phase |
| --- | --- | --- | --- | --- | --- | --- |
| HW-RECON-001 | Reconciliation must compare desired and observed state as separate inputs. | Agent Engineering Manual | Implemented for Phase 7 planner input | `Sources/HostwrightReconciler/ReconciliationPlanner.swift`, `Sources/HostwrightReconciler/DriftDetector.swift` | Reconciler XCTest cases | 7 |
| HW-RECON-002 | Plans must be deterministic and non-mutating before apply. | Agent Engineering Manual; Document 2 | Implemented for Phase 7 dry-run planner | `Sources/HostwrightReconciler/DriftModels.swift`, `Sources/HostwrightReconciler/PlanRenderer.swift` | Reconciler and CLI XCTest cases | 7 |
| HW-RECON-003 | Drift detection must identify missing, stopped, unhealthy, and modified resources. | Agent Engineering Manual | Implemented for Phase 7 non-mutating planning | `Sources/HostwrightReconciler/DriftDetector.swift` | Reconciler XCTest cases | 7 |
| HW-RECON-004 | Apply must be idempotent and persist intent before mutation. | Agent Engineering Manual; Document 2 | Partially implemented for single confirmed createMissingService, startManagedService, and restartManagedService actions with operation group locking | `Sources/HostwrightCLI/ApplyCommand.swift`, `Sources/HostwrightReconciler/DriftDetector.swift`, `Sources/HostwrightState/StateRepositories.swift` | CLI, reconciler, and state XCTest cases | 8, 9, 17, 18 |
| HW-RECON-005 | Partial apply failure must leave recoverable operation records. | Document 2 | Implemented for current single-action apply scope through operation groups, checkpoints, steps, and manual recovery hints | `Sources/HostwrightCLI/ApplyCommand.swift`, `Sources/HostwrightCLI/RecoveryCommand.swift`, `Sources/HostwrightState/StateRecords.swift`, `Sources/HostwrightState/StateRepositories.swift` | CLI and state XCTest cases | 8, 17, 18 |

## Daemon

| ID | Requirement | Source document | Current status | Implementation file if any | Test coverage if any | Release phase |
| --- | --- | --- | --- | --- | --- | --- |
| HW-DAEMON-001 | `hostwrightd` must run only in explicit foreground development mode until launchd installation is separately approved. | Phase 15 maintainer scope | Implemented | `Sources/HostwrightDaemon/main.swift`, `Sources/HostwrightDaemonCore/DaemonCommand.swift` | Daemon command parser XCTest cases | 15 |
| HW-DAEMON-002 | Daemon reconciliation must require explicit config and state database paths. | Phase 15 maintainer scope | Implemented | `Sources/HostwrightDaemonCore/DaemonCommand.swift`, `Sources/HostwrightDaemonCore/DaemonCore.swift` | Daemon parser and loop XCTest cases | 15 |
| HW-DAEMON-003 | Daemon loop cadence, jitter, repeated-error backoff, shutdown, single-instance lock, and sleep/wake behavior must be testable. | Phase 15 maintainer scope | Implemented for foreground dev loop | `Sources/HostwrightDaemonCore/DaemonCore.swift`, `Sources/HostwrightDaemonCore/DaemonFileLock.swift` | Daemon fake-clock, backoff, shutdown, lock, and sleep/wake XCTest cases | 15 |
| HW-DAEMON-004 | Daemon loop must not perform unattended runtime mutation before a later policy authorizes it. | Phase 15 maintainer scope | Implemented by omission and tests | `Sources/HostwrightDaemonCore/DaemonCore.swift` | Daemon XCTest asserts `RuntimeAdapter.execute` is not called | 15 |
| HW-DAEMON-005 | Daemon health/restart reconciliation must record health results and restart policy state without starting or restarting services by itself. | Phase 16 maintainer scope | Implemented | `Sources/HostwrightDaemonCore/DaemonCore.swift` | Daemon health persistence and crash-loop blocking XCTest cases | 16 |

## Health

| ID | Requirement | Source document | Current status | Implementation file if any | Test coverage if any | Release phase |
| --- | --- | --- | --- | --- | --- | --- |
| HW-HEALTH-001 | Manifest must model health checks. | Agent Engineering Manual | Partially implemented | `ManifestModel.swift`, `ManifestValidator.swift` | Manifest smoke tests | 2 |
| HW-HEALTH-002 | Runtime health execution must be bounded, non-shell, and redacted before display or persistence. | Agent Engineering Manual; Phase 16 maintainer scope | Implemented for in-process loopback probes and direct true/false probes | `Sources/HostwrightRuntime/RuntimeHealthChecker.swift`, `Sources/HostwrightDaemonCore/DaemonCore.swift` | Runtime and daemon XCTest cases | 16 |
| HW-HEALTH-003 | Restart policy must include crash-loop backoff. | Document 2; Phase 16 maintainer scope | Implemented for managed-start and managed-restart planning gates | `Sources/HostwrightReconciler/RestartPolicyEvaluator.swift`, `Sources/HostwrightCLI/ApplyCommand.swift`, `Sources/HostwrightState/StateRecords.swift` | Reconciler, CLI, daemon, and state XCTest cases | 16, 17 |
| HW-HEALTH-004 | Health check results must be persisted append-only with redacted stdout, stderr, command, and metadata surfaces. | Phase 16 maintainer scope | Implemented | `Sources/HostwrightState/MigrationRunner.swift`, `Sources/HostwrightState/StateRepositories.swift` | State and daemon XCTest cases | 16 |
| HW-HEALTH-005 | Restart policy state must track max attempts, backoff, operator hold, manual-disable, and crash-loop blocking. | Phase 16 maintainer scope | Implemented for state, planning, manual-disable, preexisting operator hold, managed-start failure gates, and managed-restart failure gates | `Sources/HostwrightState/StateRecords.swift`, `Sources/HostwrightState/StateRepositories.swift`, `Sources/HostwrightReconciler/RestartPolicyEvaluator.swift`, `Sources/HostwrightCLI/ApplyCommand.swift` | State, reconciler, and CLI XCTest cases | 16, 17 |

## Networking

| ID | Requirement | Source document | Current status | Implementation file if any | Test coverage if any | Release phase |
| --- | --- | --- | --- | --- | --- | --- |
| HW-NET-001 | Networking must be declared state, not incidental shell output. | Document 3 | Implemented for manifest/runtime port planning models and versioned observation fixture network metadata | `Sources/HostwrightNetworking/NetworkingModels.swift`, `Sources/HostwrightRuntime/RuntimeModels.swift`, `Sources/HostwrightReconciler/ManifestRuntimeMapper.swift` | Networking, runtime, and reconciler XCTest cases | 7, 22 |
| HW-NET-002 | Port conflicts must fail during planning before mutation. | Document 3 | Implemented for duplicate desired host ports and live observed host-port conflicts | `Sources/HostwrightReconciler/PlanningPolicy.swift` | Reconciler XCTest cases | 7, 22 |
| HW-NET-003 | Project and localhost exposure may be considered first; LAN, tunnel, and public exposure are blocked by default. | Document 3 | Implemented for localhost publish defaults, broad-bind blocking, unsupported discovery fields, and blocked non-target observed port occupancy | `NetworkingModels.swift`, `docs/architecture/networking-boundary.md`, `Sources/HostwrightManifest/ManifestParser.swift`, `Sources/HostwrightReconciler/PlanningPolicy.swift` | Manifest, networking, runtime, and reconciler XCTest cases | 7, 22 |
| HW-NET-004 | DNS, tunnel, and cloud connector behavior require separate research gates. | Document 3 | DNS/service discovery fails closed; tunnel/cloud remain deferred to research gates | Docs and manifest parser | Manifest XCTest and docs review | 22, deferred |

## Safety / Security

| ID | Requirement | Source document | Current status | Implementation file if any | Test coverage if any | Release phase |
| --- | --- | --- | --- | --- | --- | --- |
| HW-SAFE-001 | Every apply operation must support dry-run planning before mutation. | Document 2 | Partially implemented through deterministic plan hashing and explicit `--confirm-plan` for supported apply actions | `Sources/HostwrightCLI/ApplyCommand.swift`, `Sources/HostwrightReconciler/PlanRenderer.swift` | CLI and reconciler XCTest cases | 8, 9 |
| HW-SAFE-002 | Destructive operations require preview, ownership checks, confirmation design, and audit events. | Document 2 | Implemented for exact cleanup-eligible container delete with Phase 19 dry-run classification, and narrow managed restart | `Sources/HostwrightCLI/CleanupCommand.swift`, `Sources/HostwrightCLI/ApplyCommand.swift`, `Sources/HostwrightRuntime/RuntimeCommand.swift` | CLI and runtime XCTest cases | 9, 17, 19 |
| HW-SAFE-003 | Named volumes must not be deleted by default. | Document 2 | Implemented by omission: no volume delete command path exists | `Sources/HostwrightRuntime/AppleContainerCommand.swift`, `Sources/HostwrightRuntime/RuntimeCommand.swift` | Runtime command-policy XCTest cases; code review | 9 |
| HW-SAFE-004 | Secret values must not appear in logs, events, status, reports, fixtures, or docs examples; execution env values must not be mutated into redaction placeholders. | Document 2 | Partially implemented for runtime command output, plan rendering, logs, state payloads, apply errors, execution/display env separation, secret references, fake Keychain backend tests, and fail-closed unavailable live Keychain behavior | `Sources/HostwrightSecrets/SecretStore.swift`, `Sources/HostwrightRuntime/RuntimeRedaction.swift`, `Sources/HostwrightState/StateJSON.swift`, `Sources/HostwrightCLI/ApplyCommand.swift`, `Sources/HostwrightCLI/LogsCommand.swift` | Secrets, runtime, state, CLI, and reconciler XCTest cases with fake secret values | 6, 8, 9, 11, 24 |
| HW-SAFE-007 | Secret references must be local, explicit, noninteractive, and unresolved unless a confirmed mutation uses an approved backend. | Phase 24 maintainer scope | Implemented for `secretEnv`, fake Keychain backend, unavailable default backend, redacted state/diagnostics/plans, and runtime unresolved-reference refusal | `Sources/HostwrightSecrets/SecretStore.swift`, `Sources/HostwrightManifest/ManifestModel.swift`, `Sources/HostwrightCLI/ApplyCommand.swift`, `Sources/HostwrightRuntime/AppleContainerApplyAdapter.swift` | Secrets, manifest, runtime, state, CLI, observability, and reconciler XCTest cases | 24 |
| HW-SAFE-005 | Privileged helpers are rejected unless a future threat model proves necessity. | Document 2 | Rejected for first release | Docs only | Docs review | Rejected |
| HW-SAFE-006 | Public/LAN/tunnel exposure must require explicit policy and review. | Document 3 | Research decision recorded; implementation remains deferred behind policy, secrets, auth, DNS, audit, and revocation gates | `docs/architecture/secure-exposure-research.md`, `docs/architecture/networking-boundary.md` | Core docs XCTest and docs review | 23, deferred |

## Observability

| ID | Requirement | Source document | Current status | Implementation file if any | Test coverage if any | Release phase |
| --- | --- | --- | --- | --- | --- | --- |
| HW-OBS-001 | Hostwright must emit local events for meaningful operations. | Agent Engineering Manual; Final Production Arsenal | Implemented for current apply, cleanup, status, logs, daemon, health, and restart scopes | `Sources/HostwrightState/StateRepositories.swift`, `Sources/HostwrightObservability/ObservabilityModels.swift` scaffold | State and CLI XCTest cases | 6, 9, 15, 16, 17, 18, 19, 20 |
| HW-OBS-002 | Status must distinguish desired state, observed runtime state, health, drift, restarts, and ports. | Agent Engineering Manual | Partially implemented for live RuntimeAdapter status output with parser and local telemetry metadata | `Sources/HostwrightCLI/StatusCommand.swift` | CLI XCTest cases | 9, 20 |
| HW-OBS-003 | Logs and diagnostics must avoid secret leakage. | Document 2 | Implemented for bounded log reads, event rendering, recovery rendering, and local diagnostics export in current scope | `Sources/HostwrightCLI/LogsCommand.swift`, `Sources/HostwrightCLI/EventsCommand.swift`, `Sources/HostwrightCLI/RecoveryCommand.swift`, `Sources/HostwrightCLI/DiagnosticsCommand.swift`, `Sources/HostwrightState/DiagnosticsExport.swift`, `Sources/HostwrightRuntime/RuntimeRedaction.swift` | CLI, state, and runtime XCTest cases | 9, 18, 20 |
| HW-OBS-004 | OSLog is the planned local logging direction. | Final Production Arsenal | Deferred; Phase 20 uses local SQLite-backed diagnostics export instead | None | None | Deferred |
| HW-OBS-005 | Diagnostic exports must be local-only, redacted, and explicit-path based. | Phase 20 maintainer scope | Implemented | `Sources/HostwrightCLI/DiagnosticsCommand.swift`, `Sources/HostwrightState/DiagnosticsExport.swift` | CLI and state XCTest cases | 20 |
| HW-OBS-006 | Event browsing must support bounded filtering and deterministic sorting. | Phase 20 maintainer scope | Implemented | `Sources/HostwrightCLI/EventsCommand.swift`, `Sources/HostwrightCLI/CLICommand.swift` | CLI XCTest cases | 20 |

## Compatibility

| ID | Requirement | Source document | Current status | Implementation file if any | Test coverage if any | Release phase |
| --- | --- | --- | --- | --- | --- | --- |
| HW-COMPAT-001 | First supported release targets Apple silicon. | Agent Engineering Manual; Document 2 | Implemented as compatibility gate | `HostwrightIdentity.swift`, `DoctorModels.swift` | Core and CLI smoke tests | 1 |
| HW-COMPAT-002 | First supported release targets macOS 26+. | Agent Engineering Manual; Final Production Arsenal | Implemented as compatibility gate | `Package.swift`, `HostwrightIdentity.swift` | Core and CLI smoke tests | 1 |
| HW-COMPAT-003 | Intel Macs and older macOS releases are out of first-release scope. | Agent Engineering Manual | Implemented in docs/gate | `docs/reference/compatibility.md` | Docs review | 1 |
| HW-COMPAT-004 | GPU/ANE/Metal/Core ML/MLX support inside containers must not be claimed without proof. | Document 2 | Rejected for first release | Docs only | Docs review | Rejected |
| HW-COMPAT-005 | CRI, Kubernetes, Docker API, and full Compose parity must not be claimed. | Agent Engineering Manual; Final Production Arsenal | Rejected for first release | Docs and ADRs | Docs review | Rejected |
| HW-COMPAT-006 | Apple silicon resource intelligence must report measurement method, host facts, workload profile, unmeasured dimensions, and limits without implying scheduler or accelerator support. | Phase 26 maintainer scope; Document 2 | Implemented for local ProcessInfo-backed doctor reports and fixture-backed parser coverage | `Sources/HostwrightHealth/ResourceIntelligenceModels.swift`, `Sources/HostwrightHealth/DoctorModels.swift`, `docs/architecture/resource-intelligence.md` | Health and CLI XCTest cases; docs review | 26 |

## Docs / Site

| ID | Requirement | Source document | Current status | Implementation file if any | Test coverage if any | Release phase |
| --- | --- | --- | --- | --- | --- | --- |
| HW-DOCS-001 | Every supported command must have reference docs. | Agent Engineering Manual | Partially implemented | `docs/reference/cli.md` | Docs review | 2 |
| HW-DOCS-002 | Unsupported behavior must be explicit and searchable. | Agent Engineering Manual | Partially implemented | `docs/reference/limitations.md`, site limitations page | `scripts/grep-orchard.sh .`; docs review | 3 |
| HW-DOCS-003 | Public website copy must not claim unimplemented behavior as current support. | Agent Engineering Manual; Final Production Arsenal | Planned for separate website repository | Not committed in core repo; website belongs in `hostwright.dev` | Website repo review | 3 |
| HW-DOCS-004 | Source material must remain preserved and traceable. | Final Production Arsenal; Naming Convention Folder | Implemented | `docs/source-material/README.md` | Preservation log review | 0 |

## Release

| ID | Requirement | Source document | Current status | Implementation file if any | Test coverage if any | Release phase |
| --- | --- | --- | --- | --- | --- | --- |
| HW-REL-001 | Public releases must use real `v*` release tags and keep `phase-*` tags as internal engineering checkpoints. | Final Production Arsenal | Implemented for `v0.1.0-alpha.1` planning | `docs/release/RELEASE_PROCESS.md` | Core release-doc XCTest case | 10 |
| HW-REL-002 | Public release requires build, tests, docs, examples, compatibility matrix, and limitations review. | Agent Engineering Manual | Implemented for `v0.1.0-alpha.1` release candidate prep | `README.md`, `docs/reference/`, `docs/release/` | Core and manifest XCTest cases; release checklist | 10 |
| HW-REL-003 | Signing, notarization, SBOM, checksums, and provenance are considered before public artifacts. | Final Production Arsenal; Document 2 | Implemented as source-only alpha decision with no binary artifacts | `docs/release/RELEASE_PROCESS.md`, `docs/reference/install.md`, `docs/reference/security-safety.md` | Core release-doc XCTest case | 10 |
| HW-REL-004 | Benchmarks begin before claims about Apple silicon performance. | Document 2; Final Production Arsenal | Implemented by release policy: no performance claims are made in `v0.1.0-alpha.1` | `docs/release/v0.1.0-alpha.1-notes.md`, `docs/reference/limitations.md` | Docs review | 10 |
