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
- The versioned observation fixture schema can record reviewed network attachments by name, kind, address, gateway, and interface. Non-empty real Apple container network output remains unsupported until a reviewed fixture defines its schema.

## First-Release Direction

- Support explicit project and localhost scope first.
- Validate ports conservatively.
- Treat LAN, tunnel, and public exposure as blocked until separate design and review.
- Keep local reverse proxying research-only until a separate threat model proves routing, auth, audit, and rollback behavior.

## Non-Goals

- No CNI support.
- No local DNS resolver.
- No local reverse proxy mutation.
- No Cloudflare, Tailscale, WireGuard, or tunnel integration.
- No cloud control plane.
