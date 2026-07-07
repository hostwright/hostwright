# Security Model

Hostwright must be conservative because it will eventually manage local runtime resources.

## Current State

Hostwright has narrow runtime mutation gates through `RuntimeAdapter`: create-missing-service, restart-policy-allowed managed start, restart-policy-allowed managed restart, and exact cleanup-eligible managed container delete. Create, start, and managed restart require explicit `--state-db`, explicit `--confirm-plan`, and state intent persistence before execution. Create keeps conservative service-shape validation. Managed restart additionally requires exact Hostwright ownership, live observed running state, and fresh persisted unhealthy health state before the internal stop-then-start sequence. Cleanup requires explicit `--state-db`, dry-run planning, an exact cleanup token, ownership records, live observation, and a non-running lifecycle. The foreground `hostwrightd` loop observes and plans through `RuntimeAdapter`, but does not execute runtime mutation.

No general lifecycle mutation, user-facing stop/restart command, broad cleanup, image deletion, volume deletion, unmanaged deletion, privileged helper, service installer, launch agent, DNS behavior, tunnel behavior, cloud integration, unattended daemon mutation, or default database path exists.

## Requirements

- User-space first.
- No secrets in manifests, logs, status output, events, fixtures, or support bundles.
- Dry-run before runtime mutation.
- Persist operation intent before runtime mutation.
- Explicit confirmation design before destructive operations.
- Host path mounts require validation.
- Public network exposure requires explicit policy and review.
- Privileged helpers require a threat model before implementation.
