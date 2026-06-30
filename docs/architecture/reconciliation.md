# Reconciliation

Reconciliation is the loop that compares desired state with observed state and produces a plan.

## Model

1. Load desired state.
2. Observe runtime state through `RuntimeAdapter`.
3. Compute drift.
4. Produce a dry-run plan.
5. Apply only after mutation behavior and confirmation design exist.
6. Record events.

## Phase 2 State

Hostwright can create a manifest-level dry-run plan from `hostwright.yaml`. The plan is explicitly non-mutating and states that runtime observation is unavailable.

There is no apply loop, runtime observation, runtime mutation, or daemon scheduling loop.

## Correctness Requirements

- Planning must be deterministic.
- Desired state and observed state must remain separate inputs.
- Drift must be explainable.
- Future mutation must be idempotent.
- Failures must be observable through events.
