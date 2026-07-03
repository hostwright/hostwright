# Reconciliation

Reconciliation is the loop that compares desired state with observed state and produces a plan.

## Model

1. Load desired state.
2. Observe runtime state through `RuntimeAdapter`.
3. Compute drift.
4. Produce a dry-run plan.
5. Apply only through the create-only confirmation and persistence gate.
6. Record events.

## Current State

Hostwright has a deterministic planner. It maps the supported `hostwright.yaml` manifest subset to runtime-shaped desired state, accepts optional `RuntimeAdapter`-shaped observed state, runs planning policy checks, and emits typed drift records, typed issues, typed planned actions, and a deterministic plan hash.

`hostwright plan` still does not perform live runtime observation by default. It renders desired-state and policy diagnostics and states that runtime observation is not connected in the CLI path.

`hostwright apply` is separate from `hostwright plan`. Apply recomputes the observed plan, requires a matching `--confirm-plan` hash, persists intent before mutation, and executes exactly one `createMissingService` action.

There is no cleanup, rollback, multi-action apply, or daemon scheduling loop.

## Drift Cases

The planner detects:

- missing desired services;
- unmanaged observed services;
- stopped, exited, failed, and missing lifecycle states;
- image drift;
- port drift;
- mount drift;
- unhealthy or unknown health state where policy requires health;
- duplicate observed identities;
- unsupported unknown observed lifecycle state;
- unavailable observation.

Only `createMissingService` can be marked executable. Every other action remains unavailable.

## Correctness Requirements

- Planning must be deterministic.
- Desired state and observed state must remain separate inputs.
- Drift must be explainable.
- Plan rendering must not expose raw secrets.
- Mutation must require plan-hash confirmation.
- Operation intent must be persisted before mutation.
- Failures must be observable through events.
