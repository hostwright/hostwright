# Networking Boundary

Networking is a high-risk surface. Hostwright must prove local reliability before exposing services beyond the local host.

## Current State

Networking contains local model and policy boundaries only. It does not implement DNS, tunnel management, packet filtering, LAN exposure, local reverse proxying, or cloud integration.

Hostwright currently controls or rejects these local facts:

- Manifest ports use only `"host:container"` syntax; manifests do not expose a bind-address field.
- Hostwright-created Apple container publishes are mapped to explicit `127.0.0.1:host:container` bindings.
- Planning rejects duplicate desired host ports and broad bind addresses when represented in runtime-shaped desired state.
- Planning blocks desired host ports that conflict with observed non-target runtime services when live observation is supplied.
- Privileged host ports remain warning-level in planning and are rejected before create execution.
- DNS, service discovery, network aliases, network modes, `expose`, and other orchestrator networking fields fail closed as unsupported manifest fields.
- The versioned observation fixture schema and the reviewed Apple container 1.0.0 parser record network name, kind, hostname, IPv4/IPv6 address, gateway, interface, MAC address, and MTU when present.
- A disposable two-project proof verified real Apple container 1.0.0 network metadata parsing and exact cleanup. Host-to-container localhost HTTP reachability remains blocked on this machine by the macOS Local Network permission state for `container-runtime-linux`, so that data-plane lane is not counted as passing evidence.

## First-Release Direction

- Support explicit project and localhost scope first.
- Validate ports conservatively.
- Treat LAN, tunnel, and public exposure as blocked until separate design and review.
- Keep local reverse proxying research-only until a separate threat model proves routing, auth, audit, and rollback behavior.
- Treat the Phase 23 secure exposure decision record as the current boundary for Cloudflare Tunnel, Tailscale, WireGuard, mTLS, reverse proxy, DNS, and cloud exposure research.

## Non-Goals

- No CNI support.
- No local DNS resolver.
- No local reverse proxy mutation.
- No Cloudflare, Tailscale, WireGuard, or tunnel integration.
- No cloud control plane.

See [Secure Exposure Research](secure-exposure-research.md) for the current research decisions.
