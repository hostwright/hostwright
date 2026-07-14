# Security Model

Hostwright must be conservative because it will eventually manage local runtime resources.

## Current State

Hostwright has narrow runtime mutation gates through `RuntimeAdapter`: create-missing-service, restart-policy-allowed managed start, restart-policy-allowed managed restart, and exact cleanup-eligible managed container delete. Create, start, and managed restart require a selected state database that passes the secure path policy, explicit `--confirm-plan`, and state intent persistence before execution. Create keeps conservative service-shape validation. Managed restart additionally requires exact Hostwright ownership, live observed running state, and fresh persisted unhealthy health state before the internal stop-then-start sequence. Cleanup requires the secure selected state, dry-run planning, an exact cleanup token, ownership records, live observation, and a non-running lifecycle. The foreground `hostwrightd` loop observes and plans through `RuntimeAdapter`, but does not execute runtime mutation.

All production subprocess call sites now use the Phase 02 secure process boundary: direct argv, root-owned named executable resolution, minimal non-inherited environment, descriptor-pinned working directories, bounded I/O/time, cancellation, fenced session process-group cleanup, and typed caller-normalized errors. The exact flow and native-code containment boundary are documented in [Secure Process Execution](../reference/process-execution.md).

Local state defaults to the private per-user Application Support layout and safely migrates compatible legacy state through a resumable identity journal. No general lifecycle mutation, user-facing stop/restart command, broad cleanup, image deletion, volume deletion, unmanaged deletion, privileged helper, service installer, launch agent, DNS behavior, tunnel behavior, cloud integration, or unattended daemon mutation exists.

## Requirements

- User-space first.
- No plaintext secrets in manifests, logs, status output, events, fixtures, or support bundles.
- Secret references must stay local, explicit, redacted, and unresolved unless a confirmed mutation uses an approved secret backend.
- Dry-run before runtime mutation.
- Persist operation intent before runtime mutation.
- Explicit confirmation design before destructive operations.
- Host path mounts require validation.
- Public network exposure requires explicit policy and review.
- Privileged helpers require a threat model before implementation.
- Native extension isolation requires the Phase 09 WASI or signed XPC boundary; process-group cleanup is not presented as a hostile-code sandbox.
