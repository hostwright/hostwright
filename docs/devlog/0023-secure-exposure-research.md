# Phase 23: Secure Exposure Research

## What Changed

- Added a research-only secure exposure decision record.
- Compared Cloudflare Tunnel, Cloudflare Access, Tailscale Serve/Funnel, WireGuard, mTLS, local reverse proxy, DNS, and cloud-control-plane paths.
- Recorded conservative decisions before implementation: reject Cloudflare, Tailscale, WireGuard, DNS, and cloud-control-plane work from current core scope, leave provider paths only for explicit plugin or later prototype work, and keep reverse proxy and mTLS as later design work.
- Added a docs guard test so current public docs do not drift into tunnel/cloud support claims.

## Boundaries Preserved

- No provider integration.
- No credentials.
- No tunnels.
- No DNS behavior.
- No reverse proxy mutation.
- No cloud control plane.
- No product network calls.
- No runtime mutation.
