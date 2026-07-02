# Reconciliation

Reconciliation is the loop that compares desired state with observed state and produces a plan.

## Model

1. Load desired state.
2. Observe runtime state through `RuntimeAdapter`.
3. Compute drift.
4. Produce a dry-run plan.
5. Apply only after mutation behavior and confirmation design exist.
6. Record events.

## Phase 7 State

Hostwright now has a deterministic non-mutating planner. It maps the supported `hostwright.yaml` manifest subset to runtime-shaped desired state, accepts optional `RuntimeAdapter`-shaped observed state, runs planning policy checks, and emits typed drift records, typed issues, typed planned actions, and a deterministic plan hash.

`hostwright plan` still does not perform live runtime observation by default. It renders desired-state and policy diagnostics and states that runtime observation is not connected in the CLI path for this phase.

There is no apply loop, runtime mutation, cleanup, or daemon scheduling loop.

## Drift Cases

Phase 7 detects:

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

Every action is a dry-run action with execution unavailable until Phase 8.

## Correctness Requirements

- Planning must be deterministic.
- Desired state and observed state must remain separate inputs.
- Drift must be explainable.
- Plan rendering must not expose raw secrets.
- Future mutation must be idempotent.
- Failures must be observable through events.
