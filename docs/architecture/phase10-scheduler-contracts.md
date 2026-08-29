# Phase 10 G1-G2 Scheduler Contracts

Status: Accepted for the first Phase 10 vertical slice.

## Decision

Phase 10 starts with a dependency-free `HostwrightScheduler` module containing
pure, immutable contracts. Resource quantities use `ResourceVector`: named
`Int64` values that must be nonnegative, reject invalid names, omit zero
entries, and expose checked addition, subtraction, remaining-capacity, and fit
operations. Arithmetic overflow and underflow are stable validation errors.

`WorkloadResourceSnapshot` validates that every request fits its optional
limit. `NodeResourceSnapshot` validates allocation against capacity and derives
available resources once. `WorkloadPlacementRequirements` and
`NodePlacementSnapshot` carry only explicit scheduling facts: architecture,
runtime/provider identity, capabilities, health/maintenance state, labels and
affinity, taints/tolerations, and accelerator request/availability vectors.

`HardPlacementFilterEvaluator` evaluates every hard filter without consulting a
clock, database, runtime, platform probe, or global service. Capacity,
architecture, runtime/provider, capabilities, health/maintenance,
labels/affinity, taints/tolerations, and accelerator availability each emit
typed blocking reasons. Results sort by lowercased UUID order; reasons sort by
filter order, semantic reason order, stable detail key, and message. The same
snapshots therefore produce the same eligible results and explanations.

## Boundary

This slice does not reserve capacity, score or pack workloads, mutate runtime
state, persist scheduler state, inspect Apple hardware, discover provider
capabilities, execute accelerator work, or implement pressure, topology,
preemption, disruption, hysteresis, fairness, or compatibility behavior.
Accelerator fields are declarations and immutable availability evidence only;
they are not a claim of accelerator access.

## Consequence

Later Phase 10 work can build packing, explanation, and policy behavior on
validated snapshots without reinterpreting resource arithmetic or placement
eligibility. Any future runtime, state, probe, or reservation integration must
remain outside these pure contracts and add its own evidence and boundary
decision.

## Persistence boundary: v22 scheduler authority

The first durable scheduler slice is additive state schema v22. Node capacity
is immutable history keyed by `(node_uuid, generation)` and bound to its
canonical vector digest. New admission reads only the latest generation;
replay of an existing decision verifies the exact historical generation it was
bound to. A newer snapshot therefore cannot rewrite an older decision, while
new work cannot reserve against a stale generation or an inflated caller
assertion.

Planning persists an immutable decision artifact independently from admission;
it does not consume capacity or create a reservation. Apply later creates the
reservation in a transaction after revalidating the artifact binding and
current authority. The reservation binding includes workload/node UUIDs,
canonical resources, capacity digest/generation, input/config/profile/
lifecycle-plan digests, owner subject, project UUID, bounded lease metadata,
and the deterministic reservation identity. Exact replay compares immutable
semantic fields before returning the existing artifact or reservation; caller
timestamps do not change an identical replay. Each reservation stores a
structured `(node_epoch, reservation_sequence)` token. Ordinary reservation
allocation advances only the node's durable next sequence; sibling sequences
therefore do not stale one another. Authoritative recovery advances the node
epoch transactionally, and later fence/release evidence must carry the current
epoch, the reservation's immutable sequence, and that reservation/workload
lineage. Ordinary commit, release-request, and verified-runtime-absence
release require the exact stored token and current epoch; stale tokens fail
closed. Pending, committed, release-pending, and fenced records continue to
consume capacity. Expiry is metadata only: capacity is released only by
explicit verified runtime-absence or authoritative-fence evidence, whose
verification time is no earlier than the reservation's current `updatedAt`.
Fenced records persist `updatedAt == fenceAt`; released records persist
`updatedAt == releaseAt`, with `createdAt <= fenceAt <= releaseAt` when both
proofs exist. When both proofs exist, an authoritative release proof keeps
the same reservation sequence and lineage and carries an epoch greater than
or equal to the fence proof's epoch; equality is valid when no later recovery
intervened.

The repository validates identifiers, digests, canonical vectors, timestamps,
proof fields, policy envelopes, and state transitions at the database
boundary. It performs no runtime or platform calls inside transactions, so
crash/reopen recovery is a replay of durable state. v22 includes the durable
node-capacity, decision, reservation, fairness, disruption-budget,
preemption-intent, and host-pressure authorities; later schema work may extend
these records only through the explicit checksum- and backup-aware migration
path.
