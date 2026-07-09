# Apple Silicon Control-Plane Direction

Status: Phase 40 direction decision.

Phase 40 decides the platform direction after the compatibility, multi-host, scheduler, accelerator, benchmark, and beta-readiness work. It does not implement cluster behavior, remote mutation, CRI, Kubernetes behavior, cloud control, accelerator access, scheduler APIs, runtime mutation, state replication, networking providers, release tags, or GitHub Releases.

## Decision

Hostwright core remains a single-host Apple silicon control plane through the beta path and first supported release work.

Experimental platform expansion should not be added to current core. If later pursued, it should be a separate approved prototype, plugin, control-plane project, or separate repository with its own threat model, state authority, conformance plan, and disposable proof path.

This keeps the current product centered on one local Mac, explicit local state paths, local policy, local diagnostics, `RuntimeAdapter` runtime boundaries, and human-confirmed mutation gates.

## Evidence Reviewed

- Phase 27 found no supported Apple-container path for Apple GPU, ANE, Metal, Core ML, MLX, or PyTorch MPS acceleration inside managed Linux containers.
- Phase 29 rejected current-core CRI, Kubernetes node behavior, Docker API, Testcontainers, full Compose parity, attach, exec, log-follow, and port-forward compatibility because those contracts require broader protocol, lifecycle, stream, state, and network semantics.
- Phase 30 kept current core single-host because multi-host work requires identity, membership, transport trust, state authority, failure recovery, audit, revocation, and scheduler policy.
- Phase 31 added only local advisory scheduling. It does not reserve capacity, place workloads automatically, expose a scheduler API, schedule accelerators, or place work on remote hosts.
- Phase 36 benchmark work records dry-run or fixture-backed methodology only. It does not publish benchmark numbers or prove production capacity.
- Phase 39 keeps beta release claims blocked until clean-checkout, CI, docs, examples, state, security, operations, telemetry, and support evidence exist.

## Direction Table

| Question | Decision | Reason | Reconsideration Gate |
| --- | --- | --- | --- |
| Single-host core | Accept | The existing safety model depends on one local permission envelope, explicit local state, local policy, and confirmed mutation gates. | Continue preserving local-only defaults and narrow mutation gates. |
| Kubernetes-class Apple silicon control plane in current core | Reject | Cluster behavior needs API authority, node identity, scheduler state, networking, storage, lifecycle, health, and recovery semantics beyond the current product boundary. | Separate product decision, architecture record, threat model, conformance plan, and maintainer approval. |
| Multi-host inside current core | Reject | Remote hosts require identity, enrollment, trust, revocation, transport security, state authority, audit, and failure-domain handling. | Separate prototype or project with pairing, state-authority, recovery, and proof design. |
| CRI compatibility in current core | Reject | CRI requires kubelet-facing runtime and image services, pod sandbox behavior, status fidelity, logs, exec, attach, and port-forward semantics. | Separate exact-version CRI target, conformance matrix, disposable proof, and maintainer approval. |
| Docker API or full Compose parity in current core | Reject | Existing clients expect broad daemon, stream, image, network, volume, lifecycle, and schema semantics that Hostwright does not expose. | Separate API subset proposal with client contract and tests. |
| Cloud control plane in current core | Reject | Hosted authority changes credentials, privacy, telemetry, audit, data retention, support, and product positioning. | Separate product approval, security review, data model, privacy policy, and support plan. |
| Accelerator-aware scheduling | Reject for current core | No proved accelerator execution path, measured capacity model, or policy gate exists for managed container workloads. | Official supported access path, local proof, threat model, measured capacity model, and maintainer approval. |
| Local advisory scheduling | Keep | Deterministic recommendations are useful without taking control of placement or resources. | Keep advisory-only until separate placement/reservation proof exists. |
| Platform expansion path | Split | Separate work avoids weakening current single-host safety assumptions. | Approved issue or repository with boundaries, tests, docs, and release claims scoped to evidence. |

## Current Product Direction

The beta and first supported release path should prioritize:

- source install and release evidence;
- local manifest validation, planning, status, events, diagnostics, and bounded logs;
- explicit local state paths and migration safety;
- narrow Hostwright-owned runtime mutation through `RuntimeAdapter`;
- cleanup and recovery hardening;
- documentation accuracy and operator trust;
- local policy, redaction, audit, and confirmation gates.

The core roadmap should not spend implementation budget on cluster control, external API compatibility, remote placement, cloud authority, or accelerator scheduling until the current local product has a stable release surface.

## Evidence Required Before Platform Expansion

Any later platform-expansion issue must define:

- exact product placement: core, plugin, prototype, control-plane project, or separate repository;
- target protocol or behavior contract and explicit non-goals;
- state authority, locking, idempotency, migration, backup, recovery, and rollback model;
- host identity, enrollment, authorization, revocation, transport, and audit model;
- policy behavior for lifecycle, networking, mounts, images, secrets, cleanup, diagnostics, and untrusted input;
- resource and scheduling model, including measured capacity and failure-domain assumptions;
- local disposable proof path that avoids non-Hostwright resources, broad cleanup, and image pulls unless separately approved;
- public documentation rules that avoid broad support or compatibility claims.

## Rejected Current-Core Claims

Current core does not include:

- Kubernetes-class control-plane behavior;
- CRI, Docker API, or full Compose compatibility;
- multi-host orchestration, remote host agents, remote placement, peer discovery, state replication, or membership service;
- cloud control, hosted scheduler, hosted audit log, hosted diagnostics, or remote policy distribution;
- accelerator access, accelerator-aware scheduling, host-native accelerator helper, or GPU/ANE/Metal/Core ML/MLX/PyTorch MPS behavior.

## Follow-Up Policy

Follow-up issues may be opened only for evidence-backed work in the chosen direction. They should improve local single-host quality first unless the maintainer explicitly approves a separate experimental platform track.
