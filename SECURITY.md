# Security Policy

Hostwright is not yet production ready. Security-sensitive behavior must be designed, reviewed, and tested before it is enabled.

## Current Security Posture

- Runtime mutation is limited to reviewed `RuntimeAdapter` gates: create-missing-service, restart-policy-allowed managed start, restart-policy-allowed managed restart, and exact cleanup-eligible managed container delete.
- Destructive mutation is limited to ownership-scoped cleanup delete with dry-run classification, exact token confirmation, live observation, and non-running lifecycle state.
- `hostwrightd --foreground` observes, plans, records events, and runs bounded health checks without unattended runtime mutation.
- No privileged helper exists.
- No launch agent or service installer exists.
- No tunnel, DNS, cloud, CRI, Kubernetes, or Docker API behavior exists.
- Internal planning/source-material binaries are not required in the public tree.

## Security Requirements

- Secrets must not be written to manifests, logs, status output, events, screenshots, fixtures, or support bundles.
- Runtime mutation must have a dry-run plan first.
- Destructive operations must require explicit dry-run review, ownership checks, and exact confirmation design.
- Host path mounts, public ports, env values, and image references must be validated at system boundaries.
- Any future privileged helper requires a threat model and design record before implementation.

## Reporting

This repository is local-only at the moment. Do not publish sensitive reports in public trackers until the project has a published security contact and disclosure process.

If a report includes secrets, credentials, private hostnames, private file paths, diagnostic bundles, exploit details, or live-resource identifiers, request a private maintainer contact first instead of opening a public issue.

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
