# Networking Boundary

Networking is fail-closed and ownership-scoped. Localhost is the default; no unsupported provider capability or exposure mode is silently degraded.

## Current State

Phase 07 qualifies:

- UUID-owned project networks with deterministic attachments, recovery, and reverse-order cleanup;
- deterministic project-scoped DNS and ready-only service and replica aliases;
- structured TCP/UDP mappings and descriptor-confined Unix-socket publication;
- guarded workload-to-host endpoints using Apple's documented localhost mechanism only when the provider can enforce the declared allowlist;
- explicit LAN listeners bound to the confirmed interface and CIDR;
- owned HTTP/1.1 and WebSocket ingress with bounded parsing, health-aware backends, atomic reload, and drain;
- Keychain-backed imported or local-CA certificates, TLS 1.3 mTLS identities, rotation, revocation, and fail-closed recovery;
- canonical ingress/egress policy with provider capability checks and no permissive transition;
- authenticated Hostwright service tunnels and a signed, digest-bound, restricted network-provider SPI.

Runtime names do not establish ownership. Every network, attachment, reservation, listener, certificate record, policy generation, and tunnel route is bound to Hostwright UUIDs, provider generation, and a fencing token. Ambiguous effects are re-observed; cleanup removes only exact verified ownership.

## Exposure Rules

- Legacy `"host:container"` ports remain localhost TCP mappings.
- LAN requires an explicit interface, network class, allowed CIDR, TLS policy, and exact plan confirmation.
- Public exposure requires TLS plus mTLS or an authenticated tunnel/provider path. Hostwright never opens an unauthenticated public listener.
- Unsupported IPv6 assignment, host-access enforcement, raw egress enforcement, certificate authority, or tunnel capability fails before mutation.
- Hostwright does not manage arbitrary PF rules or mutate global host DNS.

## Boundaries

- No Kubernetes CNI compatibility in Phase 07.
- No general VPN or NetworkExtension.
- No built-in Cloudflare, Tailscale, or WireGuard integration.
- No unmanaged host-wide DNS or reverse-proxy configuration.
- No cloud control plane or unauthenticated exposure.

See [Secure Exposure Research](secure-exposure-research.md) for the retained provider research and [Security and Safety](../reference/security-safety.md) for the active trust boundary.
