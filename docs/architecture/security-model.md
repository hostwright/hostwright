# Security Model

Hostwright must be conservative because it will eventually manage local runtime resources.

## Phase 1 State

No runtime mutation, destructive operation, privileged helper, service installer, DNS behavior, tunnel behavior, or cloud integration exists.

## Requirements

- User-space first.
- No secrets in manifests, logs, status output, events, fixtures, or support bundles.
- Dry-run before runtime mutation.
- Explicit confirmation design before destructive operations.
- Host path mounts require validation.
- Public network exposure requires explicit policy and review.
- Privileged helpers require a threat model before implementation.

