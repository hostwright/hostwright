# Security Model

Hostwright must be conservative because it will eventually manage local runtime resources.

## Current State

Hostwright has one runtime mutation gate: create-missing-service through `RuntimeAdapter`. It requires explicit `--state-db`, explicit `--confirm-plan`, state intent persistence before execution, local image confirmation, and conservative service-shape validation.

No destructive operation, general lifecycle mutation, privileged helper, service installer, DNS behavior, tunnel behavior, cloud integration, daemon loop, cleanup, or default database path exists.

## Requirements

- User-space first.
- No secrets in manifests, logs, status output, events, fixtures, or support bundles.
- Dry-run before runtime mutation.
- Persist operation intent before runtime mutation.
- Explicit confirmation design before destructive operations.
- Host path mounts require validation.
- Public network exposure requires explicit policy and review.
- Privileged helpers require a threat model before implementation.
