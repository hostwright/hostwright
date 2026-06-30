# Networking Boundary

Networking is a high-risk surface. Hostwright must prove local reliability before exposing services beyond the local host.

## Phase 1 State

Networking contains model boundaries only. It does not implement DNS, tunnel management, packet filtering, LAN exposure, local proxying, or cloud integration.

## First-Release Direction

- Support explicit project and localhost scope first.
- Validate ports conservatively.
- Treat LAN, tunnel, and public exposure as blocked until separate design and review.

## Non-Goals

- No CNI support.
- No local DNS resolver.
- No Cloudflare, Tailscale, WireGuard, or tunnel integration.
- No cloud control plane.

