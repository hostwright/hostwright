# Reconciliation

Reconciliation is the loop that compares desired state with observed state and produces a plan.

## Model

1. Load desired state.
2. Observe runtime state through `RuntimeAdapter`.
3. Bind the immutable provider capability digest and compute drift.
4. Compile a canonical dependency DAG with preconditions, postconditions, timeouts, idempotency keys, and compensation.
5. Persist complete schema-v7 intent before the first external effect.
6. Execute ready nodes with deterministic bounded parallelism.
7. Re-observe and persist verification after each mutation wave.
8. Complete, compensate, resume, or enter a precise safe hold.

## Current State

Hostwright maps strict Manifest v2 into executable desired state and compiles `up`, `down`, `run`, `start`, `stop`, `restart`, `rm`, and `update` into `LifecyclePlan v1`. Plans bind manifest, observation, capability, provider, project generation, resource UUID, and fence digests and have a stable topological order.

`hostwright plan` still does not perform live runtime observation by default. It renders desired-state and policy diagnostics and states that runtime observation is not connected in the CLI path.

Lifecycle dry-runs observe without acquiring a mutation group and return the exact confirmation hash. Confirmed execution re-observes, rejects a stale hash before mutation, acquires one operation group per project, and persists canonical intent plus precomputed compensation before calling a provider. `hostwright apply` is a compatibility entry point for the same confirmed `up` engine, not a separate executor.

Replicas and service dependencies expand into deterministic nodes. `started`, `ready`, and `completed` dependencies gate subsequent work; scale-down and removal use safe reverse order. Repeated desired state emits no mutation. Rolling and recreate updates keep the prior revision until the candidate satisfies startup and readiness gates. Failure restores the prior verified revision only when every inverse effect and ownership identity is provable; otherwise recovery records a safe hold.

Node starts, attempts, provider results, observations, health results, and checkpoints are durable. After timeout, cancellation, crash, or ambiguous provider output, Hostwright observes before deciding whether to retry, compensate, or hold. Retry is capped at three attempts and allowed only by normalized retry safety.

`hostwrightd --foreground` runs a non-mutating reconciliation loop. It reads the explicit config path, observes through `RuntimeAdapter`, computes a plan, and records daemon events and operation records to the selected state database (Application Support by default). It does not call `RuntimeAdapter.execute`.

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

The lifecycle planner also detects replica, dependency, revision, probe, and ownership/fence drift. It rejects named volumes, custom networks, unavailable secrets, unavailable architecture/Apple options, and missing local images before external mutation.

## Correctness Requirements

- Planning must be deterministic.
- Desired state and observed state must remain separate inputs.
- Drift must be explainable.
- Plan rendering must not expose raw secrets.
- Mutation must require plan-hash confirmation.
- Complete intent and compensation must be persisted before mutation.
- Failures must be observable through events.
- Every external effect must use exact UUID-backed ownership, project generation, provider generation, and fence validation.
- Ambiguous effects must be re-observed before retry, compensation, or return.
- Readiness must gate dependency release and rollout promotion; liveness restarts remain bounded by policy.
- Removal must verify exact runtime absence before deleting ownership state.
- Unmanaged collisions and later-phase capability gaps must fail before mutation.
