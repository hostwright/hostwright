# Phase 10 G3-G8 Scheduler Engine

Status: Accepted for the pure scheduler-engine vertical slice.

## Decision

SchedulerEngine accepts only immutable, caller-supplied snapshots. It validates
finite input limits and resource-limit charges, computes a canonical SHA-256
input digest from normalized inputs (or rejects a mismatching expected digest),
and runs the existing G1 hard filters. Queue ordering first applies the
explicit priority/starvation policy and weighted current dominant allocation
share, recomputed after each accepted placement. Pending demand remains an
explainable eligibility and borrowing input, not allocated usage.
Best-fit-decreasing normalized demand then orders workloads within equal fair
eligibility, with stable workload UUID as the final tie-break. Feasible nodes are scored with
checked integer basis-point components for fragmentation, DRF fairness,
topology, locality, host posture/energy, and disruption. Input ordering never
affects the result.

The default resource overcommit ratio is exactly 1/1. An explicit bounded
integer ratio may charge a declared limit lower than its raw value, while the
engine always charges max(request, ceil(limit / ratio)). Critical, unknown, or
unavailable pressure is a hard filter; elevated pressure is a score deweight.
Borrowed fairness usage is recorded as reclaimable and may only be represented
by a preemptible victim.

## Boundary

Planning and simulation are read-only and do not reserve capacity, fence
victims, call clocks, probes, databases, runtimes, or globals. When capacity
requires lower-priority work, a deterministic exact bounded branch search
selects the minimum declared disruption cost under all budgets. The explicit
per-node victim and search-state bounds fail closed with an actionable explanation
when exact enumeration would exceed either contract limit; no heuristic nonminimal
plan is returned.
Sequential placements update only local immutable planning snapshots. When
capacity requires lower-priority work, the engine returns a deterministic
minimum-disruption preemption intent with its input digest and
requiresFence == true; a later admission boundary must revalidate and obtain
the durable fence.

Every result is bounded and Codable/Sendable. Its deterministic UUID decision ID
is derived from canonical input/output material with SHA-256 and its explanation
includes chosen placement, score components, alternatives, every hard-filter
failure, limit charges, and preemption intent details.

## Consequence

The engine can be replayed or simulated safely from the same snapshots, while
state admission remains responsible for reservations, fencing, and durable
capacity authority.
