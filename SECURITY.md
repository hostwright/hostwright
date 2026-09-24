# Security Policy

Hostwright is not yet production ready. Security-sensitive behavior must be designed, reviewed, and tested before it is enabled.

## Current Security Posture

- Supported local runtime mutation is fenced through reviewed `RuntimeAdapter` and lifecycle-saga gates: exact plan confirmation, provider capability, ownership and generation checks, durable intent before effects, and post-effect verification. Ambiguous effects enter a safe hold.
- Destructive resource and file effects remain ownership-scoped with dry-run classification, exact confirmation, live observation, and fail-closed handling when ownership or state cannot be proven.
- Foreground and managed `hostwrightd` use the same reconciliation path. Both may reconcile admitted workload changes only through the shared fenced lifecycle saga, with current scheduler authority and ownership checks.
- No privileged helper exists.
- The supported daemon service is one explicit current-user LaunchAgent, `dev.hostwright.daemon`; no privileged helper or system-wide service installer exists.
- Phase 07 networking is limited to exact UUID-owned project DNS, ingress, certificate, policy, authenticated service-tunnel, and restricted provider-SPI boundaries. No unmanaged host DNS, general VPN, unauthenticated public exposure, cloud, CRI, Kubernetes, or Docker API behavior exists.
- Internal planning/source-material binaries are not required in the public tree.

## Security Requirements

- Secrets must not be written to manifests, logs, status output, events, screenshots, fixtures, or support bundles.
- Runtime mutation must have a dry-run plan first.
- Destructive operations must require explicit dry-run review, ownership checks, and exact confirmation design.
- Host path mounts, public ports, env values, and image references must be validated at system boundaries.
- Any future privileged helper requires a threat model and design record before implementation.

## Reporting

Do not put vulnerability details or sensitive diagnostics in public issues or pull requests. To arrange private disclosure, open a minimal [maintainer contact request](https://github.com/hostwright/hostwright/issues/new) that asks for a private security-reporting channel without describing the vulnerability. Wait for a maintainer to provide that channel before sending details. No response-time commitment or production support SLA is offered.

After arranging private contact, include the exact Hostwright version or source commit, macOS and runtime versions, the affected boundary, and a minimal reproduction with sensitive values removed. Never send secrets, credentials, Keychain exports, or raw state databases. Keep private hostnames, file paths, exploit details, and live-resource identifiers out of public follow-up messages.

For diagnostics, follow the [support-bundle preview and confirmation workflow](docs/reference/support-bundles.md). Bundles stay local until the operator chooses to share them; review the contents and recipient first. For interrupted state maintenance, preserve the evidence and follow [local state recovery](docs/reference/local-recovery.md) before retrying mutations.

## Security Review Triggers

Maintainer security review is required before changes that affect:

- runtime command construction, command allowlists, lifecycle mutation, cleanup deletion, or live proof scope;
- SQLite migrations, operation ledgers, ownership records, diagnostics export, or recovery records;
- secret references, Keychain behavior, redaction, credential storage, or support-bundle content;
- policy decisions, policy override behavior, untrusted manifest handling, stack import, or compatibility claims;
- networking exposure, DNS, tunnels, cloud control, provider integrations, multi-host trust, or accelerator behavior;
- release artifacts, signing, notarization, SBOM, provenance, installers, or package channels.

## Support Boundary

Hostwright has no production support SLA, hosted diagnostics, telemetry upload, cloud control plane, or enterprise support workflow in the current core project.
