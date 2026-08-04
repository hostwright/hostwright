# Compatibility

Status: exact development evidence for `0.0.2-dev`; not a `v0.0.2` GA support claim.

## Current Development Boundary

| Area | Current evidence-backed scope | v0.0.2 target |
| --- | --- | --- |
| CPU | Apple silicon only. | Apple silicon; M1/8 GB is the minimum lab cell. |
| macOS | Swift package target is macOS 26+. | Apple’s current and previous supported macOS major at GA, subject to physical qualification. |
| Swift | Package uses Swift tools 6.2; local Phase 01 verification records the exact compiler used. | Reproducible release toolchain recorded in signed provenance. |
| Apple `container` | Versioned structured codecs and declared-capability conformance passed for Apple `container` 1.0.0 and 1.1.0 on physical Apple silicon. Unsupported or mixed versions fail before mutation. | Current and previous tested Apple `container` minor at GA. |
| Containerization | Containerization 0.35.0 is pinned behind the authenticated out-of-process `hostwright-containerization-helper`. Its local-image-only declared subset passed the shared provider conformance suite. | One exact pinned Containerization version per Hostwright release through an out-of-process helper. |
| Manifest | Strict bounded Yams 6.2.2 decoding, canonical Manifest v2 encoding, complete executable Phase 04 single-host, qualified Phase 07 networking, and Phase 08 restart-budget, maintenance-window, and stable-observation rollout fields, plus deterministic legacy-health migration. Unknown or unsupported fields fail before mutation. | Repeat parser, migration, and executable-field qualification at GA. |
| Lifecycle | Confirmed single-host dependency/replica lifecycle, typed startup/readiness/liveness/dependency/stable gates, bounded interactive operations, rolling/recreate updates, verified rollback, resumable exact-stage recovery, and unattended restart budgets through one schema-v17 saga. Images must already exist locally and are bound to reviewed descriptor/platform-variant locks. | Repeat current/previous provider and destructive-recovery qualification at GA. |
| Daemon | Foreground and exact current-user LaunchAgent modes use the same level-triggered lifecycle saga. One-user LaunchAgent lifecycle, secure config reload, unattended reconciliation, durable restart budgets, deterministic local maintenance deferral, health-gated exact-stage rollout, last-healthy rollback with safe holds, checkpoint recovery, exact single-host ownership/finalizer leases, retention, OSLog, event watches, bounded local metrics, correlated local traces, and privacy-safe local support bundles are implemented; the Phase 08 aggregate soak gate remains incomplete. | Repeat the complete lifecycle on the supported macOS matrix and pass the aggregate unattended-policy/soak gate before GA. |
| Control API | v2 contract; the bounded one-shot local process provides read operations plus non-interactive lifecycle parity through exact confirmation. It has no listener or remote endpoint. | Persistent authenticated Unix-socket API with N/N-1 compatibility after v2 establishes the baseline. |
| Runtime providers | Runtime Provider API v2 uses stable IDs `apple-container-cli` and `apple-containerization`, immutable capability snapshots, deterministic observation, normalized outcomes, one provider per project generation, fenced migration, and upgrade/restart recovery. Both providers pass the same suite for every capability they declare. | Repeat the current/previous runtime and pinned-helper conformance matrix at GA. |
| State | SQLite schema v21 for standalone/node-local state. It preserves schema-v17 image, storage, network, restart, maintenance, and ownership authority and adds local identity/session state, tamper-evident audit, least-privilege RBAC, admission/profile storage, and immutable plugin lifecycle authority. | Qualified backup/restore/repair and etcd 3.7.x authority for multi-Mac clusters. |
| Storage | Exact Hostwright-owned named-volume lifecycle, guarded mounts, snapshots, verified online backup/restore, quota and pressure accounting, reclaim policy, attachment fencing, and orphan quarantine/GC through the built-in `hostwright-local` provider and one-shot Control parity. | Repeat live Apple-runtime, crash-recovery, and cleanup qualification at GA. |
| Networking | Exact Hostwright-owned project networks, deterministic DNS and aliases, structured TCP/UDP and Unix-socket publication, guarded host access, explicit LAN exposure, local TLS/mTLS ingress, fail-closed policy enforcement, authenticated service tunnels, and signed sandboxed provider modules through the signed `hostwright-network-helper`. Unsupported provider capabilities fail before mutation. | Repeat Apple CLI 1.0.0/1.1.0, Containerization 0.35.0, permission, sleep/wake, interface-change, and recovery qualification at GA. |
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
