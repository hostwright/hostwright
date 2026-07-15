# Acceptance Matrix

> **Historical acceptance catalog:** these gates preserve earlier evidence. The active closure constitution and phase ownership are in the [v0.0.2 implementation plan](../roadmap/v0.0.2/IMPLEMENTATION_PLAN.md), evidence schema, and GitHub issue manifest. A former docs/research gate does not satisfy a v0.0.2 implementation issue.

This matrix defines verification gates for the near-term requirements that control future implementation. It also records future gates that must exist before runtime mutation or public release.

Verification types:

- Automated: checked by local command or test.
- Manual: requires maintainer or reviewer inspection.
- Blocked: cannot be verified until a prerequisite exists.
- Future: intentionally belongs to a later phase.

## Phase 3 Gate

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-NAME-001, HW-NAME-005 | Public-facing repo files use Hostwright; old-name references are only historical or naming-context references. | Automated + manual | `scripts/grep-orchard.sh .`; review remaining matches. |
| HW-DOCS-002, HW-DOCS-003 | Core limitations docs do not claim current support for runtime mutation, `apply`, SQLite, cleanup, production readiness, CRI, Kubernetes, Compose parity, Docker API, tunnels, cloud, GPU/ANE, or privileged helpers. | Manual | Review `docs/reference/limitations.md`; website copy is reviewed separately in the `hostwright.dev` repository. |
| HW-REL-002 | Build and test gate remains documented and runnable. | Automated | `swift build`, `swift test`, `scripts/test.sh`. |
| HW-RUNTIME-002 | No Phase 3 change adds Apple container calls or RuntimeAdapter process execution. | Manual | Review changed files; no Swift runtime files should change in Phase 3. |
| HW-STATE-001 | No Phase 3 change implements SQLite or creates database files. | Manual | Review changed files; no state code or schema execution. |
| HW-CLI-008 | No Phase 3 change implements `apply`. | Manual | Review `Sources/HostwrightCLI/` remains unchanged. |

## Phase 4 Gate: RuntimeAdapter Contract

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-RUNTIME-001, HW-RUNTIME-002 | CLI and reconciler still cannot call Apple container directly for runtime behavior. | Automated + manual | Runtime/reconciler smoke tests; code review. |
| HW-RUNTIME-003 | Runtime types cover desired state, observed state, planned actions, runtime events, capabilities, metadata, and typed errors. | Automated | XCTest cases for type construction, mock observation, and error mapping. |
| HW-RUNTIME-004 | Process-execution design includes timeout, output capture, cancellation result fields, command classification, and redaction before read-only runtime use. | Automated + manual | Fake process-runner tests; architecture review. |
| HW-RUNTIME-006 | Mutation hooks exist only as unavailable contracts in Phase 4. | Automated | Runtime smoke tests assert mutation unavailable. |
| HW-MANIFEST-004 | Decision on restricted parser vs approved YAML dependency is recorded before manifest expansion. | Manual | ADR or requirements update. |

## Phase 5 Gate: Read-Only Apple Observation

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-RUNTIME-005 | Adapter can report Apple container availability and safe read-only observations without mutation. | Automated + manual | Adapter tests with fixture output; manual command review before local runtime test. |
| HW-CLI-007 | `doctor` reports runtime availability clearly and does not crash when `container` is missing. | Automated | CLI tests with missing and present executable fixtures. |
| HW-COMPAT-001, HW-COMPAT-002 | Compatibility diagnostics remain explicit for architecture and macOS version. | Automated | Core and doctor tests. |
| HW-RUNTIME-001, HW-RUNTIME-002 | Apple container command strings and live process execution remain isolated in `HostwrightRuntime`. | Automated + manual | Runtime boundary smoke checks; code review of CLI, health, and reconciler modules. |
| HW-RUNTIME-004, HW-RUNTIME-006 | Mutating, forbidden, unknown, and unresolved command specs fail before execution. | Automated | Runtime smoke tests for command policy. |
| HW-RUNTIME-005, HW-SAFE-004 | Empty, running, malformed, and redaction fixtures are parsed or rejected honestly. | Automated | Runtime smoke tests with `Tests/HostwrightRuntimeTests/Fixtures/`. |

## Phase 6 Gate: SQLite State And Events

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-STATE-001, HW-STATE-002 | SQLite schema and migrations are explicit and isolated in `HostwrightState`. | Automated | XCTest cases run against explicit temporary databases. |
| HW-STATE-003, HW-OBS-001 | Events and operation records persist and reload from SQLite. | Automated | XCTest cases append, reload, and verify event/operation records. |
| HW-STATE-004, HW-SAFE-004 | Known fake secret values do not appear in persisted env, event, operation, ownership, or observed-summary fields. | Automated | XCTest cases assert redacted payloads. |
| HW-STATE-005 | Ownership ledger stores resource ownership and cleanup eligibility without cleanup behavior. | Automated | XCTest cases persist and reload ownership records with `cleanupEligible` false. |
| HW-RECON-003 | Drift planning does not start in Phase 6. | Manual | Review changed files: no Phase 7 drift planner or apply path. |

## Phase 7 Gate: Real Planning And Drift

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-RECON-001, HW-RECON-002, HW-RECON-003 | Planner produces deterministic non-mutating plans from desired and observed state. | Automated | Reconciler XCTest cases for missing, stopped, failed, unmanaged, unhealthy, image drift, port drift, mount drift, duplicate observed identity, unsupported observed state, observation unavailable, deterministic hash, and stable ordering. |
| HW-NET-001, HW-NET-002, HW-NET-003 | Port and exposure validation happen during planning, before mutation. | Automated | Reconciler XCTest cases for duplicate desired host ports, unsafe broad bind address, and privileged host port warning. |
| HW-VALID-004, HW-VALID-005, HW-VALID-006 | Unsafe volumes, secret-like env paths, and unsupported features fail closed before mutation. | Automated | Reconciler and CLI XCTest cases for unsafe mount sources, secret-like env redaction, and restricted manifest parser failures. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-RUNTIME-006 | Phase 7 does not add runtime mutation, direct Apple container calls, cleanup, or `apply`. | Automated + manual | Runtime mutation-unavailable XCTest cases; targeted `rg` scans of CLI/reconciler/state modules; code review. |

## Phase 8 Gate: First Runtime Mutation

Phase 8A is a required preflight before this mutation gate. It proves real read-only Apple container observation before `apply` implementation begins.

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-RUNTIME-005, HW-SAFE-004 | Parser supports the verified real empty Apple container JSON list output `[]` and fails closed for unsupported real JSON shapes. | Automated + manual | Runtime XCTest fixture tests; manual `container list --all --format json` preflight. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-RUNTIME-006 | Phase 8A does not add `apply`, mutation command descriptors, cleanup, or Apple container calls outside `HostwrightRuntime`. | Automated + manual | Runtime mutation-unavailable XCTest cases; targeted `rg` scans of CLI/reconciler/state modules; code review. |
| HW-REL-002 | Build and test gates still pass after real empty JSON fixture support. | Automated | `swift build`, `swift test list`, `swift test`, `scripts/test.sh`. |

## Phase 8B Gate: First Runtime Mutation

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-CLI-008, HW-RECON-004, HW-RUNTIME-006 | `apply` uses the secure selected state database (`--state-db`/environment override or the documented default), requires explicit `--confirm-plan`, recomputes the observed plan, persists intent before mutation, and executes only one `createMissingService` action through `RuntimeAdapter`. | Automated + manual | CLI XCTest cases; RuntimeAdapter boundary scans; code review. |
| HW-RUNTIME-004, HW-RUNTIME-006 | Runtime process execution accepts read-only commands and the single Phase 8B create-missing-service command kind; unknown, forbidden, unresolved, and unsupported mutating specs fail before execution. | Automated | Real process-runner XCTest cases plus scripted test-only failure injection. |
| HW-VALID-004, HW-VALID-005, HW-NET-003, HW-SAFE-004 | Create rejects volumes/mounts, privileged host ports, broad bind addresses, flag-like image values, and service command tokens beginning with `-`; sensitive env values are kept for execution and redacted from state, events, plan output, and errors. | Automated | CLI and runtime XCTest cases. |
| HW-RECON-005, HW-STATE-003, HW-OBS-001 | Partial apply failure leaves recoverable operation records and redacted failure events. | Automated | CLI and state failure-injection XCTest cases. |
| HW-SAFE-001 | `plan` remains non-mutating and reviewable before `apply`; `apply` only proceeds when the provided plan hash matches the recomputed plan. | Automated | CLI and planner XCTest cases. |
| HW-RUNTIME-005, HW-RUNTIME-006 | Live create is proven only for the approved disposable proof image and the single create-missing-service action. Stale repeat apply must fail before mutation after observed state changes. | Automated + manual | Built `hostwright-proof-web:phase8b`, ran `hostwright apply` with matching plan hash, verified `hostwright-proof-web` in Apple container output, reran with stale hash and observed refusal before duplicate create, then deleted only the exact proof container and proof image. |

## Phase 9 Gate: Operability And Cleanup

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-CLI-009, HW-OBS-002, HW-OBS-003 | `status`, `logs`, and `events` render useful facts, use the secure selected state database when reading or persisting, and redact fake secrets. | Automated | CLI XCTest cases for status observation, logs redaction, and event rendering. |
| HW-RECON-004, HW-RUNTIME-006 | `apply` executes exactly one restart-policy-allowed managed start and no other non-create action. | Automated + manual | Reconciler and CLI XCTest cases; runtime boundary scans. |
| HW-SAFE-002, HW-SAFE-003, HW-STATE-005 | Cleanup requires ownership records, live observation, non-running lifecycle, dry-run token, and exact confirmation before delete. | Automated + manual | CLI cleanup XCTest case; review that no image/volume deletion exists. |
| HW-RUNTIME-004, HW-RUNTIME-006 | Command policy rejects attach, interactive, all, force, stop, restart, remove, prune, pull, push, build, exec, run, unresolved, unknown, and forbidden specs. | Automated | Runtime XCTest cases for managed start/delete policies and fake/live runner validation. |
| HW-REL-002 | Build and XCTest gates still pass after operability changes. | Automated | `swift build`, `swift test list`, `swift test`, `scripts/test.sh`. |

## Phase 10 Gate: First Supported Release

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-REL-001, HW-REL-002 | Release checklist passes with build, tests, docs, examples, compatibility, limitations, and release notes reviewed for `v0.1.0-alpha.1`. | Automated + manual | `swift build`, `swift test list`, `swift test`, `scripts/grep-orchard.sh .`, `scripts/test.sh`, release-doc XCTest cases, reviewer signoff. |
| HW-REL-003 | Source-only artifact decision is documented; no binaries, installers, Homebrew formula, signing, notarization, SBOM, or provenance claim is made. | Automated + manual | Release-doc XCTest cases and release hardening review. |
| HW-REL-004 | No Apple silicon performance claim is made without benchmark data. | Manual | Release notes and limitations review. |

## Phase 12 Gate: CLI And Developer Workflow Hardening

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-CLI-001, HW-CLI-009 | CLI commands keep default human output while adding documented `--output text|json` where supported. | Automated | CLI XCTest cases for parsing, text defaults, and JSON success shapes. |
| HW-CLI-001, HW-DOCS-001 | Every supported command has documented synopsis, arguments, exit-code behavior, output modes, and failure examples. | Automated + manual | CLI reference review; help-output XCTest checks. |
| HW-SAFE-004, HW-OBS-003 | JSON output and JSON errors redact fake secrets and runtime/state-derived sensitive strings. | Automated | CLI XCTest cases for plan, events, status, doctor, and JSON error redaction. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001 | CLI hardening does not add runtime mutation, hidden state paths, direct Apple container shell-out, or SQLite access outside `HostwrightState`. | Automated + manual | Full local gate plus targeted boundary scans. |

## Phase 13 Gate: Manifest Schema Maturity

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-MANIFEST-002, HW-MANIFEST-003, HW-MANIFEST-004 | Parser, validator, schema, starter manifest, and examples agree on the supported restricted manifest subset. | Automated + manual | Manifest XCTest schema/example alignment; manifest reference review. |
| HW-MANIFEST-003, HW-VALID-006 | Unsupported top-level, service, health, restart, Kubernetes-style, and Compose-style fields fail closed with stable manifest errors. | Automated | Manifest XCTest unsupported-field fixtures. |
| HW-MANIFEST-002, HW-VALID-006 | Manifest version policy accepts `version: 1`, treats omitted version as legacy v1 input, and rejects explicit older/newer versions without upgrade or downgrade conversion. | Automated + manual | Manifest XCTest version fixtures; manifest reference review. |
| HW-VALID-004, HW-VALID-005, HW-SAFE-004 | Untrusted manifest handling rejects unsafe host-root or parent-traversal mount sources and unsafe environment keys before planning or mutation. | Automated + manual | Manifest XCTest unsafe fixtures; security-safety docs review. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001 | Schema maturity does not add runtime mutation, hidden state paths, direct Apple container shell-out, YAML dependency, or Compose parity. | Automated + manual | Full local gate plus targeted boundary scans and dependency review. |

## Phase 14 Gate: State Migrations And Upgrade Safety

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-STATE-001, HW-STATE-002, HW-STATE-006 | Fresh and repeated explicit migrations record schema version and checksums, and rerunning migrations preserves existing rows. | Automated | State XCTest migration idempotency and row-count tests. |
| HW-STATE-002 | Transaction failures roll back partial state writes. | Automated | State XCTest transaction rollback test. |
| HW-STATE-002, HW-STATE-006 | Future-version, checksum-mismatched, and non-contiguous migration histories fail closed before state reads, schema-version queries, writes, or migration. | Automated | State XCTest future-schema, checksum-mismatch, and migration-gap integration tests. |
| HW-STATE-001, HW-STATE-006 | Corrupt and locked databases produce actionable state errors rather than generic SQLite failures or hangs. | Automated | State XCTest corrupt-file and lock-contention tests. |
| HW-STATE-002, HW-STATE-003 | Real connections preserve transaction isolation, expose committed rows across connections and reopen, and allow exactly one concurrent operation-group acquisition per idempotency key. | Automated | State multi-connection and 20-round concurrent-acquisition integration tests. |
| HW-STATE-001, HW-STATE-002 | Repository reads validate already-applied schema without creating databases or applying migrations as a side effect. | Automated + manual | State XCTest read-side-effect tests; review that repository reads use validated read-only connections. |
| HW-STATE-007, HW-STATE-008, HW-STATE-009, HW-SAFE-002, HW-SAFE-004 | Online backup captures one consistent live SQLite snapshot, publishes only a private fully verified catalog entry, reports tamper/incomplete evidence, and leaves no owned partial artifact on cancellation or real SQLite-full failure. | Automated + built binary | State maintenance unit/integration suites and `scripts/integration.sh`. |
| HW-STATE-008, HW-STATE-011 | Integrity separates healthy, reconstructible projection damage, and authoritative/schema/SQLite damage; repair deletes only declared projection rows, preserves authoritative/audit state, and can execute its verified rollback snapshot if committed state becomes unrecoverable. | Automated | State integrity/repair tests for required indexes, UUIDs, JSON/enums, row counts, authoritative refusal, post-repair verification, and failed-repair rollback. |
| HW-STATE-010, HW-STATE-012 | Restore tokens bind exact state and backup identity; the staged copy remains digest/size-bound; publication is atomic; unreadable originals are quarantined; each durable checkpoint and torn window recovers by exact finalization or rollback without blank-state creation. | Automated + built binary | Restore round-trip/stale-token/backup-race/corrupt-source/five-checkpoint/four-torn-window/ordinary-failure/tampered-journal tests and CLI integration. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001, HW-STATE-012 | State maintenance never invokes RuntimeAdapter, never mutates Apple container, refuses sidecar-ambiguous filesystem replacement, and does not introduce undocumented state paths or destructive reset commands. | Automated + manual | Full local gate, targeted runtime-boundary scans, live runtime inventory comparison, and diff review. |

## Phase 15 Gate: Local Daemon Reconciliation Loop

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-DAEMON-001, HW-DAEMON-002 | `hostwrightd` requires `--foreground` and `--config <path>` before running; `--state-db <path>` is an optional override of the secure default. | Automated | Daemon command parser XCTest cases. |
| HW-DAEMON-003 | The loop supports manual-clock cadence, deterministic jitter, repeated-error backoff, shutdown, real single-instance lock refusal, and sleep/wake resume events. | Automated | Daemon core XCTest cases. |
| HW-DAEMON-004, HW-RUNTIME-001, HW-RUNTIME-002 | Foreground daemon reconciliation observes through `RuntimeAdapter`, computes a plan, records state/events/operations, and never calls `RuntimeAdapter.execute`. | Automated + manual | Daemon XCTest no-execute assertion; targeted runtime-boundary scans. |
| HW-STATE-001, HW-STATE-003, HW-OBS-001 | Successful daemon attempts persist desired state, observed snapshots, event records, and operation records to the secure selected state database; failed attempts persist failed operation and event records with redacted diagnostic codes. | Automated | Daemon foreground loop persistence and failure-classification XCTest cases. |
| HW-DOCS-002, HW-SAFE-001 | Docs distinguish foreground non-mutating daemon behavior from unsupported launch agent, background service, restart loop, and unattended mutation behavior. | Manual | Daemon architecture, limitations, CLI reference, security-safety, and README review. |

## Phase 16 Gate: Health Checks And Restart Policy Expansion

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-HEALTH-002, HW-SAFE-004 | Health checks execute only as in-process loopback probes or direct true/false probes after allowlisted command-shape validation, map failures/timeouts to health results, and redact stdout/stderr/commands. | Automated | Runtime bounded health checker XCTest cases. |
| HW-HEALTH-004, HW-STATE-001, HW-STATE-003 | Health check results are persisted append-only with redacted command, stdout, stderr, and metadata surfaces. | Automated | State and daemon health-result XCTest cases. |
| HW-HEALTH-003, HW-HEALTH-005, HW-RECON-004 | Restart decisions include restart policy state, max attempts, backoff, preexisting operator hold, manual-disable, and crash-loop blocking before exposing a managed start action. | Automated | Reconciler restart-state XCTest cases and CLI restart-state XCTest cases. |
| HW-DAEMON-004, HW-DAEMON-005 | Foreground daemon records health results and restart policy state but never calls `RuntimeAdapter.execute` or performs unattended restart mutation. | Automated + manual | Daemon XCTest no-execute assertions and targeted runtime-boundary scans. |
| HW-DOCS-002, HW-SAFE-004 | Docs describe in-process loopback health checks, redacted health events, restart-state blocking, and the absence of aggressive restart loops or production readiness. | Manual | Manifest, daemon, limitations, security-safety, requirements, and build-status docs review. |

## Phase 17 Gate: Managed Restart

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-RECON-004, HW-HEALTH-003, HW-HEALTH-005 | Reconciliation exposes `restartManagedService` only for unhealthy running services when restart policy state allows one managed recovery attempt. | Automated | Reconciler XCTest cases for allowed and crash-loop-blocked managed restart. |
| HW-SAFE-002, HW-RUNTIME-006, HW-STATE-005 | `apply` requires exact Hostwright ownership, live observed running state, fresh persisted unhealthy health, explicit plan hash, and operation intent before managed restart mutation. | Automated + manual | CLI XCTest cases for ownership refusal, fresh/stale persisted health handling, status/apply plan-hash parity, and successful managed restart; code review. |
| HW-RUNTIME-001, HW-RUNTIME-004, HW-RUNTIME-006 | Runtime executes managed restart only as an internal `stop <hostwright-id>` then `start <hostwright-id>` sequence through `RuntimeAdapter`; no public stop/restart command is added. | Automated + manual | Runtime command-policy XCTest cases, scripted-runner sequencing test, and targeted runtime-boundary scans. |
| HW-RECON-005, HW-STATE-003, HW-OBS-001 | Managed restart writes append-only operation records, restart recovery records, restart policy state, and redacted events for success, failure, and stop-success/start-failure reporting. | Automated | CLI, runtime, and state XCTest cases for success, failure hints, backoff, partial failure records, and redaction. |
| HW-DOCS-002, HW-SAFE-001 | Docs describe managed restart without claiming broad lifecycle management, daemon restart loops, unmanaged cleanup, or image/volume cleanup. | Manual | Runtime adapter, CLI, limitations, security-safety, state-store, and README review. |

## Phase 18 Gate: Rollback And Partial Failure Recovery

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-RECON-004, HW-RECON-005, HW-STATE-003 | Apply acquires an operation group before runtime mutation, records checkpoints and forward steps, and releases the group as succeeded, failed, or interrupted. | Automated | CLI XCTest cases for apply success, runtime failure, managed restart stop-success/start-failure, and success-persistence interruption. |
| HW-RECON-005, HW-SAFE-004 | Recovery records include redacted manual recovery hints, completed/failed/unsupported steps, and no raw fake secrets. | Automated | State and CLI XCTest redaction assertions for operation groups, steps, and recovery JSON. |
| HW-SAFE-001, HW-SAFE-002 | Recovery output distinguishes automatic, manual, and unsupported recovery without retrying or rolling back runtime changes. | Automated + manual | `hostwright recovery` XCTest JSON shape; CLI reference and limitations review. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001 | Phase 18 does not add direct Apple container shell-out, SQLite access outside `HostwrightState`, undocumented or unsafe default state paths, or new lifecycle commands. | Automated + manual | Full local gate plus targeted boundary scans and diff review. |

## Phase 19 Gate: Cleanup Classification Maturity

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-SAFE-002, HW-SAFE-003, HW-STATE-005 | Cleanup dry-run classifies eligible, ambiguous, stale, running, unknown, blocked, and never-delete ownership-backed and observed-only resources. | Automated | CLI XCTest mixed cleanup classification and adapter-mismatch cases. |
| HW-SAFE-002, HW-RUNTIME-006 | Confirmed cleanup deletes only exact eligible Hostwright-owned created/stopped/exited containers covered by the current token. | Automated + manual | CLI XCTest eligible-only execution assertions and runtime boundary scans. |
| HW-STATE-003, HW-OBS-001 | Cleanup reports runtime partial failure and delete-success/state-persistence failure without hiding completed deletions. | Automated | CLI XCTest cases for partial runtime failure and state persistence failure after delete success. |
| HW-DOCS-002, HW-SAFE-001 | Docs describe cleanup classification without claiming broad garbage collection, image cleanup, volume cleanup, unmanaged deletion, or automatic cleanup. | Manual | CLI, limitations, security-safety, requirements, and implementation-plan docs review. |

## Phase 20 Gate: Observability And Diagnostics

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-OBS-005, HW-SAFE-004, HW-STATE-001 | `hostwright diagnostics` writes a redacted local JSON bundle from an explicit existing state database path, refuses overwrite, does not create or migrate missing state, and does not observe or mutate runtime state. | Automated + manual | CLI and state XCTest diagnostics export cases; runtime-boundary scans; CLI and state-store docs review. |
| HW-OBS-006, HW-OBS-001 | `hostwright events` supports project, type, service, severity, limit, and ascending/descending sort filters while preserving deterministic read-only event rendering. | Automated | CLI XCTest event filtering/sorting/limit cases. |
| HW-OBS-002, HW-CLI-007 | `hostwright status` and `hostwright doctor` report parser/state-path/telemetry policy metadata without claiming service reachability or external telemetry. | Automated + manual | CLI and health XCTest cases; doctor, status, limitations, and security docs review. |
| HW-DOCS-002, HW-SAFE-004 | Docs describe local-only diagnostics and forensic records without claiming hosted diagnostics, upload, OSLog integration, production monitoring, or support-bundle workflows. | Manual | CLI, limitations, security-safety, state-store, daemon, requirements, and implementation-plan docs review. |

## Phase 21 Gate: GUI Control Surface Requirements And API Boundary

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-GUI-001, HW-GUI-002 | Control-surface docs define approved local data surfaces for projects, services, plans, apply confirmation, status, logs, events, recovery, cleanup previews, diagnostics, doctor reports, and errors. | Automated + manual | Core docs guard plus review of `docs/architecture/control-surface-api-boundary.md`. |
| HW-GUI-001, HW-SAFE-001, HW-SAFE-002, HW-SAFE-004 | Control surfaces cannot bypass manifest validation, local policy, redaction, plan-hash confirmation, cleanup tokens, ownership records, secure selected state paths, or RuntimeAdapter gates. | Automated + manual | Core docs guard plus security/safety review. |
| HW-GUI-003 | Accessibility requirements cover keyboard navigation, focus, screen-reader status/error states, non-color-only severity, selectable confirmation hashes/tokens, and diagnostics-sharing warnings. | Automated + manual | Core docs guard plus control-surface requirements review. |
| HW-GUI-004, HW-DOCS-002 | Phase 21 does not add GUI code, website implementation, web dashboard, cloud dashboard, daemon API, direct Apple container execution, direct SQLite access, RuntimeAdapter bypass, telemetry upload, hosted diagnostics, release tags, or GitHub Releases. | Automated + manual | Full local gate, targeted boundary scans, and diff review. |

## Phase 22 Gate: Networking And Service Discovery

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-NET-001, HW-NET-003 | Hostwright-created publishes remain explicit localhost bindings, manifest bind addresses remain unsupported, and broad bind addresses are blocked when represented in runtime desired state. | Automated + manual | Networking, runtime, and reconciler XCTest cases; networking-boundary and security docs review. |
| HW-NET-002 | Duplicate desired host ports and live observed non-target host-port conflicts produce blocker plan issues before mutation. | Automated | Reconciler XCTest cases for duplicate desired ports and observed host-port conflict. |
| HW-NET-004, HW-VALID-006 | DNS, service discovery, network aliases, network modes, `expose`, tunnel, and cloud exposure settings fail closed or remain documented research-only. | Automated + manual | Manifest XCTest unsupported networking fields; limitations, manifest, and networking-boundary docs review. |
| HW-RUNTIME-005, HW-SAFE-001 | Reviewed Apple container 1.0.0 fields and versioned fixtures preserve exact network metadata without weakening ownership filtering; unrecognized shapes still fail closed. Localhost HTTP reachability is a separate live data-plane gate and a missing macOS Local Network permission is reported as blocked, never passed. | Automated + live | Runtime XCTest parser/ownership cases plus the disposable exact-cleanup runtime proof; blocked reachability evidence records the capability failure separately. |

## Phase 23 Gate: Secure Exposure Research

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-NET-004, HW-SAFE-006 | Cloudflare Tunnel, Tailscale Serve/Funnel, WireGuard, mTLS, reverse proxy, DNS, and cloud-control-plane paths have explicit reject, defer, plugin, or later-prototype decisions before implementation. | Automated + manual | Core docs XCTest and secure exposure decision-record review. |
| HW-DOCS-002, HW-DOCS-003 | Public docs still state that Hostwright does not currently support tunnels, cloud exposure, DNS management, reverse proxy setup, provider integration, or a cloud control plane. | Automated + manual | Core docs XCTest; limitations, networking-boundary, and security docs review. |
| HW-SAFE-004, HW-STATE-001 | Research does not add credentials, provider dependencies, product network calls, hidden state paths, or runtime mutation. | Manual | Diff review plus full local gate. |

## Phase 24 Gate: Secrets Credentials And Keychain Boundary

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-VALID-005, HW-SAFE-004, HW-SAFE-007 | Manifests accept `secretEnv` keychain references, reject plaintext credential-like `env` values, reject malformed references, and keep Compose/Kubernetes `secrets:` unsupported. | Automated | Manifest and schema XCTest cases. |
| HW-SAFE-004, HW-STATE-004, HW-OBS-003 | Plans, state rows, events, diagnostics, errors, and observability redaction do not expose synthetic secret values or raw keychain reference labels. | Automated | Secrets, CLI, state, runtime, reconciler, and observability XCTest cases. |
| HW-SAFE-007 | The opt-in macOS Keychain backend reads one exact non-synchronizable generic-password item without authentication UI; unique live items are exactly deleted and confirmed absent, while malformed data and missing items fail without label disclosure. | Local integration | Secrets XCTest live Keychain add/read/delete/post-delete and malformed-data cases; no conditional skip. |
| HW-SAFE-007, HW-RUNTIME-001 | Apply resolves secret references only through an injected backend immediately before `RuntimeAdapter.execute`; the default unavailable backend and unresolved runtime references fail before mutation. | Automated + manual | CLI in-memory/unavailable backend tests; runtime unresolved-reference guard; diff review. |

## Phase 25 Gate: Supply Chain And Image Trust

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-MANIFEST-005, HW-VALID-002 | Manifest `imagePolicy: require-digest` rejects mutable tag-only images and accepts `@sha256:<64 lowercase hex characters>` references before planning or mutation. | Automated | Manifest XCTest cases and schema/example alignment tests. |
| HW-REL-003, HW-DOCS-002 | Docs distinguish implemented local digest-reference validation from deferred signature verification, SBOM generation/validation, vulnerability scanning, registry resolution, and provenance. | Automated + manual | Core docs XCTest and supply-chain decision-record review. |
| HW-RUNTIME-001, HW-SAFE-001 | Image trust work does not add registry calls, image pulls, runtime image mutation, scanner/signing dependencies, hidden state paths, or unsupported public claims. | Manual | Diff review plus full local gate and targeted boundary scans. |

## Phase 26 Gate: Apple Silicon Resource Intelligence

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-COMPAT-006, HW-CLI-007 | Resource reports state measurement method, hardware, OS version, Apple container version evidence, workload profile, unmeasured benchmark dimensions, and limits. | Automated | Health XCTest report construction, fixture parser, and CLI doctor JSON tests. |
| HW-COMPAT-006, HW-MANIFEST-005 | Non-arm64 image architecture warnings are emitted only when explicit image architecture evidence exists and do not block workloads by themselves. | Automated | Health XCTest architecture-warning cases for arm64, amd64, x86_64, linux/amd64, nil evidence, and non-arm64 hosts. |
| HW-COMPAT-004, HW-REL-004, HW-DOCS-002 | Docs describe benchmark methodology and blocked evidence without claiming production capacity, accelerator scheduling, GPU/ANE/Metal/Core ML/MLX support, telemetry upload, or automatic placement. | Automated + manual | Core docs XCTest and review of resource-intelligence, compatibility, limitations, and Apple silicon constraints docs. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001 | Resource intelligence does not add direct Apple container shell-out, runtime mutation, image pull, hidden state writes, or SQLite access outside `HostwrightState`. | Automated + manual | Full local gate plus targeted boundary scans and diff review. |

## Phase 27 Gate: Apple Silicon Accelerator Boundary Research

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-COMPAT-004, HW-COMPAT-007 | Apple container accelerator passthrough, PyTorch MPS, MLX, Core ML, ANE, host-native accelerator helpers, read-only accelerator detection, and scheduler accelerator dimensions have explicit reject or defer decisions before implementation. | Automated + manual | Core docs XCTest and accelerator boundary decision-record review. |
| HW-COMPAT-006, HW-REL-004, HW-DOCS-002 | Public docs still state that Hostwright does not currently implement GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator helpers, host accelerator device exposure, or accelerator-aware scheduling. | Automated + manual | Core docs XCTest; limitations, security-safety, resource-intelligence, and Apple silicon constraints review. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001 | Research does not add runtime mutation, Apple container command execution from doctor, image pulls, dependencies, hidden state paths, host-native services, or accelerator probes. | Manual | Diff review plus full local gate and targeted boundary scans. |

## Phase 28 Gate: Stack-File Import And Migration Tooling

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-CLI-010, HW-COMPAT-008 | `hostwright import-stack` converts only the reviewed safe subset into deterministic `hostwright.yaml` text and does not write files, observe runtime, touch state, contact registries, or mutate resources. | Automated + manual | CLI import text/JSON tests, import golden-output tests, and diff review. |
| HW-COMPAT-005, HW-COMPAT-008, HW-SAFE-008 | Unsupported networking, discovery, build, deploy, secret, config, named-volume, shell-healthcheck, lifecycle, cloud, and tunnel semantics fail closed with stable diagnostics and policy reason codes where applicable. | Automated | Import unsupported-field XCTest cases and CLI JSON error tests. |
| HW-VALID-001, HW-VALID-002, HW-VALID-003, HW-VALID-004, HW-VALID-005 | Converted output still passes through normal Hostwright manifest validation before success is reported. | Automated | Import validation-gate XCTest cases and `ManifestValidator.validated` golden-output assertion. |
| HW-DOCS-002, HW-COMPAT-005 | Docs describe import as conversion-only and do not claim Docker Compose parity, runtime compatibility, scheduler compatibility, DNS/tunnel/cloud behavior, or current external orchestrator support. | Automated + manual | Core docs XCTest plus CLI, manifest, limitations, policy, import guide, requirements, and acceptance docs review. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001 | Import work does not add RuntimeAdapter calls, direct Apple container shell-out, SQLite access outside `HostwrightState`, undocumented or unsafe default state paths, image pulls, registry calls, runtime mutation, or release artifacts. | Automated + manual | Full local gate plus targeted boundary scans and diff review. |

## Phase 29 Gate: External Orchestration Compatibility Research

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-COMPAT-005 | CRI, Kubernetes node behavior, Docker API, Testcontainers target behavior, full Compose parity, attach, exec, log following, port forwarding, lifecycle, networking, identity, state, and scheduler compatibility have explicit reject, defer, prototype, or split-project decisions before implementation. | Automated + manual | Core docs XCTest and external orchestration compatibility decision-record review. |
| HW-DOCS-002 | Core repository docs still state that Hostwright does not currently implement CRI shims, Kubernetes node behavior, Docker API shims, Testcontainers target behavior, full Compose parity, attach, exec, log following, port forwarding, or external scheduler APIs. | Automated + manual | Core docs XCTest; limitations, requirements, implementation-plan, and build-status review. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001 | Research does not add runtime mutation, RuntimeAdapter calls, direct Apple container shell-out, SQLite access outside `HostwrightState`, state writes, dependencies, network calls, image pulls, release tags, or GitHub Releases. | Manual | Diff review plus full local gate and targeted boundary scans. |

## Phase 30 Gate: Multi-Host Apple Silicon Platform Research

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-COMPAT-009 | Multi-host identity, membership, local-network discovery, peer trust, transport security, state authority, replication, failure recovery, cloud boundary, remote control, and scheduler implications have explicit reject, defer, prototype, plugin, control-plane, or separate-project decisions before implementation. | Automated + manual | Core docs XCTest and multi-host platform decision-record review. |
| HW-DOCS-002 | Core repository docs still state that Hostwright does not currently implement multi-host orchestration, remote host agents, membership service, peer discovery, state replication, remote mutation, remote placement, cloud control plane, or scheduler APIs. | Automated + manual | Core docs XCTest; limitations, requirements, implementation-plan, and build-status review. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001, HW-SAFE-008 | Research does not add runtime mutation, RuntimeAdapter calls, direct Apple container shell-out, SQLite access outside `HostwrightState`, state writes, remote policy, dependencies, network calls, image pulls, release tags, or GitHub Releases. | Manual | Diff review plus full local gate and targeted boundary scans. |

## Phase 31 Gate: Scheduler And Placement Engine

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-COMPAT-010, HW-SAFE-008, HW-RECON-002 | Scheduler reports are deterministic, explainable, local, advisory-only, and derived from declared inputs plus local policy decisions. | Automated | Reconciler XCTest cases for deterministic recommendations, policy/port blockers, scores, and stable reason codes. |
| HW-COMPAT-006, HW-COMPAT-010 | Memory and overcommit behavior uses explicit declared memory requests and resource-report host facts without capacity guarantees or inferred workload memory pressure. | Automated + manual | Reconciler overcommit/missing-memory XCTest cases and advisory-scheduler docs review. |
| HW-COMPAT-007, HW-COMPAT-009, HW-DOCS-002 | Accelerator and remote-placement dimensions block with explanations; docs still state no accelerator-aware scheduling, scheduler API, remote placement, multi-host scheduling, or automatic placement exists. | Automated + manual | Reconciler accelerator/remote-placement XCTest cases plus core docs guard. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001 | Scheduler work does not add RuntimeAdapter methods, direct Apple container shell-out, SQLite access outside `HostwrightState`, state writes, daemon scheduling, network calls, registry calls, image pulls, dependencies, release tags, or GitHub Releases. | Automated + manual | Full local gate plus targeted boundary scans and diff review. |

## Phase 32 Gate: Policy Engine

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-SAFE-008, HW-RECON-002, HW-NET-002, HW-VALID-004, HW-VALID-005 | Policy decisions are deterministic and explainable for ports, mounts, images, env/secrets, cleanup, lifecycle, secure exposure, untrusted manifests, and accelerator placeholders. | Automated | HostwrightPolicy XCTest cases. |
| HW-SAFE-008, HW-RECON-002 | Existing planner safety checks route through the local policy evaluator without changing the `PlanIssue` content that drives plan rendering and confirmation hashes. | Automated | Reconciler bridge test comparing policy decisions to planning issues. |
| HW-SAFE-002, HW-SAFE-008 | Cleanup classification remains fail-closed and confirmed deletion still requires existing ownership, adapter, service, lifecycle, dry-run, token, and exact identifier gates. | Automated + manual | Policy cleanup classification tests, CLI cleanup tests, and diff review. |
| HW-SAFE-008, HW-DOCS-002 | Docs describe local deterministic policy without claiming remote policy service, team workflow, silent bypass, runtime mutation from policy, DNS/tunnel/cloud behavior, or accelerator support. | Automated + manual | Core docs XCTest and policy/security/limitations review. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001 | Policy work does not add direct Apple container shell-out, SQLite access outside `HostwrightState`, undocumented or unsafe default state paths, registry calls, image pulls, telemetry upload, or runtime mutation. | Automated + manual | Full local gate plus targeted boundary scans and diff review. |

## Phase 33 Gate: Plugin And Extension Architecture

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-EXT-001, HW-SAFE-008 | Extension declarations are typed, versioned, trust-scoped, capability-scoped, and evaluated locally with deterministic `PolicyDecision` output. | Automated | HostwrightPolicy XCTest cases for allowed reviewed-local declarations and deterministic ordering. |
| HW-EXT-002, HW-SAFE-008 | Untrusted, unsupported-version, empty, missing-boundary, runtime-mutation, state-write, networking-provider, tunnel-provider, secret-resolution, and accelerator declarations fail closed. | Automated | HostwrightPolicy XCTest cases for deterministic in-memory declaration contracts. |
| HW-EXT-003, HW-RUNTIME-001, HW-STATE-001 | Extension architecture does not add a plugin loader, remote registry, binary distribution, untrusted code execution, RuntimeAdapter bypass, direct Apple container shell-out, SQLite access outside `HostwrightState`, state writes, or runtime mutation. | Automated + manual | Full local gate, targeted boundary scans, and diff review. |
| HW-EXT-003, HW-DOCS-002 | Docs distinguish extension declaration policy from unsupported plugin runtime, provider networking, tunnels, secret backends, accelerators, GUI, cloud, and distribution behavior. | Automated + manual | Core docs guard plus plugin-extension architecture, policy, security, and limitations review. |

## Phase 34 Gate: Enterprise And Team Workflow

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-TEAM-001, HW-SAFE-008 | Team profiles are explicit local versioned JSON, reject unknown fields, preserve every required gate, and can only add stricter digest/review requirements. | Automated + local integration | `TeamWorkflowPolicyTests`, real-file CLI tests, and built-CLI integration. |
| HW-TEAM-002, HW-SAFE-008 | Apply and confirmed cleanup reject absent, rejected, wrong-scope, stale, or mismatched approvals; valid approvals cannot bypass plan confirmation or exact ownership. | Automated | `TeamWorkflowCLITests` approval binding, mismatch, apply ownership, and cleanup ownership cases. |
| HW-TEAM-003, HW-OBS-001, HW-SAFE-004 | Profile, manifest, plan, and approval hashes persist through runtime confirmations and redacted append-only event/operation records using secure selected state paths. | Automated + local integration | Real SQLite apply/cleanup audit tests and state redaction tests. |
| HW-TEAM-004, HW-DOCS-002 | Docs describe local team workflow without claiming cloud team service, central remote control, hosted audit log, user tracking, enterprise support workflow, remote policy distribution, macOS user/group/ACL management, or shared-secret management. | Automated + manual | Core docs guard plus team workflow, governance, security, limitations, requirements, and acceptance review. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001 | Team workflow work does not add runtime mutation, direct Apple container shell-out, SQLite access outside `HostwrightState`, undocumented or unsafe default state paths, cloud services, remote policy, telemetry upload, dependencies, release tags, or GitHub Releases. | Automated + manual | Full local gate, targeted boundary scans, and diff review. |

## Phase 35 Gate: Packaging Signing Notarization And Distribution

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-REL-005 | Clean build rejects dirty/mismatched source and external SwiftPM dependencies; local output binds exact ARM64 payload, archive, SHA-256, SPDX, unsigned provenance, environment, commands, and blocked trust stages. | Automated + local evidence | Distribution model/integration XCTest, built `hostwright-dist` subprocess, clean-worktree build, artifact verifier, and evidence report review. |
| HW-REL-005 | Two distinct artifact commits complete install, execute, upgrade, execute, downgrade, execute, and exact uninstall under an explicit temporary prefix; permission-induced partial update restores the verified baseline and unrelated files remain unchanged. | Automated + local evidence | Real-file/process distribution XCTest and clean two-commit lifecycle report. |
| HW-REL-006, HW-DOCS-002 | Public docs remain source-only and distinguish local unsigned sidecars from signed/notarized binary, `.pkg`, trusted provenance, system installer, Homebrew, and package-channel support. | Automated + manual | Core release-doc XCTest plus install, limitations, release-process, distribution-readiness, and security review. |
| HW-GOV-003 | Local artifacts remain non-publishable and blocked; Phase 35 creates no tag, GitHub Release, public upload, signed claim, or package-channel claim. | Automated + manual | Blocked evidence validation, diff/PR review, identity scan, and local git status review. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001 | Distribution tooling is isolated from product runtime/state behavior and adds no Apple container command, SQLite access, third-party dependency, release tag, website, GUI, launch agent, privileged helper, or package-channel implementation. | Automated + manual | Full local gate, targeted boundary scans, package dependency inventory, and diff review. |

## Phase 36 Gate: CI Benchmarking And Performance Lab

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-COMPAT-011, HW-REL-004 | Schema-v2 reports record source/environment facts, every adapter operation, raw sample counts, all dimensions, failures/blockers, and exact cleanup; blocked/failed/fixture/scripted reports cannot satisfy a hardware pass. | Automated + live manual | Evidence/health/runtime/CLI XCTest, built-CLI integration, report parser validation, and reviewed local run. |
| HW-COMPAT-012, HW-DOCS-002 | Hosted CI remains hardware-independent while the explicit local runner performs version/stats probes, bounded samples, optional attended sleep/wake detection, and exact cleanup without publishing benchmark numbers or capacity claims. | Automated + manual | CI, core docs guard, benchmark lab, resource intelligence, limitations, release process, and compatibility review. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001 | Phase 36 runtime work stays behind RuntimeAdapter and permits only confirmed unique benchmark resources with a pre-existing image and exact cleanup; no image pull, broad cleanup, state write, telemetry, dependency, release, website, or GUI behavior is added. | Automated + live manual | Full local gate, targeted boundary scans, exact-resource live run, and post-run runtime inventory. |

## Phase 37 Gate: Documentation Site And Public Education

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-DOCS-003, HW-DOCS-005 | Core repository docs define the documentation-site information architecture and source-of-truth boundary while keeping website presentation in the separate `hostwright.dev` repository. | Automated + manual | Core docs guard plus review of `docs/architecture/documentation-site-public-education.md`. |
| HW-DOCS-001, HW-DOCS-002 | Tutorial and task outlines are tied to tested commands, checked-in examples, source-only install truth, and searchable limitations for unsupported behavior. | Automated + manual | Core docs guard plus README, CLI reference, limitations, release process, and examples review. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001 | Phase 37 does not add product code, runtime mutation, RuntimeAdapter changes, SQLite access, dependencies, release tags, GitHub Releases, website frontend, hosted docs deployment, analytics, search, or GUI code. | Automated + manual | Full local gate, targeted boundary scans, and diff review. |

## Phase 38 Gate: Governance And Contributor Model

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-GOV-001 | Governance and contributor docs define issue-to-PR-to-release flow, risky-area review triggers, verification gates, and scoped-change expectations. | Automated + manual | Core docs guard plus review of `GOVERNANCE.md`, `CONTRIBUTING.md`, issue template, and PR template. |
| HW-GOV-002 | Security reporting guidance tells reporters not to put secrets, private host details, diagnostic bundles, or exploit details in public trackers before a private contact path exists. | Automated + manual | Core docs guard plus review of `SECURITY.md` and security/safety docs. |
| HW-GOV-003 | Release governance keeps release tags, GitHub Releases, binaries, installers, signing, notarization, SBOM, provenance, support SLA, hosted diagnostics, and cloud service claims behind explicit maintainer approval and matching docs. | Automated + manual | Core docs guard plus release-process review. |
| HW-DOCS-002, HW-RUNTIME-001, HW-STATE-001 | Governance work does not add product code, RuntimeAdapter changes, SQLite access, dependencies, release artifacts, website implementation, GUI code, branch protection, CODEOWNERS enforcement, or unsupported current-support claims. | Automated + manual | Full local gate, targeted boundary scans, and diff review. |

## Phase 39 Gate: Beta Readiness

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-REL-007 | Beta readiness docs require clean-checkout source install proof, full local gate, hosted CI, docs alignment, example validation/planning, state upgrade evidence, telemetry/support policy review, and maintainer approval before any beta tag. | Automated + manual | Core docs guard plus review of `docs/release/beta-readiness.md`. |
| HW-REL-008, HW-DOCS-002 | Public docs keep beta, production readiness, binary distribution, support SLA, compatibility expansion, benchmark/capacity, cloud/tunnel/DNS, accelerator, Kubernetes/CRI/Docker API/Compose, multi-host, and GUI claims blocked until evidence exists. | Automated + manual | Core docs guard plus limitations, compatibility, install, release-process, and beta-readiness review. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001 | Phase 39 does not add product code, runtime mutation, RuntimeAdapter changes, SQLite access, dependencies, release tags, GitHub Releases, binary artifacts, installers, website/frontend work, telemetry upload, or GUI code. | Automated + manual | Full local gate, clean-checkout smoke where practical, targeted boundary scans, and diff review. |

## Phase 40 Gate: Apple Silicon Control-Plane Direction Decision

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-COMPAT-013, HW-COMPAT-009, HW-COMPAT-010 | Direction record keeps current core single-host and makes platform expansion a separate approved track. | Automated + manual | Core docs guard plus review of `docs/architecture/control-plane-direction.md`. |
| HW-COMPAT-005, HW-COMPAT-007, HW-DOCS-002 | Public docs reject Kubernetes-class, CRI, Docker API, full Compose, cloud, multi-host, remote-placement, and accelerator-aware scheduling work from current core without claiming support. | Automated + manual | Core docs guard plus limitations, charter, implementation plan, and requirements review. |
| HW-RUNTIME-001, HW-RUNTIME-002, HW-STATE-001 | Phase 40 does not add product code, runtime mutation, RuntimeAdapter changes, SQLite access, dependencies, release tags, GitHub Releases, website work, GUI code, network providers, remote mutation, or accelerator behavior. | Automated + manual | Full local gate, targeted boundary scans, and diff review. |

## Phase 41 Gate: Reviewed-Local Executable Extension Handshake Host

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-EXT-004, HW-SAFE-008 | Strict declarations require explicit absolute paths, version 1, reviewed-local trust, one approved read-only kind/capability pair, required policy boundaries, caller-owned non-symlink files, safe modes, and exact executable SHA-256. | Unit contract + local integration | `ExecutableExtensionDocumentTests`, real-file safety/digest cases, and CLI parser tests. |
| HW-EXT-005, HW-SAFE-004 | The host privately stages exact executable bytes, uses a fixed argument/minimal environment/root working directory, concurrently bounds stdout/stderr, enforces timeout, rejects nonzero exit or stderr, and cleans the staged file/directory on every result. | Local integration | `ReviewedLocalExtensionHostIntegrationTests` with a real compiled Swift process and `scripts/integration.sh`. |
| HW-EXT-006, HW-SAFE-008 | Success requires exact protocol/request/identity/declaration/capability/status response binding with unknown and duplicate response fields rejected. | Local integration | Real compiled-process success, malformed, duplicate, extra-field, and mismatch cases. |
| HW-EXT-007, HW-RUNTIME-001, HW-STATE-001 | The extension host adds no Hostwright capability invocation, RuntimeAdapter/SQLite/state authority, secret resolution, provider integration, untrusted execution, dependency, discovery, installation, persistence, or distribution path; docs state that reviewed code still has ambient account privileges. | Automated + manual | Built-CLI integration, full local gate, targeted boundary scans, module/diff review, and docs guard. |
| HW-EXT-004, HW-EXT-005, HW-DOCS-001 | Text/JSON CLI success and stable redacted `HW-EXT-001` through `HW-EXT-003` errors match the documented handshake-only scope. | Local integration + manual | CLI XCTest, built-CLI text/JSON process proof, CLI reference, architecture, security, and limitations review. |

## Phase 42 Gate: One-Shot Local Control API

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-GUI-005, HW-SAFE-004 | API version 2 accepts exactly one bounded JSON request over a real pipe, emits exactly one bounded JSON response, requires a launch-fixed absolute manifest plus optional absolute state/profile overrides, and uses the documented secure state default when the state override is omitted. | Unit contract + local integration | `ControlRequestTests`, real-pipe timeout/overflow/EOF cases, and `scripts/integration.sh`. |
| HW-GUI-006, HW-DOCS-001 | Plan, status, events, recovery, and doctor delegate to existing CLI JSON contracts, preserve errors and exit codes, redact persisted secret-like values, and document state-backed status side effects. | Local integration + manual | `LocalControlAPIIntegrationTests` with real files, profile parsing, SQLite rows, CLI docs, and built-tool plan proof. |
| HW-GUI-007, HW-SAFE-004 | Unknown/duplicate fields, unsupported versions, invalid filters, unsafe paths, missing state, oversized input, and mutation operation names fail closed with structured `HW-API-001` through `HW-API-003` errors. | Unit contract + local integration | Parser/file-safety XCTest, real rejected built-tool mutation request, and redaction assertions. |
| HW-GUI-008, HW-RUNTIME-001, HW-STATE-001 | The API adds no persistent daemon, listener, background service, remote control, runtime mutation, direct RuntimeAdapter/SQLite access, request-selected path, hidden state write, dependency, release, website, or GUI behavior. | Automated + manual | Full local gate, module/diff review, no-hidden-state subprocess proof, targeted boundary scans, and docs guard. |
