# Scheduler Placement And Durable Admission Boundary

> The historical Phase 31 local recommendation experiment is superseded by the direct Phase 10 scheduler and admission contracts. Current-source G3-G8 scheduler qualification is sealed, but aggregate G13-G15 qualification remains evidence-gated.

Status: Phase 10 / issue #207 single-host admission boundary; not a stable aggregate qualification claim.

Phase 10 has one scheduler boundary. `HostwrightScheduler` is the pure placement contract and `HostwrightState` is the durable admission authority. The reconciler bridge translates the manifest contract into those boundaries; it does not provide a second local scheduler.

## Direct Boundary

- `Sources/HostwrightScheduler/` owns canonical resource vectors, workload and node snapshots, deterministic hard placement filters, scoring/explanation ordering, and `plan`/`simulate` operations.
- `Sources/HostwrightReconciler/ManifestSchedulerAdmissionBridge.swift` maps manifest resource requests into scheduler placement demand and maps declared limits into the runtime hard-enforcement input. It validates profile ceilings and permissions before admission and rejects unsupported runtime claims.
- `Sources/HostwrightState/SchedulerAdmissionRepository.swift` durably records node-capacity history, decision/reservation bindings, active-capacity accounting, idempotent replay, and fencing/release evidence.
- The persisted capacity generation and digest are authoritative. A caller cannot inflate capacity or replay a decision with changed resource, input, configuration, profile, lifecycle-plan, owner, or project bindings.
- Database transactions contain only state work. Runtime observation and mutation are performed at the surrounding lifecycle boundary after the durable decision or release evidence is verified.

## Admission And Enforcement

Requests drive placement and capacity accounting. Limits are the runtime enforcement values, so a runtime adapter that supports only CPU and memory must receive the declared limits. Unsupported hard limits, provider claims, accelerator claims, and scheduler constraints fail before runtime mutation with stable structured reasons.

Profile permissions and ceilings are authoritative admission constraints. A manifest may narrow a resolved profile but cannot enlarge its CPU, memory, process, provider, or accelerator permissions. The default overcommit policy remains explicit scheduler input and is never an implicit manifest relaxation.

## Durable Safety Invariants

- A reservation binds workload/node UUIDs, the canonical resource vector, capacity generation/digest, decision input/config/profile/lifecycle digests, owner subject, project, expiry metadata, and a structured fencing token.
- Identical replay returns the stored decision and reservation only after comparing the complete authoritative binding. Conflicting replay, stale capacity/input, duplicate active workload, insufficient capacity, and stale fencing evidence fail closed.
- Expiration does not release capacity. Release requires verified runtime absence or authoritative fencing evidence, with lineage, token, digest, timestamp, and monotonic-epoch checks.
- The public release operation persists intent before effects, executes the selected workload through owned-only lifecycle removal, and retains capacity in `release-pending` until fresh authoritative inventory proves absence. Ambiguous cleanup remains safely resumable.
- Node-capacity snapshots are immutable history. New reservations require the latest generation; an existing exact replay may validate its originally bound historical generation.

## Qualification Boundary

The pure scheduler, manifest bridge, policy checks, migration/repository behavior, authenticated Control 2.2 admission/release path, and owned lifecycle handoff form the bounded single-host admission slice. Current-source G3-G8 qualification is sealed with zero safety mismatches and 382 retained intentional optimization-gap fixtures. Remaining G13-G15 optimization, pressure, accelerator, distribution, and aggregate capability promotion stay evidence-gated under their owning workstreams. `scheduler.optimization` and `accelerators.host-native` remain unavailable.

The retained filename is an ADR traceability path; it does not authorize an advisory implementation or compatibility execution path.
