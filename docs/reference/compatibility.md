# Compatibility

Status: exact development evidence for `0.0.2-dev`; not a `v0.0.2` GA support claim.

## Current Development Boundary

| Area | Current evidence-backed scope | v0.0.2 target |
| --- | --- | --- |
| CPU | Apple silicon only. | Apple silicon; M1/8 GB is the minimum lab cell. |
| macOS | Swift package target is macOS 26+. | Apple’s current and previous supported macOS major at GA, subject to physical qualification. |
| Swift | Package uses Swift tools 6.2; local Phase 01 verification records the exact compiler used. | Reproducible release toolchain recorded in signed provenance. |
| Apple `container` | Local observation evidence exists for Apple `container` 1.0.0 shapes and narrow mutations; Phase 02 state/doctor qualification also passed with Apple `container` 1.1.0. Broad provider conformance is not claimed, and Phase 03 has not started. | Current and previous tested Apple `container` minor at GA; Phase 03 begins the 1.1+ structured-codec/conformance track. |
| Containerization | Not implemented. | One exact pinned Containerization version per Hostwright release through an out-of-process helper. |
| Manifest | Explicit v2 contract with a restricted parser; v1/versionless migration preview. | Complete executable Manifest v2 workload schema. |
| Control API | v2 contract; current implementation remains a bounded one-shot local process. | Persistent authenticated Unix-socket API with N/N-1 compatibility after v2 establishes the baseline. |
| Runtime providers | Runtime Provider API v2 metadata and narrow Apple adapter behavior. | Apple CLI and Containerization providers passing the same declared-capability suite. |
| State | SQLite schema v7 for standalone/node-local state. | Qualified backup/restore/repair and etcd 3.7.x authority for multi-Mac clusters. |
| Distribution | Source builds and `brew install hostwright/tap/hostwright` are available. Immutable dev.11/dev.12 ZIP and `.pkg` artifacts passed signing, notarization, stapling, Gatekeeper, SBOM, provenance, attestation, public-byte, clean macOS 26 lifecycle, state, doctor, and abrupt-power qualification. These remain unsupported prereleases, not GA. | Phase 15 repeats signed/notarized archive, `.pkg`, vendor-tap, SBOM/provenance, and reversible-lifecycle qualification for GA. |
| Kubernetes | Not implemented. | Current and previous supported Kubernetes minor through real pod-sandbox VM, CRI/CNI/CSI/Helm conformance. |
| Docker ecosystem | Narrow import-only stack conversion; no Docker API. | Published Docker API/client matrix, Compose/Podman/Testcontainers conformance. |
| GUI/cloud | Not implemented beyond requirements/local policy models. | Native accessible GUI; optional cloud that never breaks complete offline local operation. |

The current machine and tool versions used for evidence belong in the final evidence record, not in a timeless claim. Run:

```bash
hostwright --version
hostwright capabilities --json
sw_vers
uname -m
swift --version
container --version
```

Missing `container` is allowed for non-runtime commands. It blocks live-runtime evidence and runtime workflows; it does not become a skipped success.

Phase 36 can measure a local pre-existing image through RuntimeAdapter when every required capability and exact-cleanup gate passes. That retained local path is evidence for only the recorded machine/image/runtime combination and is not a GA compatibility or capacity claim.

## Explicit Unsupported Results

Until their owning phase closes, unsupported manifest fields, provider capabilities, API versions/endpoints, Kubernetes/Docker operations, and client-specific fields must fail with stable explicit diagnostics. Hostwright never silently drops a requested behavior and then reports success.

## Permanent Platform Boundaries

- No Intel or old-macOS emulation.
- No private Apple APIs.
- No unsafe cluster writes without quorum.
- No unauthenticated public control endpoint.
- No silent telemetry.
- No destructive garbage collection of unmanaged resources.

Direct guest GPU/ANE access is not claimed without a supported Apple API. Phase 10 implements the user outcome through a signed authenticated host-native Metal/Core ML/MLX service and can add direct passthrough later only with public-API conformance evidence.

## GA Matrix Rule

The exact GA matrix is frozen in Phase 15. “Current and previous” is a qualification goal, not permission to claim an untested combination. A failing unsafe upstream combination narrows the published matrix with evidence and an accountable issue; it is never papered over with a compatibility shim.
