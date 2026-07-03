# Security Policy

Hostwright is not yet production ready. Security-sensitive behavior must be designed, reviewed, and tested before it is enabled.

## Current Security Posture

- Runtime mutation is limited to the create-missing-service apply gate.
- No destructive or general lifecycle mutation is implemented.
- No privileged helper exists.
- No launch agent or service installer exists.
- No tunnel, DNS, cloud, CRI, Kubernetes, or Docker API behavior exists.
- Source material and brand-source assets are preserved for traceability.

## Security Requirements

- Secrets must not be written to manifests, logs, status output, events, screenshots, fixtures, or support bundles.
- Runtime mutation must have a dry-run plan first.
- Destructive operations must require explicit confirmation design.
- Host path mounts, public ports, env values, and image references must be validated at system boundaries.
- Any future privileged helper requires a threat model and design record before implementation.

## Reporting

This repository is local-only at the moment. Do not publish sensitive reports in public trackers until the project has a published security contact and disclosure process.
