# ADR: Phase 10 scheduler read compatibility boundary

Status: accepted

## Decision

Control protocol revision 2.2 is current and 2.1 remains the previous
revision. Existing unary and stream operations accept either revision, and
responses/stream frames echo the request or stream revision. Revision 2.0 is
not newly accepted. The connection authentication exchange remains the exact
frozen `hostwright-control-credential-proof-v2.1` 2.1 shape; there is no
wire-level hello that can safely negotiate a different authentication label.

All six scheduler operations require revision 2.2 and are gated before
authorization or handler dispatch when requested at 2.1. Their strict bodies
are `{"projectID": ..., "input": ...}` for `scheduler.plan` and
`scheduler.simulate`, `{"projectID": ..., "decisionID": ...}` for
`scheduler.status` and `scheduler.explain`, and
`{"projectID": ..., "decisionID": ..., "workloadID": ...,` plus
`"expectedInputDigest": ...}` for `scheduler.apply` and `scheduler.release`.
RBAC maps status and explain to project reads, plan and simulate to project
planning, and apply and release to project update. The daemon verifies that
pending workloads, fairness records,
existing placements, victim allocations, and disruption budgets remain in the
top-level project. Victim allocations require immutable subject and project
identities, budgets require an immutable project identity, and each victim
budget reference must resolve to a budget in the same project. Nodes,
topology, pressure, and resource-ratio snapshots are explicitly
cluster/host-global inputs.

`scheduler.simulate` calls the immutable scheduler engine without persistence,
reservation, runtime, clock, audit-secret, or lifecycle effects. `scheduler.plan`
persists the complete bounded decision as an immutable, replayable artifact and
is classified and audited as a durable operation; it does not consume capacity.
Status and explain are project-scoped reads of that artifact and all of its
reservations. The injected apply handler reloads the artifact, revalidates the
expected input and fresh daemon-authoritative capacity/configuration/profile/
lifecycle/pressure snapshots, and creates a pending durable reservation before
any runtime call. Runtime mutation is outside the database transaction;
success commits, while failure or death leaves a recoverable pending
reservation. `HostwrightDaemonControlService` injects the repository-backed
authority provider, pressure refresher, authorized reservation mutation, and
victim-fencing closures. Those closures hand the durable reservation and
preemption lineage through `UnattendedLifecycleReconciler`, which validates the
project, manifest, lifecycle digest, ownership, and fencing binding before the
runtime driver is allowed to mutate. Unsupported, unavailable, or
non-authoritative runtime evidence still rejects or retains the durable
authority; no live-runtime capability is implied by this control wiring.
Preemption intent is proposed until the authorized victim-fencing transition
returns exact fence evidence; a proposed intent is never fence evidence.

`scheduler.release` reloads the same exact project/decision/workload/input
binding used by apply. It first persists `release-pending`, which continues to
consume capacity, and then runs the selected workload through the owned-only
`rm` lifecycle path. Capacity is returned only after fresh authoritative
runtime inventory proves the exact ownership-bound resource absent. Runtime
failure or ambiguous observation leaves the durable `release-pending` record
for an idempotent retry; an already released binding replays without another
runtime mutation.

The production daemon wires the public host-pressure probe through
`SchedulerPressureAuthorityCoordinator` and persists the versioned pressure
policy envelope through the scheduler repository. Unknown/unavailable and
critical postures block admission, warning/elevated postures deweight, and
reclamation observations do not become reusable capacity. The v22/v23 state
path preserves pressure, decision, reservation, fairness, budget, preemption,
and paired-fencing authorities across explicit migration and reopen.

The reconciler boundary intentionally continues to block manifest-only
placement: `ReconciliationPlanner` requires a persisted Control 2.2 decision
and fenced reservation before runtime mutation. The daemon's authorized
scheduler handoff is consumed by `UnattendedLifecycleReconciler`; no separate
manifest-only or compatibility scheduler path is exposed. The admission slice
does not authorize remote placement, an external scheduler, optimization
promotion, or accelerator execution; those remain separate Phase 10
qualification boundaries.

## Consequences

The compatibility policy is explicit at request, response, and stream
boundaries rather than being inferred from the enum's current value. Strict
canonical JSON validation rejects unknown scheduler body fields, duplicate
keys at any nesting level, oversized bodies, and hostile nesting/node counts
before scheduler decoding. Redacted stable errors are returned for boundary
failures; scheduler decisions and input digests remain replayable through the
pure engine contract.
