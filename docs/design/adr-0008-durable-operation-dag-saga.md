# ADR 0008: Durable Operation DAG and Saga

Status: Accepted for v0.0.2

## Context

A one-action apply cannot safely implement multi-service dependency order, updates, storage and network attachment, rollout health, rollback, cluster fencing, or recovery after process/runtime failure. A database transaction cannot include an external Apple runtime mutation, so atomicity must be designed across durable state and observed side effects.

## Decision

Every mutation is represented as a durable operation graph:

1. persist redacted intent, input hashes, resource UUIDs, provider binding, and fencing token;
2. plan a deterministic dependency DAG whose steps declare preconditions, idempotency key, timeout, verification, and compensation;
3. acquire the operation/project lease and checkpoint before each external call;
4. execute through the bound Runtime Provider API;
5. observe and verify the exact postcondition instead of trusting process exit alone;
6. checkpoint the result and release dependents;
7. on failure, retry an idempotent step, execute safe compensations in reverse dependency order, or enter a durable operator-visible hold;
8. resume from the ledger after CLI, daemon, runtime, or host interruption.

The saga never promises impossible global atomicity. It promises durable intent, fencing, deterministic resume, explicit partial state, safe compensation where defined, and verified convergence.

## Step Contract

Each step records an operation UUID, step UUID, resource UUID, generation, dependencies, attempt, deadline, idempotency key, redacted request, checkpoint, redacted result, verification state, compensation state, and manual recovery guidance. Saga JSON is structurally decoded, redacted, and re-encoded before persistence; malformed JSON fails closed, and a terminal operation group cannot transition again. Secret values are resolved only at the execution boundary and are never persisted in intent, results, diagnostics, or provenance.

## Failure and Threat Model

- Kill injection occurs before and after every checkpoint and provider call.
- Timeouts cancel the complete owned process tree and do not imply the runtime mutation failed; observation decides.
- Duplicate execution is safe or detected by idempotency/identity.
- Compensation never deletes unmanaged or identity-ambiguous resources.
- Quorum loss, stale fencing, provider mismatch, failed verification, and exhausted recovery budget stop further mutation.
- Recovery actions are authenticated, authorized, audited, and bound to the current operation hash.

## Consequences

Lifecycle, image, volume, network, daemon, cluster, interoperability, and GUI mutations use the same operation engine. One-off mutation paths are not allowed to bypass it after Phase 04. State schema v7 establishes the initial intent/fencing/compensation/verification fields; Phase 04 completes execution and Phase 08 completes unattended recovery.

## Verification

Model-based state-machine tests enumerate crash/retry/compensation sequences. Live tests kill Hostwright, `hostwrightd`, Apple services, and workloads at each mutation checkpoint, then verify exactly one converged resource set, no unmanaged mutation, an intelligible ledger, and exact cleanup.
