# ADR 0018: Opt-in multi-Mac cluster mode

Status: accepted by the maintainer on 2026-11-22 when authorizing the v0.0.3
implementation in batches. Tracked in [V3-12](https://github.com/hostwright/hostwright/issues/459).

## Decision

Hostwright v0.0.3 will add opt-in clustering to core. One control Mac places
workloads on enrolled Macs, and TCP service traffic can cross nodes. Workers run
the existing daemon and local lifecycle engine. Standalone mode remains the
default. For v0.0.3 this supersedes the product direction in
[control-plane direction](../architecture/control-plane-direction.md) and
[multi-host research](../architecture/multi-host-platform-research.md).
The [implementation plan](../roadmap/v0.0.3/IMPLEMENTATION_PLAN.md#3-architecture-decisions)
defines decisions D1–D20 and their alternatives.

The control Mac's SQLite ledger is authoritative for membership, placement, and
operation groups. Each worker's local ledger records accepted generations and
executed work. The operator confirms the exact cluster plan, and workers fence
mutations by assignment generation and token. A partitioned worker keeps running
its accepted assignments. Restoration on the original control Mac holds changes
until the control Mac reconciles fences and the operator reauthorizes identities
and secret grants. Loss of the non-exportable CA key requires a new cluster and
worker re-enrollment. Control-plane HA and volume migration are outside this release.

The Control API stays local to the control Mac. The control daemon opens a
mutually authenticated TLS link to each worker. Enrollment uses a single-use,
expiring token and a worker-generated Keychain identity. Workers enforce local
runtime ownership and expose only authorized traffic and operations. Volumes
stay on their owning node. Bind mounts, host access, and file-based secret
references are pinned to the control Mac. Secret delivery is default-deny.

## Platform expansion gates

| Required item | Decision or evidence |
|---|---|
| Product placement | Opt-in core mode (D1). |
| Protocol and non-goals | Capability matrix, D7, and cluster protocol v1 in plan sections 1 and 4. |
| State authority, locking, idempotency, migration, backup, recovery, rollback | D2, D4, D15 and schema v25. Verify with V3-20, V3-64, and V3-68. |
| Identity, enrollment, authorization, revocation, transport, audit | D7, D8, D14. Verify with V3-22, V3-24, V3-50, V3-51, V3-52, and V3-55. |
| Lifecycle, networking, mounts, images, secrets, cleanup, diagnostics, untrusted input | D4, D9–D14, D20. Verify with V3-45, V3-53, V3-54, V3-56, V3-89, and V3-95. |
| Scheduling, capacity, and failure domains | D9 and D15. Measure per-node capacity and use real node snapshots in V3-26 and V3-31. |
| Disposable proof and image consent | Rehearsal and live tiers in sections 7 and 8. Use isolated state and owned fixtures. Obtain approval for named images before pulling. |
| Public support claims | Limit claims to the topologies and capabilities verified by the proof. See the section 1 matrix and V3-74. |
| Trust boundary and consent | Local Control API and per-user daemon (D5, D6), explicit join, and Local Network permission (D8, V3-14). |
| Supported and refused host operations | Section 1 matrix and D5. Refuse unsupported operations before effects. |
| Policy and scheduler interaction | D9, D11, and the cluster permission rules in V3-50. |
| Threat model | V3-13 maps enrollment, revocation, peer authentication, per-operation authorization, state and partition behavior, heartbeats and split-brain, failure domains, local-network consent, cloud and telemetry boundaries, audit, and manual recovery to verification in V3-57. See D2 and D15. |
| Maintainer approval | This ADR is the approval gate for Phase 1. Dependent work follows the roadmap. |

## Delivery

Publish two or three dependency-ready issues per batch and close each after its
acceptance criteria are verified and the PR lands. Use the existing required
checks. Defer CI optimizations and release-pipeline cleanup until they are needed
to unblock product work or publication. Capability claims require the planned
rehearsal and live proof on real Macs.
