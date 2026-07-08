# External Orchestration Compatibility Research

Status: Phase 29 research-only decision record.

Phase 29 records the current boundary for CRI, Kubernetes, Docker API, Docker Compose, attach, forwarding, scheduler, lifecycle, networking, identity, and state compatibility. It does not implement a shim, node agent, external API, scheduler behavior, runtime mutation, image pull, provider integration, or compatibility prototype.

## Reviewed Evidence

- Kubernetes CRI is the kubelet-to-runtime gRPC contract. Kubernetes 1.26 and newer require the CRI v1 API for node registration. The CRI surface includes runtime and image services, pod sandbox lifecycle, container lifecycle, logging, exec, attach, and port-forward preparation.
- Kubernetes workload behavior is reconciliation-based. The kubelet continuously compares PodSpecs with runtime state, creates pod sandboxes before containers, reports pod and node status, drives probes, handles lifecycle hooks, and participates in node readiness and lease heartbeats.
- Kubernetes streaming behavior is part of the compatibility contract. Exec, attach, and port-forward are not ordinary local command execution; they are streaming setup calls whose client-visible behavior is tied to kubelet and runtime semantics.
- Docker Engine clients speak a versioned HTTP API to a Docker daemon. Compatibility includes API negotiation, response-field drift, lifecycle endpoints, attach/log stream behavior, event streaming, image APIs, networks, volumes, and broad container inspection.
- Docker Compose is broader than Hostwright's import subset. Compose services can express build, deploy, dependencies, networks, configs, secrets, aliases, named volumes, and lifecycle behavior that Hostwright intentionally rejects or leaves unsupported.
- Hostwright currently has a local `RuntimeAdapter` boundary, explicit state paths, narrow managed lifecycle actions, local deterministic policy, and import-only stack conversion. Those are not equivalent to a kubelet runtime, Docker daemon, Compose runtime, Testcontainers target, or external scheduler.

## Decisions

| Path | Decision | Reason | Required Before Reconsidering |
| --- | --- | --- | --- |
| CRI runtime compatibility | Reject from current core | CRI requires kubelet-facing runtime and image services, pod sandbox semantics, streaming setup, log behavior, and status fidelity that are outside Hostwright's local adapter contract. | Separate issue, exact CRI version target, threat model, state-authority design, kubelet conformance plan, disposable proof, and maintainer approval. |
| Kubernetes node or kubelet replacement | Reject from current core | Node identity, leases, status, scheduler accounting, pod sandbox networking, probes, hooks, and log semantics make this a node-agent project, not an incremental local CLI feature. | Separate project or explicitly approved prototype with node lifecycle, status, security, cleanup, and recovery design. |
| Kubernetes API server or scheduler compatibility | Reject from current core | Hostwright has no API-server, admission, controller, scheduler, or cluster state authority. | Separate architecture decision and maintainer approval. |
| Docker Engine API shim | Reject from current core | A partial daemon-shaped API risks misleading existing clients because compatibility includes version negotiation, attach/log stream framing, events, images, networks, volumes, and inspection behavior. | Separate issue defining supported API version, endpoint subset, stream behavior, auth boundary, policy gates, and conformance tests. |
| Testcontainers target compatibility | Reject from current core | Test tooling usually assumes Docker API behavior, broad lifecycle controls, logs, exec, networks, and cleanup semantics that Hostwright does not expose. | Approved Docker API subset or dedicated test-provider design; no implicit claim from stack import. |
| Full Docker Compose parity | Reject from current core | Hostwright's Phase 28 import path is a reviewed conversion subset. Compose build, deploy, configs, secrets, service discovery, networks, and lifecycle semantics remain fail-closed. | Explicit supported-subset design only; broad parity needs separate issue and evidence review. |
| Attach, exec, log follow, and port-forward compatibility | Reject from current core | Current command policy blocks attach and exec, logs are bounded, and there is no streaming forwarding contract. | Separate diagnostics/streaming proposal with policy, redaction, timeouts, exact resource ownership, and disposable proof. |
| External scheduler integration | Defer | Phase 31 may add an advisory local scheduler model, but it is not a Kubernetes scheduler, cluster scheduler, or external placement API. | Phase 31 implementation plus separate compatibility issue if external API behavior is proposed. |
| Split compatibility project | Defer as possible future path | If compatibility work is pursued, a separate adapter or project is safer than weakening Hostwright's current local safety boundary. | Maintainer-approved scope, public boundary, conformance matrix, and threat model. |

## Current Boundary

Hostwright remains a local Apple container workflow tool. Current behavior is intentionally narrower than external orchestrator contracts:

- Runtime behavior stays behind `RuntimeAdapter`.
- SQLite low-level access stays inside `HostwrightState`.
- State paths are explicit; there is no hidden daemon database.
- Lifecycle mutation is limited to the existing owned create, managed start, managed restart, and exact cleanup-eligible delete paths.
- Stack-file import prints reviewed manifest text only; it does not write files, observe runtime, pull images, call registries, or run an orchestrator.
- Policy evaluation is local and non-mutating.
- Attach, exec, interactive shells, log following, port forwarding, broad stop/remove/restart, image cleanup, volume cleanup, unmanaged cleanup, DNS, tunnels, and cloud exposure remain outside current support.

## Prototype Gate

Any future compatibility prototype requires a separate maintainer-approved issue and must define:

- target protocol and exact version;
- supported and rejected endpoint or field subset;
- state authority, locking, idempotency, recovery, and cleanup model;
- policy decisions for lifecycle, ports, mounts, images, secrets, networking, exposure, and untrusted input;
- stream, log, event, probe, and health semantics if applicable;
- ownership and non-Hostwright resource protection;
- local-only proof plan using disposable Hostwright-owned resources and no image pull unless separately approved;
- documentation that avoids broad compatibility claims.

Prototype requires separate maintainer approval before any code implementation.

## Sources

- Kubernetes Container Runtime Interface: <https://kubernetes.io/docs/concepts/containers/cri/>
- Kubernetes container runtimes: <https://kubernetes.io/docs/setup/production-environment/container-runtimes/>
- Kubernetes CRI API: <https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto>
- Kubernetes pod lifecycle: <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/>
- Kubernetes kubelet sync loop: <https://kubernetes.io/docs/reference/node/kubelet-sync-loop/>
- Kubernetes probes: <https://kubernetes.io/docs/concepts/workloads/pods/probes/>
- Kubernetes port-forward reference: <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_port-forward/>
- Docker Engine API: <https://docs.docker.com/reference/api/engine/>
- Docker Engine events: <https://docs.docker.com/reference/cli/docker/system/events/>
- Docker port publishing: <https://docs.docker.com/engine/network/port-publishing/>
- Docker Compose file reference: <https://docs.docker.com/reference/compose-file/>
- Docker Compose services: <https://docs.docker.com/reference/compose-file/services/>
- Docker Compose Specification: <https://github.com/compose-spec/compose-spec/blob/main/spec.md>
