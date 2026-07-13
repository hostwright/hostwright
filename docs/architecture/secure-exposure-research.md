# Secure Exposure Research

> **Historical research, promoted to implementation:** v0.0.2 Phase 07 owns networks, DNS, ingress, TLS/mTLS, policy, Hostwright tunnels, and third-party provider SPI. The fail-closed current boundary remains until executable security and cleanup evidence passes.

Status: research-only decision record for Phase 23.

Hostwright does not currently support tunnels, public exposure, cloud exposure, local reverse proxy mutation, DNS management, WireGuard setup, Cloudflare integration, Tailscale integration, mTLS provisioning, or a cloud control plane. This document records boundaries that must exist before any later implementation issue starts.

## Source Review

Reviewed on 2026-07-08:

- [Cloudflare Tunnel](https://developers.cloudflare.com/tunnel/) publishes local applications through outbound `cloudflared` connections and maps public hostnames to local services.
- [Cloudflare published applications](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/) depend on DNS or load-balancer routing for public hostnames; Access protection is optional and separate.
- [Cloudflare Access self-hosted applications](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/) add authentication policy in front of self-hosted applications and are deny-by-default when Access policies are configured.
- [Cloudflare Tunnel permissions](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/tunnel-permissions/) involve account-scoped certificates and tunnel credentials with revocation through Cloudflare account/API token management.
- [Tailscale Funnel](https://tailscale.com/docs/features/tailscale-funnel) exposes local services to the public Internet, requires HTTPS certificates, policy attributes, access controls, and DNS propagation.
- [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve) proxies local services inside a tailnet; identity headers are available for Serve traffic but not for public Funnel traffic.
- [Tailscale ACLs/grants](https://tailscale.com/docs/features/access-control/acls) are deny-by-default when configured and are enforced by tailnet policy.
- [WireGuard](https://www.wireguard.com/) is an IP-layer tunnel interface using public keys and cryptokey routing; key distribution and pushed configuration are outside WireGuard itself.
- [NGINX mTLS](https://nginx.org/en/docs/http/ngx_http_ssl_module.html) can verify client certificates when configured with trusted CA material.
- [Caddy reverse proxy](https://caddyserver.com/docs/quick-starts/reverse-proxy) can proxy local services; public domains require DNS and public ports, while localhost TLS can involve local CA trust-store changes.

## Decision Matrix

| Exposure path | Decision | Reason |
| --- | --- | --- |
| Cloudflare Tunnel public application | Reject from core; defer only to plugin or later prototype | Requires provider credentials, Cloudflare DNS/routing, Access policy decisions, credential revocation, audit trail, and explicit operator consent. |
| Cloudflare Access / mTLS policy | Reject from core; defer only to provider plugin work | Useful auth boundary, but it belongs behind provider-specific policy, credential storage, and revocation design. |
| Tailscale Serve | Reject from core; defer only to plugin or later prototype | Private-tailnet sharing still depends on tailnet identity, grants, node/auth keys, LocalAPI behavior, and provider policy that Hostwright must not hide behind defaults. |
| Tailscale Funnel | Reject from core; defer only to plugin or later prototype | Public exposure requires tailnet policy attributes, HTTPS certificates, DNS propagation, and a clear warning that Funnel traffic lacks Serve identity headers. |
| WireGuard | Reject from core for now | It is IP-layer network plumbing with key distribution outside the protocol; core should not configure interfaces, routes, or peer keys. |
| Local reverse proxy | Defer | A local-only proxy might be useful later, but it needs port ownership, auth, TLS, config reload, audit, and rollback policy before mutation. |
| mTLS in front of local services | Defer | Needs certificate authority, certificate/key storage, rotation, revocation, identity mapping, and Phase 24 secret-boundary work. |
| DNS management | Reject for current core | Hostwright does not own domains, zones, split-horizon DNS, or propagation behavior. |
| Cloud control plane | Reject for current core | Remote orchestration changes product positioning and trust boundaries and is outside the local-first roadmap. |

## Minimum Future Gate

Any future secure-exposure implementation must have a separate issue and must prove all of these before code starts:

- explicit user action, dry-run preview, and confirmation for every exposure;
- local policy evaluation from the Phase 32 policy engine;
- Phase 24 [secret-reference and Keychain boundary](secrets-keychain-boundary.md) for all provider credentials, private keys, certificates, and tokens;
- no default public exposure and no background connectivity by default;
- exact service, port, hostname, provider, credential reference, and revocation target in the plan;
- local audit events for create, update, disable, revoke, and failure;
- deterministic rollback or explicit manual recovery when rollback is not safe;
- provider-specific threat model covering auth bypass, DNS mistakes, credential theft, stale tunnels, and accidental public exposure;
- tests for redaction, audit, auth policy shape, revocation behavior, and unsupported provider fields before any network calls.

## Rejected Paths

- Hostwright core will not create Cloudflare tunnels, Tailscale Funnel/Serve rules, WireGuard interfaces, DNS records, certificates, reverse proxy configs, or cloud resources in the current roadmap slice.
- No provider integration is implemented by this research phase.
- Hostwright will not store provider credentials or private keys as raw manifest, state, event, diagnostics, or command-line values.
- Hostwright will not claim secure sharing, public hosting, remote access, VPN, or zero-trust networking support until a later approved implementation proves it.
