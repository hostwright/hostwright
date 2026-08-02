# Security Model

Hostwright must be conservative because it will eventually manage local runtime resources.

## Current State

Hostwright has narrow runtime mutation gates through `RuntimeAdapter`: the complete confirmed lifecycle saga, unattended create/start/restart/update through that same saga, and exact cleanup-eligible managed container deletion. Confirmed and unattended lifecycle requires a selected state database that passes the secure path policy, exact plan identity, state intent persistence, ownership, provider/project generations, fencing, re-observation, compensation, and verification. Unattended mutation additionally enforces workload/project restart budgets, any declared maintenance policy, and exact startup/readiness/liveness/dependency/stable-observation proof before update promotion. Promotion re-observes the candidate identity and durable checkpoint; missing, stale, or ambiguous proof fails closed. Cleanup requires the secure selected state, dry-run planning, an exact cleanup token, ownership records, live observation, and a non-running lifecycle.

All production subprocess call sites now use the Phase 02 secure process boundary: direct argv, root-owned named executable resolution, minimal non-inherited environment, descriptor-pinned working directories, bounded I/O/time, cancellation, fenced session process-group cleanup, and typed caller-normalized errors. The exact flow and native-code containment boundary are documented in [Secure Process Execution](../reference/process-execution.md).

Local state defaults to the private per-user Application Support layout and safely migrates compatible legacy state through resumable journals. Confirmed lifecycle, image, storage, Phase 07 networking, and Phase 08 unattended lifecycle mutations use exact UUID ownership, provider generation, fencing, and durable intent. The managed daemon is one exact current-user LaunchAgent; Hostwright still has no unmanaged deletion, privileged helper, system service, cloud scheduler, persistent network control API, or multi-host authority.

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
