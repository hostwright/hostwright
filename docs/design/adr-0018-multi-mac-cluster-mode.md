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
checks. Phase 0 includes CI speed work (V3-01 to V3-06), release-gate
generalization (V3-07), and evidence-based test cleanup (V3-08 to V3-10).
Cluster work proceeds in parallel. The CI targets do not block it. Capability
claims require the planned rehearsal and live proof on real Macs.

## Existing cluster contracts (V3-90)

The inventory covers all 136 public types in the 12 `HostwrightCluster` source files at `9683d8c7`. Reuse carries forward a covered contract. Adapt identifies a contract change or a coverage gap to close at the consuming issue. Retire means the v0.0.3 path leaves the contract unused. For retired types the plan issue names the replacement boundary.

- The control Mac is the sole voter. Workers enter as learners, and v0.0.3 has no operator path for promotion or voter replacement. V3-21 creates the voter and V3-24 enrolls learners.
- V3-52 adds an explicit learner-removal transition. It binds the existing learner by UUID, leaves the voter set unchanged, advances the membership epoch once, and records exact replays in the control store. Removal publishes revocation and fences the live session and streams. An unreachable worker still requires local reset as described in D8.
- V3-24 replaces token expiry by membership epoch with a persisted 15-minute wall-clock deadline checked by the control Mac. Retain the issuance epoch for membership authority and the consumed token ID for single-use enforcement. The control ledger retains the token ID, digest, bound node name, and deadline while the secret stays in Keychain.
- The network wire contract uses the distinct name `hostwright-cluster-link-v1`. The existing `hostwright-cluster-node-agent-v1` label and 45 KiB cap remain on the local `AF_UNIX` subprocess transport. The inner `hostwright-cluster-session-v1` and `hostwright-cluster-session-handoff-v1` labels remain distinct from outer link framing. V3-91 selects the transport and V3-22 implements the link.

### ClusterCertificateLifecycle

| Public type | Disposition | Plan issue | Reason | Restored test for reuse |
|---|---|---|---|---|
| [`ClusterCertificateLifecycleError`](../../Sources/HostwrightCluster/ClusterCertificateLifecycle.swift#L9) | reuse | V3-24, V3-51 | Preserve fail-closed local Keychain errors during enrollment and rotation. | [`ClusterCertificateLifecycleTests.testLockedIsolatedKeychainFailsWithoutInteraction`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterCertificateLifecycleTests.swift#L599) |
| [`ClusterCertificateLifecycleContract`](../../Sources/HostwrightCluster/ClusterCertificateLifecycle.swift#L70) | adapt | V3-51 | Keep private-store bounds and use D8's seven-day leaf default. | — |
| [`ClusterCertificateOwnedReferences`](../../Sources/HostwrightCluster/ClusterCertificateLifecycle.swift#L82) | reuse | V3-21, V3-51 | Keep private persistent references local to their owning Keychain. | [`ClusterCertificateLifecycleTests.testRotationOverlapsSequentialGenerationsThenExactlyDeletesRetiredItems`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterCertificateLifecycleTests.swift#L100) |
| [`ClusterCertificateAuthorityCredential`](../../Sources/HostwrightCluster/ClusterCertificateLifecycle.swift#L120) | reuse | V3-21 | Keep the control CA certificate bound to its local Keychain key. | [`ClusterCertificateLifecycleTests.testBootstrapPersistsOnlyPublicEvidenceAndReturnsNonExportableIdentity`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterCertificateLifecycleTests.swift#L28) |
| [`ClusterCertificateLeafCredential`](../../Sources/HostwrightCluster/ClusterCertificateLifecycle.swift#L133) | reuse | V3-24 | Bind each installed leaf to the worker's local key and certificate references. | [`ClusterCertificateLifecycleTests.testBootstrapPersistsOnlyPublicEvidenceAndReturnsNonExportableIdentity`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterCertificateLifecycleTests.swift#L28) |
| [`ClusterCertificateGenerationCredential`](../../Sources/HostwrightCluster/ClusterCertificateLifecycle.swift#L185) | adapt | V3-24, V3-51 | Keep generation ownership exact when CA and worker leaves live in separate Keychains. | — |
| [`ClusterCertificateLifecycleMetadata`](../../Sources/HostwrightCluster/ClusterCertificateLifecycle.swift#L307) | adapt | V3-24, V3-51 | Separate local Keychain metadata from the control's enrolled-worker certificate records. | — |
| [`ClusterCertificateIdentityHandle`](../../Sources/HostwrightCluster/ClusterCertificateLifecycle.swift#L1043) | reuse | V3-22 | Expose the opaque local identity and certificate chain to the link TLS adapter. | [`ClusterCertificateLifecycleTests.testBootstrapPersistsOnlyPublicEvidenceAndReturnsNonExportableIdentity`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterCertificateLifecycleTests.swift#L28) |
| [`ClusterCertificateLifecycle`](../../Sources/HostwrightCluster/ClusterCertificateLifecycle.swift#L2477) | adapt | V3-21, V3-24, V3-51 | Reuse CA bootstrap and journaled recovery while adding certificate issuance for worker-generated keys. | — |

### ClusterCertificateTrust

| Public type | Disposition | Plan issue | Reason | Restored test for reuse |
|---|---|---|---|---|
| [`ClusterCertificateError`](../../Sources/HostwrightCluster/ClusterCertificateTrust.swift#L6) | reuse | V3-22, V3-52 | Preserve stable trust failures for a wrong CA, credential role, or revoked leaf. | [`ClusterCertificateTrustTests.testWrongAuthorityAndRevokedPeerFailClosed`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterCertificateTrustTests.swift#L233) |
| [`ClusterCertificateContract`](../../Sources/HostwrightCluster/ClusterCertificateTrust.swift#L50) | adapt | V3-22, V3-56 | Carry forward the SAN namespace and enforce its existing bounds at the link boundary. | — |
| [`ClusterCertificateGeneration`](../../Sources/HostwrightCluster/ClusterCertificateTrust.swift#L59) | reuse | V3-51 | Keep positive monotonic generations and sequential retirement overlap. | [`ClusterCertificateTrustTests.testRotationAllowsOneSequentialOverlapThenRetiresOldAuthority`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterCertificateTrustTests.swift#L286) |
| [`ClusterCertificateRole`](../../Sources/HostwrightCluster/ClusterCertificateTrust.swift#L96) | reuse | V3-22, V3-24 | Use the existing node-agent client and server certificate roles for the control and worker. | [`ClusterCertificateTrustTests.testPeerIdentityAndUsageMustMatchExactly`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterCertificateTrustTests.swift#L184) |
| [`ClusterCertificateIdentity`](../../Sources/HostwrightCluster/ClusterCertificateTrust.swift#L103) | reuse | V3-22, V3-24 | Bind the peer SAN to the cluster, node, certificate role, and generation. | [`ClusterCertificateTrustTests.testPeerIdentityAndUsageMustMatchExactly`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterCertificateTrustTests.swift#L184) |
| [`ClusterCertificateAuthority`](../../Sources/HostwrightCluster/ClusterCertificateTrust.swift#L172) | reuse | V3-21, V3-22 | Keep the CA's validated DER and cluster-generation identity. | [`ClusterCertificateTrustTests.testMalformedGenerationIdentityAuthorityAndLeafAreRejected`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterCertificateTrustTests.swift#L504) |
| [`ClusterCertificateTrustBundle`](../../Sources/HostwrightCluster/ClusterCertificateTrust.swift#L266) | reuse | V3-22, V3-51, V3-52 | Preserve canonical trust snapshots with sequential overlap and revoked leaves. | [`ClusterCertificateTrustTests.testTrustBundleRoundTripsCanonicallyAndRejectsTamperedDecode`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterCertificateTrustTests.swift#L346) |
| [`ClusterCertificatePeer`](../../Sources/HostwrightCluster/ClusterCertificateTrust.swift#L406) | reuse | V3-22 | Carry verified peer identity and public-key bindings into session authorization. | [`ClusterCertificateTrustTests.testTrustedPeerCertificateFeedsSessionCredentialWithoutPrivateMaterial`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterCertificateTrustTests.swift#L14) |
| [`ClusterMutualTLSVerifier`](../../Sources/HostwrightCluster/ClusterCertificateTrust.swift#L429) | reuse | V3-22, V3-52 | Verify the enrolled peer against the exact cluster CA, SAN, role, and revocation state. | [`ClusterCertificateTrustTests.testWrongAuthorityAndRevokedPeerFailClosed`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterCertificateTrustTests.swift#L233) |

### ClusterControlPlaneLease

| Public type | Disposition | Plan issue | Reason | Restored test for reuse |
|---|---|---|---|---|
| [`ClusterControlPlaneLeaseError`](../../Sources/HostwrightCluster/ClusterControlPlaneLease.swift#L5) | adapt | V3-20, V3-64 | Map lease failures to the single-writer SQLite authority and recovery rules. | — |
| [`ClusterControlPlaneLeaseContract`](../../Sources/HostwrightCluster/ClusterControlPlaneLease.swift#L38) | adapt | V3-20, V3-64 | Separate durable control authority bounds from leader-election semantics. | — |
| [`ClusterControlPlaneLeaseRecord`](../../Sources/HostwrightCluster/ClusterControlPlaneLease.swift#L44) | adapt | V3-20, V3-68 | Bind authority to the SQLite control store and preserve counter high-water marks on restore. | — |
| [`ClusterControlPlaneLeaseExpectation`](../../Sources/HostwrightCluster/ClusterControlPlaneLease.swift#L195) | adapt | V3-20 | Compare expected authority with the committed record inside the SQLite transaction. | — |
| [`ClusterControlPlaneLeaseProposal`](../../Sources/HostwrightCluster/ClusterControlPlaneLease.swift#L200) | adapt | V3-20, V3-64 | Collect and validate proposals at the single control writer instead of through peer elections. | — |
| [`ClusterControlPlaneLeaseAuthority`](../../Sources/HostwrightCluster/ClusterControlPlaneLease.swift#L323) | adapt | V3-20, V3-27 | Use the control store's cluster, epoch, and fence as the assignment authority. | — |
| [`ClusterControlPlaneLeaseDisposition`](../../Sources/HostwrightCluster/ClusterControlPlaneLease.swift#L345) | adapt | V3-20, V3-64 | Keep replay and rejection outcomes tied to durable control records. | — |
| [`ClusterControlPlaneLeaseDecisionEvaluator`](../../Sources/HostwrightCluster/ClusterControlPlaneLease.swift#L359) | adapt | V3-20, V3-64, V3-68 | Retain scalar and predecessor checks while removing multi-voter takeover from the shipped path. | — |
| [`ClusterControlPlaneLeaseWireContract`](../../Sources/HostwrightCluster/ClusterControlPlaneLease.swift#L576) | adapt | V3-20, V3-27 | Use strict record validation for persisted authority without treating lease proposals as link frames. | — |

### ClusterMembership

| Public type | Disposition | Plan issue | Reason | Restored test for reuse |
|---|---|---|---|---|
| [`ClusterMembershipError`](../../Sources/HostwrightCluster/ClusterMembership.swift#L4) | adapt | V3-24, V3-52 | Add explicit stale wall-clock token and learner-removal refusals. | — |
| [`ClusterID`](../../Sources/HostwrightCluster/ClusterMembership.swift#L40) | reuse | V3-20, V3-21 | Use the validated canonical cluster UUID for persisted and wire identities. | [`ClusterMembershipTests.testIDsRequireLowercaseCanonicalUUIDs`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterMembershipTests.swift#L6) |
| [`ClusterNodeID`](../../Sources/HostwrightCluster/ClusterMembership.swift#L79) | reuse | V3-20, V3-24 | Use the validated canonical UUID for each enrolled node. | [`ClusterMembershipTests.testIDsRequireLowercaseCanonicalUUIDs`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterMembershipTests.swift#L6) |
| [`ClusterMembershipEpoch`](../../Sources/HostwrightCluster/ClusterMembership.swift#L118) | reuse | V3-20, V3-52 | Keep a separate monotonic membership epoch to fence stale session authority. | [`ClusterMembershipTests.testBootstrapIsDeterministicAndReplayIsIdempotent`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterMembershipTests.swift#L14) |
| [`ClusterMemberRole`](../../Sources/HostwrightCluster/ClusterMembership.swift#L139) | reuse | V3-21, V3-24 | Keep the existing voter and learner roles for the control and workers. | [`ClusterMembershipTests.testJoinAddsLearnerAndRejectsStaleDuplicateTokensAndIdentityReuse`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterMembershipTests.swift#L49) |
| [`ClusterMembershipMember`](../../Sources/HostwrightCluster/ClusterMembership.swift#L144) | adapt | V3-20, V3-24 | Replace peer/client endpoint pairs with the control-initiated worker endpoint and bound node name. | — |
| [`ClusterMembershipPolicy`](../../Sources/HostwrightCluster/ClusterMembership.swift#L200) | adapt | V3-21, V3-52 | Apply the fixed one-control-voter policy and refuse worker promotion. | — |
| [`ClusterJoinToken`](../../Sources/HostwrightCluster/ClusterMembership.swift#L241) | adapt | V3-24 | Replace expiration by membership epoch with a persisted wall-clock deadline and bind enrollment to the node name. | — |
| [`ClusterJoinRequest`](../../Sources/HostwrightCluster/ClusterMembership.swift#L333) | adapt | V3-24 | Bind the presented enrollment and worker keys to the D8 verified handshake. | — |
| [`ClusterMembershipIntent`](../../Sources/HostwrightCluster/ClusterMembership.swift#L381) | adapt | V3-20, V3-24, V3-52 | Persist current membership, consumed tokens, and applied operations through the control ledger. | — |
| [`ClusterMembershipOperation`](../../Sources/HostwrightCluster/ClusterMembership.swift#L494) | adapt | V3-52 | Add learner removal while keeping voter changes outside the v0.0.3 operator path. | — |
| [`ClusterMembershipChange`](../../Sources/HostwrightCluster/ClusterMembership.swift#L502) | adapt | V3-52 | Represent an exact existing learner identity as the removal target. | — |
| [`ClusterMembershipTransitionRecord`](../../Sources/HostwrightCluster/ClusterMembership.swift#L597) | adapt | V3-20, V3-52 | Record the committed learner removal and new epoch in the durable membership journal. | — |
| [`ClusterMembershipRecoveryRecord`](../../Sources/HostwrightCluster/ClusterMembership.swift#L665) | adapt | V3-64, V3-68 | Bind recovery progress to the transactional control store and restored authority. | — |
| [`ClusterMembershipPlan`](../../Sources/HostwrightCluster/ClusterMembership.swift#L746) | adapt | V3-24, V3-52 | Include the new join and learner-removal semantics in the canonical plan. | — |
| [`ClusterMembershipApplyDisposition`](../../Sources/HostwrightCluster/ClusterMembership.swift#L954) | reuse | V3-20, V3-52 | Preserve the distinction between an applied plan and an exact replay. | [`ClusterMembershipTests.testBootstrapIsDeterministicAndReplayIsIdempotent`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterMembershipTests.swift#L14) |
| [`ClusterMembershipApplyResult`](../../Sources/HostwrightCluster/ClusterMembership.swift#L959) | adapt | V3-20, V3-52 | Use the outcome at the durable membership boundary with the adapted intent. | — |
| [`ClusterMembershipPlanner`](../../Sources/HostwrightCluster/ClusterMembership.swift#L969) | adapt | V3-24, V3-52 | Add wall-clock join admission and an exact learner-removal transition. | — |

### ClusterMutationFence

| Public type | Disposition | Plan issue | Reason | Restored test for reuse |
|---|---|---|---|---|
| [`ClusterMutationFenceError`](../../Sources/HostwrightCluster/ClusterMutationFence.swift#L5) | adapt | V3-27 | Report missing or inconsistent assignment authority in addition to existing scalar failures. | — |
| [`ClusterMutationFenceContract`](../../Sources/HostwrightCluster/ClusterMutationFence.swift#L16) | adapt | V3-27, V3-56 | Retain bounded typed proof decoding and assign a compatible wire version for assignment authority. | — |
| [`ClusterMutationAuthorityDigestKind`](../../Sources/HostwrightCluster/ClusterMutationFence.swift#L24) | adapt | V3-27 | Distinguish assignment-authority digests from predecessor and lease digests. | — |
| [`ClusterMutationAuthoritySnapshot`](../../Sources/HostwrightCluster/ClusterMutationFence.swift#L36) | adapt | V3-27 | Derive worker mutation authority from the durable assignment generation and fencing token. | — |
| [`ClusterMutationProofSource`](../../Sources/HostwrightCluster/ClusterMutationFence.swift#L191) | adapt | V3-27 | Bind execution proofs to the assignment source needed by the worker. | — |
| [`ClusterMutationSourceRecordBinding`](../../Sources/HostwrightCluster/ClusterMutationFence.swift#L200) | adapt | V3-27 | Bind the source to plan, assignment, and node identity for execution. | — |
| [`ClusterMutationProof`](../../Sources/HostwrightCluster/ClusterMutationFence.swift#L239) | adapt | V3-27 | Keep digest and mutation identity checks while supporting the new assignment proof source. | — |
| [`ClusterMutationFenceRejection`](../../Sources/HostwrightCluster/ClusterMutationFence.swift#L423) | adapt | V3-27 | Classify stale assignment generations and invalid worker bindings. | — |
| [`ClusterMutationFenceDecision`](../../Sources/HostwrightCluster/ClusterMutationFence.swift#L455) | adapt | V3-27 | Carry worker-specific execution, replay, and refusal outcomes. | — |
| [`ClusterMutationFenceEvaluator`](../../Sources/HostwrightCluster/ClusterMutationFence.swift#L467) | adapt | V3-27, V3-68 | Reuse its pure fail-closed comparison inside the durable worker fencing and recovery path. | — |
| [`ClusterMutationFenceWireContract`](../../Sources/HostwrightCluster/ClusterMutationFence.swift#L592) | adapt | V3-27, V3-56 | Extend the strict typed decoder for the assignment proof format. | — |

### ClusterNodeAgentTransportSecurity

| Public type | Disposition | Plan issue | Reason | Restored test for reuse |
|---|---|---|---|---|
| [`ClusterNodeAgentTransportSecurityError`](../../Sources/HostwrightCluster/ClusterNodeAgentTransportSecurity.swift#L4) | adapt | V3-22, V3-52 | Map peer and handoff checks to link establishment and live-session fencing. | — |
| [`ClusterNodeAgentTransportSecuritySide`](../../Sources/HostwrightCluster/ClusterNodeAgentTransportSecurity.swift#L47) | reuse | V3-22 | Keep dialer/client and listener/server certificate role bindings. | [`ClusterNodeAgentTransportSecurityTests.testAdapterRejectsClusterNodeRoleAndStaleLocalIdentityBindings`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterNodeAgentTransportSecurityTests.swift#L161) |
| [`ClusterNodeAgentTransportIdentity`](../../Sources/HostwrightCluster/ClusterNodeAgentTransportSecurity.swift#L72) | reuse | V3-22 | Use the opaque Security identity and certificate chain to configure mutually authenticated TLS. | [`ClusterNodeAgentTransportSecurityTests.testAdaptersBindOpaqueLifecycleIdentityPeerCertificateAndSessionHandoff`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterNodeAgentTransportSecurityTests.swift#L14) |
| [`ClusterNodeAgentAuthenticatedClient`](../../Sources/HostwrightCluster/ClusterNodeAgentTransportSecurity.swift#L93) | adapt | V3-22, V3-50 | Bind the authenticated caller and session result to the live worker link. | — |
| [`ClusterNodeAgentTransportSecurityAdapter`](../../Sources/HostwrightCluster/ClusterNodeAgentTransportSecurity.swift#L132) | adapt | V3-22, V3-52 | Apply its existing identity and peer validation to the chosen listener and dialer. | — |

### ClusterRemoteOperationAdmission

| Public type | Disposition | Plan issue | Reason | Restored test for reuse |
|---|---|---|---|---|
| [`ClusterRemoteOperationAdmissionError`](../../Sources/HostwrightCluster/ClusterRemoteOperationAdmission.swift#L5) | adapt | V3-27, V3-50 | Report invalid assignment inputs and identify authorization failures before execution. | — |
| [`ClusterRemoteOperationContract`](../../Sources/HostwrightCluster/ClusterRemoteOperationAdmission.swift#L16) | adapt | V3-27, V3-56 | Define strict assignment admission bounds and operation envelope versioning. | — |
| [`ClusterRemoteOperationKind`](../../Sources/HostwrightCluster/ClusterRemoteOperationAdmission.swift#L24) | adapt | V3-27, V3-50 | Bind admission to PlanSlice, ExecuteSlice, and the supported cluster operations. | — |
| [`ClusterRemoteOperationIntent`](../../Sources/HostwrightCluster/ClusterRemoteOperationAdmission.swift#L36) | adapt | V3-27 | Bind the intended effect to an exact node plan and assignment generation. | — |
| [`ClusterRemoteOperationPayloadDisclosure`](../../Sources/HostwrightCluster/ClusterRemoteOperationAdmission.swift#L93) | reuse | V3-50, V3-55 | Keep audit admission disclosure limited to digests. | [`ClusterRemoteOperationAdmissionTests.testExactAuthorityProducesDigestOnlyAdmissionRecord`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterRemoteOperationAdmissionTests.swift#L9) |
| [`ClusterRemoteOperationAdmissionRecord`](../../Sources/HostwrightCluster/ClusterRemoteOperationAdmission.swift#L99) | adapt | V3-27, V3-55 | Record assignment-specific admission while keeping the result separate from proof of delivery. | — |
| [`ClusterRemoteOperationAdmissionRejection`](../../Sources/HostwrightCluster/ClusterRemoteOperationAdmission.swift#L114) | adapt | V3-27, V3-50 | Classify rejected worker assignments and admission decisions before mutation. | — |
| [`ClusterRemoteOperationAdmissionDecision`](../../Sources/HostwrightCluster/ClusterRemoteOperationAdmission.swift#L133) | adapt | V3-27, V3-50 | Use the revised admission record and rejection cases in the worker. | — |
| [`ClusterRemoteOperationAdmissionEvaluator`](../../Sources/HostwrightCluster/ClusterRemoteOperationAdmission.swift#L140) | adapt | V3-27, V3-50 | Compare exact assignment, session, generation, and permission records from durable adapters. | — |
| [`ClusterRemoteOperationIntentWireContract`](../../Sources/HostwrightCluster/ClusterRemoteOperationAdmission.swift#L241) | adapt | V3-27, V3-56 | Retain canonical decoder validation while admitting the versioned assignment intent. | — |

### ClusterReplicatedDesiredState

| Public type | Disposition | Plan issue | Reason | Restored test for reuse |
|---|---|---|---|---|
| [`ClusterReplicatedDesiredStateError`](../../Sources/HostwrightCluster/ClusterReplicatedDesiredState.swift#L5) | adapt | V3-27, V3-65 | Express failures of single-writer assignment snapshots and worker recovery. | — |
| [`ClusterReplicatedDesiredStateContract`](../../Sources/HostwrightCluster/ClusterReplicatedDesiredState.swift#L36) | adapt | V3-27, V3-56 | Specify bounds and versioning for an assignment snapshot rather than quorum exchange. | — |
| [`ClusterReplicatedProjectID`](../../Sources/HostwrightCluster/ClusterReplicatedDesiredState.swift#L42) | reuse | V3-27, V3-85 | Preserve the canonical project identity within assignment snapshots. | [`ClusterReplicatedDesiredStateTests.testRecordBoundaryRejectsInvalidIdentifiersDigestsCountersAndFence`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterReplicatedDesiredStateTests.swift#L382) |
| [`ClusterReplicatedDesiredState`](../../Sources/HostwrightCluster/ClusterReplicatedDesiredState.swift#L74) | adapt | V3-27, V3-85 | Publish control-owned assignments with node placement and generation bindings. | — |
| [`ClusterReplicatedDesiredStateExpectation`](../../Sources/HostwrightCluster/ClusterReplicatedDesiredState.swift#L268) | adapt | V3-27 | Compare assignment predecessor and generation expectations in durable state. | — |
| [`ClusterReplicatedDesiredStateProposal`](../../Sources/HostwrightCluster/ClusterReplicatedDesiredState.swift#L273) | adapt | V3-27 | Represent control-issued assignment publication without quorum. | — |
| [`ClusterReplicatedDesiredStateAuthority`](../../Sources/HostwrightCluster/ClusterReplicatedDesiredState.swift#L399) | adapt | V3-27, V3-68 | Bind snapshot publication to the current control store and membership epoch. | — |
| [`ClusterReplicatedDesiredStatePublication`](../../Sources/HostwrightCluster/ClusterReplicatedDesiredState.swift#L421) | adapt | V3-27 | Distinguish accepted assignment snapshots from rejected or replayed proposals. | — |
| [`ClusterReplicatedDesiredStatePublisher`](../../Sources/HostwrightCluster/ClusterReplicatedDesiredState.swift#L428) | adapt | V3-27, V3-64 | Use the control SQLite store to validate and persist published assignments. | — |
| [`ClusterReplicatedDesiredStateReplicaDisposition`](../../Sources/HostwrightCluster/ClusterReplicatedDesiredState.swift#L553) | adapt | V3-27, V3-65 | Classify exact replay, advanced assignment, and stale worker updates. | — |
| [`ClusterReplicatedDesiredStateReplica`](../../Sources/HostwrightCluster/ClusterReplicatedDesiredState.swift#L559) | adapt | V3-27, V3-65 | Use monotonic snapshot checks when accepting assignments into the worker ledger. | — |
| [`ClusterReplicatedDesiredStateWireContract`](../../Sources/HostwrightCluster/ClusterReplicatedDesiredState.swift#L635) | adapt | V3-27, V3-56 | Decode the new assignment snapshot format with closed and bounded fields. | — |

### ClusterSession

| Public type | Disposition | Plan issue | Reason | Restored test for reuse |
|---|---|---|---|---|
| [`ClusterSessionError`](../../Sources/HostwrightCluster/ClusterSession.swift#L5) | reuse | V3-22, V3-52 | Preserve rejection of invalid and replayed session proofs. | [`ClusterSessionTests.testInvalidProofIsConsumedAndReplayFailsClosed`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterSessionTests.swift#L515) |
| [`ClusterSessionContract`](../../Sources/HostwrightCluster/ClusterSession.swift#L76) | reuse | V3-22, V3-56 | Keep bounded pending challenges in the inner session protocol. | [`ClusterSessionTests.testPendingChallengeCapacityIsBoundedAndExpiredEntriesRecover`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterSessionTests.swift#L693) |
| [`ClusterSessionX509CredentialBinding`](../../Sources/HostwrightCluster/ClusterSession.swift#L88) | reuse | V3-22 | Bind credential identity and both certificate fingerprints into session authorization. | [`ClusterCertificateTrustTests.testTrustedPeerCertificateFeedsSessionCredentialWithoutPrivateMaterial`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterCertificateTrustTests.swift#L14) |
| [`ClusterSessionCredentialProvenance`](../../Sources/HostwrightCluster/ClusterSession.swift#L151) | adapt | V3-22, V3-50 | Require X.509 provenance on the live enrolled link and isolate the legacy path. | — |
| [`ClusterSessionCredential`](../../Sources/HostwrightCluster/ClusterSession.swift#L156) | adapt | V3-22, V3-50 | Use verified X.509 credentials for the link and keep legacy credentials out of it. | — |
| [`ClusterSessionCredentialCatalog`](../../Sources/HostwrightCluster/ClusterSession.swift#L336) | reuse | V3-22, V3-52 | Revalidate the catalog's exact certificate binding against the admitted session. | [`ClusterCertificateTrustTests.testTrustedPeerCertificateFeedsSessionCredentialWithoutPrivateMaterial`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterCertificateTrustTests.swift#L14) |
| [`ClusterSessionCredentialGenerationAuthorizing`](../../Sources/HostwrightCluster/ClusterSession.swift#L372) | adapt | V3-51, V3-52 | Back generation authorization with the durable membership and revocation state. | — |
| [`ClusterSessionChallenge`](../../Sources/HostwrightCluster/ClusterSession.swift#L379) | reuse | V3-22 | Reuse the nonce, expiration, and context-bound challenge inside the authenticated link. | [`ClusterSessionTests.testChallengeExpiryAndContextAreDeterministic`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterSessionTests.swift#L550) |
| [`ClusterSessionProof`](../../Sources/HostwrightCluster/ClusterSession.swift#L480) | reuse | V3-22 | Reuse its canonical proof of the authenticated peer's exact challenge. | [`ClusterSessionTests.testCanonicalChallengeProofAuthenticatesAndValidates`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterSessionTests.swift#L8) |
| [`ClusterSessionWireContract`](../../Sources/HostwrightCluster/ClusterSession.swift#L515) | reuse | V3-22, V3-56 | Keep the inner session codec under the distinct outer link framing. | [`ClusterSessionTests.testCanonicalChallengeProofAuthenticatesAndValidates`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterSessionTests.swift#L8) |
| [`ClusterSessionState`](../../Sources/HostwrightCluster/ClusterSession.swift#L580) | reuse | V3-22, V3-52 | Preserve active, closed, expired, and fenced session states independently of node conditions. | [`ClusterSessionTests.testMembershipEpochAndCredentialRevocationFenceSessions`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterSessionTests.swift#L603) |
| [`ClusterAuthenticatedSession`](../../Sources/HostwrightCluster/ClusterSession.swift#L587) | reuse | V3-22, V3-50 | Carry the authenticated peer, epoch, fence, and expiration in the link session. | [`ClusterSessionTests.testCanonicalChallengeProofAuthenticatesAndValidates`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterSessionTests.swift#L8) |
| [`ClusterSessionHandoff`](../../Sources/HostwrightCluster/ClusterSession.swift#L686) | reuse | V3-49, V3-50 | Keep the strict credential-free handoff and reauthorize it at the consumer boundary. | [`ClusterSessionTests.testConsumerHandoffIsStrictCredentialFreeAndReauthorized`](https://github.com/hostwright/hostwright/blob/9683d8c783e6cd1522b87143109cc139cda2defd/Tests/HostwrightClusterTests/ClusterSessionTests.swift#L61) |
| [`ClusterSessionTransitionResult`](../../Sources/HostwrightCluster/ClusterSession.swift#L789) | adapt | V3-22, V3-52 | Use fenced-session transitions to close streams owned by the live link. | — |
| [`ClusterSessionAuthorizing`](../../Sources/HostwrightCluster/ClusterSession.swift#L808) | adapt | V3-22, V3-50 | Supply link-bound session authorization and recheck authority before mutation. | — |
| [`ClusterSessionHandoffAuthorizing`](../../Sources/HostwrightCluster/ClusterSession.swift#L817) | adapt | V3-49, V3-50 | Reauthorize helper handoffs against the exact receiving daemon session. | — |
| [`ClusterSessionAuthority`](../../Sources/HostwrightCluster/ClusterSession.swift#L825) | adapt | V3-22, V3-52, V3-73 | Reuse challenge and revocation decisions while binding sessions to live streams and version-skew restrictions. | — |

### ManagedEtcdArtifact

| Public type | Disposition | Plan issue | Reason | Restored test for reuse |
|---|---|---|---|---|
| [`ManagedEtcdPlatform`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L6) | retire | V3-20 | The SQLite control store needs no managed-etcd platform catalog. | — |
| [`ManagedEtcdArchiveKind`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L11) | retire | V3-20 | The control store ships without a managed-etcd archive. | — |
| [`ManagedEtcdError`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L16) | retire | V3-20 | Managed-etcd errors remain development-only outside the SQLite control path. | — |
| [`ManagedEtcdArtifact`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L68) | retire | V3-20 | The SQLite control path does not install a managed-etcd artifact. | — |
| [`ManagedEtcdArchiveEntryType`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L182) | retire | V3-20 | The SQLite control path does not unpack a managed-etcd archive. | — |
| [`ManagedEtcdArchiveEntry`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L190) | retire | V3-20 | Managed-etcd archive entries stay outside cluster bootstrap. | — |
| [`ManagedEtcdArchiveValidator`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L202) | retire | V3-20 | Archive validation applies only to deferred managed-etcd packaging. | — |
| [`ManagedEtcdVerifiedArchive`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L272) | retire | V3-20 | Cluster bootstrap consumes the SQLite store rather than a verified etcd bundle. | — |
| [`ManagedEtcdArtifactVerifier`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L294) | retire | V3-20 | Artifact checks remain with the deferred managed-etcd distribution path. | — |
| [`ManagedEtcdProvenanceRecord`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L340) | retire | V3-20 | The SQLite-backed cluster ships without managed-etcd provenance. | — |
| [`ManagedEtcdLayout`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L431) | retire | V3-20 | The cluster store uses existing Hostwright state paths instead of the managed-etcd layout. | — |
| [`ManagedEtcdLayoutPreparationReport`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L546) | retire | V3-20 | Store initialization needs SQLite migration results instead of etcd layout preparation. | — |
| [`ManagedEtcdInstallPlan`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L556) | retire | V3-20 | The control Mac initializes a store without installing a managed-etcd service. | — |
| [`ManagedEtcdInitialClusterState`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L583) | retire | V3-20 | Single-control membership replaces initial managed-etcd topology. | — |
| [`ManagedEtcdSupervisedProcessConfiguration`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L588) | retire | V3-25 | hostwrightd supervises the node link without starting an etcd process. | — |
| [`ManagedEtcdSnapshotPlan`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L741) | retire | V3-68 | Use the existing SQLite backup and restore mechanism for control state. | — |
| [`ManagedEtcdRestorePlan`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L755) | retire | V3-68 | Control recovery uses the SQLite store recovery hold. | — |
| [`ManagedEtcdSnapshotPlanner`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L771) | retire | V3-68 | SQLite recovery owns planning for this release. | — |
| [`ManagedEtcdCleanupPlan`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L815) | retire | V3-52 | Worker reset targets its cluster-owned credentials and resources without an etcd directory. | — |
| [`ManagedEtcdCleanupReport`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift#L862) | retire | V3-52 | Worker reset reports its exact owned-resource cleanup. | — |

### ManagedEtcdRuntime

| Public type | Disposition | Plan issue | Reason | Restored test for reuse |
|---|---|---|---|---|
| [`ManagedEtcdInstallReport`](../../Sources/HostwrightCluster/ManagedEtcdRuntime.swift#L5) | retire | V3-20 | No etcd install result is part of control initialization. | — |
| [`ManagedEtcdInstaller`](../../Sources/HostwrightCluster/ManagedEtcdRuntime.swift#L27) | retire | V3-20 | A single SQLite control store replaces managed-etcd installation. | — |
| [`ManagedEtcdSnapshotExecutionReport`](../../Sources/HostwrightCluster/ManagedEtcdRuntime.swift#L222) | retire | V3-68 | Use control-store backup evidence instead of etcd snapshot execution results. | — |
| [`ManagedEtcdRestoreExecutionReport`](../../Sources/HostwrightCluster/ManagedEtcdRuntime.swift#L241) | retire | V3-68 | Use SQLite restore and worker reconciliation evidence. | — |
| [`ManagedEtcdSnapshotExecutor`](../../Sources/HostwrightCluster/ManagedEtcdRuntime.swift#L289) | retire | V3-68 | SQLite backup and recovery replace managed-etcd snapshot execution. | — |
| [`ManagedEtcdMemberState`](../../Sources/HostwrightCluster/ManagedEtcdRuntime.swift#L511) | retire | V3-26 | Node readiness describes enrolled worker health instead of etcd membership. | — |
| [`ManagedEtcdMemberStatus`](../../Sources/HostwrightCluster/ManagedEtcdRuntime.swift#L522) | retire | V3-26 | Use worker condition and capacity for node status. | — |
| [`ManagedEtcdMemberSupervisor`](../../Sources/HostwrightCluster/ManagedEtcdRuntime.swift#L538) | retire | V3-25 | hostwrightd manages worker links and the network helper without supervising etcd. | — |

### NodeAgentTransport

| Public type | Disposition | Plan issue | Reason | Restored test for reuse |
|---|---|---|---|---|
| [`ClusterNodeAgentTransportError`](../../Sources/HostwrightCluster/NodeAgentTransport.swift#L6) | retire | V3-22 | Keep legacy subprocess transport failures within the AF_UNIX path. | — |
| [`ClusterNodeAgentTransportContract`](../../Sources/HostwrightCluster/NodeAgentTransport.swift#L48) | retire | V3-22 | Keep the local v1 label and 45 KiB cap separate from the new worker link. | — |
| [`ClusterNodeAgentRequest`](../../Sources/HostwrightCluster/NodeAgentTransport.swift#L58) | retire | V3-22, V3-27 | Use versioned remote link and assignment frames in place of local subprocess requests. | — |
| [`ClusterNodeAgentResponseStatus`](../../Sources/HostwrightCluster/NodeAgentTransport.swift#L140) | retire | V3-22, V3-27 | Report worker-link and assignment outcomes through their own contract. | — |
| [`ClusterNodeAgentResponse`](../../Sources/HostwrightCluster/NodeAgentTransport.swift#L145) | retire | V3-22, V3-27 | Use remote link responses without carrying the local subprocess envelope. | — |
| [`ClusterNodeAgentWireContract`](../../Sources/HostwrightCluster/NodeAgentTransport.swift#L239) | retire | V3-22, V3-56 | Keep the local socket codec and the new bounded remote codec distinct. | — |
| [`ClusterNodeAgentSubprocessConfiguration`](../../Sources/HostwrightCluster/NodeAgentTransport.swift#L282) | retire | V3-25 | The worker runs the normal daemon role instead of a launched node-agent subprocess. | — |
| [`ClusterNodeAgentLocalTransport`](../../Sources/HostwrightCluster/NodeAgentTransport.swift#L335) | retire | V3-22, V3-49 | Keep the AF_UNIX subprocess implementation outside the shipped worker link. | — |
