# Phase 40 Devlog: Apple Silicon Control-Plane Direction

Phase 40 records the control-plane direction decision. It does not implement platform expansion.

## Changed

- Added `docs/architecture/control-plane-direction.md`.
- Chose single-host core as the beta and first-supported-release direction.
- Rejected Kubernetes-class, CRI, Docker API, full Compose, cloud, multi-host, remote placement, and accelerator-aware scheduling work from current core.
- Updated the charter, roadmap, limitations, requirements, acceptance matrix, source traceability, build status, and README links.
- Added core docs guard coverage for the Phase 40 direction boundary.

## Not Changed

- No cluster implementation.
- No CRI shim.
- No Kubernetes node, API, or scheduler behavior.
- No Docker API shim or Compose parity.
- No cloud control plane.
- No remote host agents, state replication, membership, peer discovery, or remote placement.
- No accelerator implementation or accelerator-aware scheduling.
- No product code, runtime mutation, RuntimeAdapter change, SQLite change, dependency, release tag, GitHub Release, website work, or GUI code.
