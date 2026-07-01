# Acceptance Matrix

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
| HW-RUNTIME-003 | Runtime types cover desired state, observed state, planned actions, runtime events, capabilities, metadata, and typed errors. | Automated | Swift smoke tests for type construction, mock observation, and error mapping. |
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
| HW-STATE-001, HW-STATE-002 | SQLite schema and migrations are explicit and isolated in `HostwrightState`. | Automated | Migration tests on temporary databases. |
| HW-STATE-003, HW-OBS-001 | Events and operation records survive process restart. | Automated | Crash/reopen state tests. |
| HW-STATE-004, HW-SAFE-004 | Known secret fixtures never appear in state, logs, status, or events. | Automated | Redaction tests. |
| HW-STATE-005 | Ownership ledger can distinguish owned, unowned, and ambiguous resources. | Automated | Ledger tests. |

## Phase 7 Gate: Real Planning And Drift

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-RECON-001, HW-RECON-002, HW-RECON-003 | Planner produces deterministic plans from desired and observed state. | Automated | Missing, stopped, unmanaged, unhealthy, changed, and duplicate resource tests. |
| HW-NET-001, HW-NET-002, HW-NET-003 | Port and exposure validation happen during planning, before mutation. | Automated | Port conflict and unsafe exposure tests. |
| HW-VALID-004, HW-VALID-005, HW-VALID-006 | Unsafe volumes, secret-like env paths, and unsupported features fail closed before mutation. | Automated | Manifest/policy tests. |

## Phase 8 Gate: First Runtime Mutation

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-CLI-008, HW-RECON-004, HW-RUNTIME-006 | `apply` persists intent before mutation and mutates only through `RuntimeAdapter`. | Automated + manual | Mock adapter tests; disposable Apple container integration tests. |
| HW-RECON-005 | Partial apply failure leaves recoverable operation records. | Automated | Failure injection tests. |
| HW-SAFE-001 | `plan` remains non-mutating and reviewable before `apply`. | Automated | CLI and planner tests. |

## Phase 9 Gate: Operability And Cleanup

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-HEALTH-002, HW-HEALTH-003 | Health checks and restart policy use bounded crash-loop backoff. | Automated | Health/restart tests. |
| HW-SAFE-002, HW-SAFE-003 | Cleanup refuses ambiguous resources and preserves named volumes by default. | Automated + manual | Cleanup dry-run and ownership tests. |
| HW-OBS-002, HW-OBS-003, HW-OBS-004 | Status, logs, and events are useful and redacted. | Automated | Snapshot/redaction tests. |

## Phase 10 Gate: First Supported Release

| Requirement IDs | Acceptance criteria | Verification type | Verification command or review |
| --- | --- | --- | --- |
| HW-REL-001, HW-REL-002 | Release checklist passes with build, tests, docs, examples, compatibility, and limitations reviewed. | Automated + manual | Local release checklist and reviewer signoff. |
| HW-REL-003 | Signing, notarization, SBOM, checksums, and provenance decisions are documented before public artifacts. | Manual | Release hardening review. |
| HW-REL-004 | Apple silicon performance claims are backed by benchmark data. | Automated + manual | Benchmark scripts and benchmark report. |
