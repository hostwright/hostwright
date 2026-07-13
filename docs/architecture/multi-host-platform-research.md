# Multi-Host Apple Silicon Platform Research

> **Historical research, promoted to implementation:** v0.0.2 Phase 11 owns managed-etcd multi-Mac consensus, node agents, fencing, remote operations/storage/discovery, failover, upgrades, and disaster recovery. The current build remains single-host; that is a present limitation, not a permanent non-goal.

Status: Phase 30 research-only decision record.

Phase 30 records the boundary for multi-host Apple silicon platform work. It does not implement multi-host orchestration, remote mutation, host agents, state replication, membership, scheduler APIs, cloud control plane, DNS, tunnels, discovery, transport, certificates, or runtime behavior.

## Decision

Hostwright core stays single-host. Multi-host Apple silicon orchestration is deferred out of current core scope and should be explored only as a separately approved prototype, plugin, control plane, or separate project after a threat model and state-authority design exist.

This keeps the current product centered on one local Mac, one explicit local state database path, one local runtime boundary, local deterministic policy, and human-confirmed mutation gates.

## Reviewed Evidence

- Hostwright's current architecture is local and single-host. Runtime behavior goes through local `RuntimeAdapter` implementations, state uses explicit local SQLite paths, the foreground daemon does not mutate runtime state, and networking remains localhost-first.
- macOS local-network discovery is a user-visible privacy boundary. Even before trust decisions, a multi-host design would need explicit per-host permission and a stable program identity story.
- Bonjour and DNS-SD can discover and resolve services, but discovery is not trust. Hostwright would still need peer identity, authorization, revocation, and audit semantics.
- Apple-backed device attestation exists for managed-device workflows, but that path depends on Secure Enclave-backed declarations, Apple attestation services, ACME or MDM-style enrollment, and a relying-party service. That is materially outside the current local CLI scope.
- Distributed state authority is a different system class from Hostwright's local SQLite ledger. Consensus and replicated-state-machine designs introduce leader election, quorum, membership changes, replicated logs, partition behavior, and quorum-loss recovery.
- Multi-host placement requires failure domains, host identity, heartbeats, capacity facts, policy, port availability, image policy, and unavailable-host handling. That is a scheduler/control-plane problem, not an incremental extension of the current reconciler.
- Remote control expands the threat model to compromised peers, delegated credentials, transport authentication, certificate lifecycle, remote audit, blast radius, and recovery from partial cross-host mutation.

## Decisions

| Path | Decision | Reason | Required Before Reconsidering |
| --- | --- | --- | --- |
| Keep current core single-host | Accept | The existing safety model depends on one local permission envelope, explicit local state paths, local policy, and explicit mutation confirmation. | Continue preserving single-host defaults in core behavior. |
| Local LAN discovery | Reject from current core | Discovery without trust creates ambiguous peer selection and macOS local-network permission prompts without solving authorization. | Separate prototype with explicit permission, pairing, revocation, and no DNS/tunnel assumptions. |
| Peer-to-peer multi-host control | Reject from current core | Peer control requires identity, authorization, transport security, state authority, audit, and failure recovery not present in current core. | Threat model, pairing design, certificate lifecycle, recovery model, and maintainer approval. |
| Replicated state database | Reject from current core | The current explicit SQLite state path is single-writer local state. Replication would require consensus, quorum, membership, snapshots, restore, and partition behavior. | State-authority design, replicated log or external database decision, migration policy, and failure tests. |
| Remote control plane | Reject from current core | A hosted or remote authority changes product positioning, credentials, telemetry, audit, privacy, and support boundaries. | Separate product decision, security review, data model, privacy policy, and maintainer approval. |
| Plugin or separate project | Defer as preferred exploration path | Multi-host can be explored without weakening current single-host core assumptions. | Approved issue, explicit integration contract, no hidden remote mutation, and compatibility with local policy boundaries. |
| Scheduler implications | Defer to Phase 31 local advisory model | Phase 31 can score local constraints, but it must not imply cluster scheduling, remote placement, or multi-host mutation. | Separate multi-host scheduler design with host identity, failure domains, leases, capacity, and policy. |

## Threat Model Topics

Any future prototype must cover:

- host identity and enrollment;
- membership changes and revocation;
- peer authentication and encrypted transport;
- authorization for observation, planning, mutation, cleanup, diagnostics, and secret resolution;
- state authority, leader election, quorum, snapshots, restore, and partition behavior;
- heartbeat, lease, offline, degraded, and split-brain handling;
- failure domains and scheduler placement semantics;
- local-network privacy prompts and operator consent on every participating Mac;
- cloud boundary, telemetry boundary, and data retention if a control plane is proposed;
- audit trail, redaction, diagnostics, and manual recovery for cross-host operations.

## Current Boundary

Current Hostwright core remains:

- one local Mac;
- explicit local state database paths only;
- local `RuntimeAdapter` observation and narrow mutation;
- foreground daemon observation/planning without runtime mutation;
- localhost-first networking;
- local deterministic policy;
- no DNS, tunnel, cloud control plane, peer discovery, state replication, remote host agent, multi-host scheduler, or multi-host cleanup.

## Prototype Gate

Prototype requires separate maintainer approval before any code implementation.

A prototype proposal must define:

- core, plugin, control-plane, or separate-project placement;
- exact trusted-computing boundary and user consent flow;
- local-only or remote authority model;
- state-authority and failure-recovery model;
- supported and rejected host operations;
- transport security and credential lifecycle;
- interaction with Phase 32 policy and Phase 31 scheduler work;
- disposable proof plan that avoids non-Hostwright resources, image pulls, broad cleanup, and hidden remote mutation.

## Sources

- Apple local network privacy: <https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy>
- Apple Bonjour: <https://developer.apple.com/bonjour/>
- Apple Bonjour overview: <https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/NetServices/Introduction.html>
- Apple TLS security: <https://support.apple.com/guide/security/tls-security-sec100a75d12/web>
- Apple Managed Device Attestation: <https://support.apple.com/guide/security/managed-device-attestation-sec8a37b4cb2/web>
- Apple ACME deployment payload: <https://support.apple.com/guide/deployment/automated-certificate-management-environment-depb95c66a07/web>
- SQLite appropriate uses: <https://sqlite.org/whentouse.html>
- Raft consensus paper: <https://raft.github.io/raft.pdf>
- ZooKeeper paper: <https://www.usenix.org/legacy/event/atc10/tech/full_papers/Hunt.pdf>
- etcd security model: <https://etcd.io/docs/v3.6/op-guide/security/>
- Kubernetes leases: <https://kubernetes.io/docs/concepts/architecture/leases/>
- Kubernetes node model: <https://kubernetes.io/docs/concepts/architecture/nodes/>
- Kubernetes scheduler: <https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/>
- Kubernetes topology spread constraints: <https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/>
