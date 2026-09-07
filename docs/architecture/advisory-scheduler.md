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

## Reduced Local Lifecycle

The [reduced release decision](../design/adr-0015-reduced-local-release.md) admits normal local lifecycle commands through the authenticated daemon. Each request receives its authenticated subject and daemon-owned capacity, configuration, profile, and pressure snapshots. The two local providers share one physical capacity ledger. The default budget leaves one logical CPU and the greater of 2 GiB or one quarter of physical memory for the host. This budget does not promise exclusive physical capacity against unrelated applications.

A confirmed plan maps each service replica to an exact resource UUID, resource generation, provider, and immutable runtime ownership fence. A generation-specific scheduler workload UUID distinguishes replacement workloads from the resources they replace. Existing resource-scoped decision identities remain readable. Hard placement constraints are checked for retained workloads as well as new workloads. Runtime preemption, disruption policies, soft affinity, topology optimization, and accelerator requests are rejected before opening lifecycle state.

Admission registers a fresh project's identity without publishing desired services. The scheduler checks the complete selected workload set and reserves every new placement in one transaction. A failed sibling rolls back the batch and its fence sequences. Only successful admission permits publication of desired services and network, storage, or runtime effects. Every create, start, or restart rechecks the persisted reservation, node epoch, current configuration/profile digests, and fresh admissible host pressure.

The pressure probe reads the current kernel memory-pressure level for every sample; unavailable or unrecognized readings remain unknown and block new admission. The mapping follows [Apple's XNU pressure interface](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_memorystatus_notify.c). Pressure records older than five seconds cannot authorize local admission. Pressure does not prevent stopping or removing existing workloads.

Scheduler release concerns CPU and memory execution reservations. An authoritative provider inventory can prove either that the exact generation is absent or that its VM execution has ended while a created, stopped, or exited container configuration remains. Evidence distinguishes `inactive` from `absent` and binds the exact ownership tuple and inventory digest. Both use the existing schema-v24 `runtime-absence` evidence kind; neither permits deleting an ownership record while its container configuration remains. Resource removal retains its stronger exact-absence and dependent-finalizer checks. Unknown state, a foreign ownership tuple, an incomplete inventory, or a stale reservation fence retains capacity.

Daemon startup and lifecycle completion reconcile pending and committed reservations. A running workload keeps its capacity even without a health check. A stopped workload can release CPU and memory while retaining its configuration for the next `up`. Expiry alone never releases capacity. An immutable resource fence and a per-operation fence are checked separately when the lifecycle finalizer releases its exact finite mutation lease.

## Qualification Boundary

The pure scheduler, manifest bridge, policy checks, migration/repository behavior, authenticated Control 2.2 admission/release path, and owned lifecycle handoff form the bounded single-host admission slice. Current-source G3-G8 qualification is sealed with zero safety mismatches and 382 retained intentional optimization-gap fixtures. Remaining G13-G15 optimization, pressure, accelerator, distribution, and aggregate capability promotion stay evidence-gated under their owning workstreams. `scheduler.optimization` and `accelerators.host-native` remain unavailable.

The retained filename is an ADR traceability path; it does not authorize an advisory implementation or compatibility execution path.
