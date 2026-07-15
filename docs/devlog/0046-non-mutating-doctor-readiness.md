# Devlog 0046: Non-Mutating Doctor Readiness

Date: 2026-07-14

Issue: #117

## Outcome

`hostwright doctor` is now a real local readiness gate rather than an executable-presence summary. Schema version 2 classifies every check as `ready`, `degraded`, `externally-constrained`, `blocked`, or `unsupported`, reports bounded remediation, selects the strictest overall readiness, and maps that result to stable CLI exits.

The implemented flow covers supported hardware and macOS, Apple CLI/service readiness, manifest presence, filesystem policy, immutable state health, permissions, local interfaces, executable signing and Gatekeeper trust, reclaimable memory and thermal pressure, required tools, local-only telemetry, and extended resource reporting.

## Boundary Decisions

- Apple runtime facts cross `RuntimeAdapter.runtimeReadiness()`. The provider runs only a bounded CLI-version command and `container system status --format json`; CLI and health code do not execute Apple container directly.
- Runtime status parsing is typed and limited to 64 KiB. CLI version output is independently limited to 1 KiB, only semantic CLI/service versions and a bounded printable build token enter diagnostics, and duplicate top-level JSON fields fail closed. Apple's status-1 JSON for not-running and unregistered services crosses an exact read-only exit policy; every mutation and unrelated command remains zero-only.
- Existing state is opened only after secure path validation and only as a checkpointed `mode=ro&immutable=1` snapshot. Doctor never creates or migrates the database, checkpoint files, lock files, or sidecars.
- An existing shared Hostwright fence is honored without changing it. Database identity, content fingerprint, and checkpointed sidecar state are checked before and after inspection.
- A rollback journal or nonempty WAL blocks immutable inspection. Doctor does not conceal ambiguity by checkpointing another process's state.
- Signing assessment uses absolute public macOS tools with the shared bounded subprocess implementation. Raw authority/team output is not emitted.
- Local Network authorization is not prompted. Public interface availability is reported separately from future listener authorization.
- Critical thermal state or less than five percent reclaimable memory blocks readiness. Lower pressure thresholds degrade readiness without claiming workload capacity.

## Failures Found During Implementation

The first non-mutating state design used a normal SQLite read-only connection. A real byte snapshot proved that opening it could change shared-memory coordination bytes. The inspection profile now requires a sidecar-free checkpointed database and SQLite immutable read-only mode.

Control API review also found that doctor did not carry the launch-configured state path. The delegated doctor request now receives the same fixed `--state-db` value as other state-backed control operations.

The focused review found three misleading boundary cases before closure. Apple intentionally returns exit status 1 with valid stopped/unregistered JSON, so the zero-only process boundary had discarded the typed state. Active WAL or lock refusal was also mislabeled as unrecoverable and advised restore; it now becomes a retryable `inspection-failed` result while completed integrity checks retain real degraded/unrecoverable classifications. Finally, the optional Swift toolchain no longer degrades a release installation when every runtime-required tool is present.

The integration cleanup contract was missing the schema-v7 writer-fence file introduced by issue #115. Cleanup now names that exact Hostwright-owned file; it does not broaden deletion.

## Verification

Focused evidence uses the real public host network, Mach memory, thermal, code-signing, and Gatekeeper boundaries; real SQLite databases and active WAL writers; exact file-set snapshots; typed Apple status fixtures and command specifications; and built CLI/Control API workflows. Tests cover every readiness value, precedence, remediation, external-service states, unsafe paths, healthy state, active WAL refusal, no-lock creation, existing-lock reuse, runtime error redaction/limits, and exact state bytes before and after doctor.

The local gate executes 517 repository tests with zero failures and passes `scripts/integration.sh`. The expanded 24-test doctor/state/runtime/process/Control API boundary passes independently under AddressSanitizer and ThreadSanitizer with zero reports. Normal build, lint, naming, current-truth, 290-reference documentation, every quickstart, and patch-hygiene checks pass.

The final isolated proof uses the built binary and Apple `container` CLI/service 1.0.0. Missing-state doctor creates no state artifact. After a real status observation creates schema-v7 state, doctor reports state integrity ready while the exact five-file state set and every file digest remain unchanged. Apple inventory is byte-identical before and after at SHA-256 `72c1055bba3b39b4050f16a777675a1b155f995ff46e2c2cdeca19d392c0819f`; cleanup removes the isolated root exactly.

Aggregate exact-commit and hosted-CI evidence remains recorded at the single Phase 02 PR gate. This devlog does not substitute a local result for that aggregate gate.

## Remaining Boundary

Doctor does not prove registry reachability, image trust, workload health, port reachability, LAN consent, runtime density, sustained thermal/battery behavior, or production capacity. It does not repair the host or start Apple services. Those outcomes remain owned by their implementation and qualification phases.
