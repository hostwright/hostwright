# Reconciliation

Reconciliation is the loop that compares desired state with observed state and produces a plan.

## Model

1. Load desired state.
2. Observe runtime state through `RuntimeAdapter`.
3. Bind the immutable provider capability digest and compute drift.
4. Compile a canonical dependency DAG with preconditions, postconditions, timeouts, idempotency keys, and compensation.
5. Persist complete schema-v17 intent, including immutable image locks, exact supply-chain policy bindings, content leases, storage authority, network authority, and restart-budget state, before the first external effect.
6. Execute ready nodes with deterministic bounded parallelism.
7. Re-observe and persist verification after each mutation wave.
8. Complete, compensate, resume, or enter a precise safe hold.

## Current State

Hostwright maps strict Manifest v2 into executable desired state and compiles `up`, `down`, `run`, `start`, `stop`, `restart`, `rm`, and `update` into `LifecyclePlan v1`. Plans bind manifest, observation, capability, provider, project generation, resource UUID, and fence digests and have a stable topological order.

`hostwright plan` still does not perform live runtime observation by default. It renders desired-state and policy diagnostics and states that runtime observation is not connected in the CLI path.

Lifecycle dry-runs observe without acquiring a mutation group and return the exact confirmation hash. Confirmed execution re-observes, rejects a stale hash before mutation, acquires one operation group per project, and persists canonical intent plus precomputed compensation before calling a provider. When declared, image signature, SBOM, vulnerability, and build-provenance preflights reload the exact verified Gate 6 graph and current policy material before the first provider effect. `hostwright apply` is a compatibility entry point for the same confirmed `up` engine, not a separate executor.

An update persists exact prior and candidate resource identity before effects. Promotion is ordered after candidate start, startup, readiness, liveness, dependency, and optional stable-observation gates. Every promotion attempt freshly re-observes provider identity and lifecycle state, reloads the probe checkpoint, and refuses missing or ambiguous proof. The stable interval is checkpointed so process restart resumes the same candidate and stage without a duplicate workload. Progress-deadline, restart-budget, and maintenance admission remain independent fail-closed bounds around that DAG.

Replicas and service dependencies expand into deterministic nodes. `started`, `ready`, and `completed` dependencies gate subsequent work; scale-down and removal use safe reverse order. Repeated desired state emits no mutation. Rolling and recreate updates keep the prior revision until the candidate satisfies startup and readiness gates. Failure restores the prior verified revision only when every inverse effect and ownership identity is provable; otherwise recovery records a safe hold.

Node starts, attempts, provider results, observations, health results, supply-chain authorization events, and checkpoints are durable. After timeout, cancellation, crash, or ambiguous provider output, Hostwright observes before deciding whether to retry, compensate, or hold. Recovery revalidates current signature, SBOM, vulnerability, and provenance evidence and rebinds that authorization to any derived rollback plan. Retry is capped at three attempts and allowed only by normalized retry safety.

### Mutation checkpoint contract v1

Every `lifecycle-v1` operation group has one recognized bounded checkpoint. The enclosing group supplies the operation ID, group ID, plan SHA-256, project, provider generation, and fencing token; the step record supplies direction, resource identity, attempt, result, and verification. `hostwright recovery` renders the following stable classification without copying raw provider output:

| Exact checkpoint | Class | Recovery |
|---|---|---|
| `intent-persisted` | `intent` | `resume` |
| `<node>:effect-pending` | `forward-effect` | `reobserve` |
| `<node>:verified`, `<node>:verified-after-resume` | `verification` | `complete` |
| `<node>:cancelled-before-effect`, `<node>:cancelled-no-effect` | `interruption` | `resume` |
| `<node>:ambiguous-after-resume`, `<node>:ambiguous-effect`, `<node>:accepted-without-effect`, `<node>:context-stale`, `<node>:irreversible-effect-safe-hold` | `safe-hold` | `safe-hold` |
| `<node>:compensation-pending` | `compensation` | `reobserve` |
| `<node>:compensated` | `compensation` | `complete` |
| `<node>:compensation-ambiguous-after-resume`, `<node>:compensation-attempts-exhausted`, `<node>:compensation-context-stale`, `<node>:compensation-failed`, `<node>:compensation-record-mismatch`, `<node>:compensation-unavailable` | `compensation` | `safe-hold` |
| `<node>:restored-health-safe-hold`, `rollback-restored-health-safe-hold` | `restored-health` | `safe-hold` |
| `rollback-restored-health-verified` | `restored-health` | `complete` |
| `finalizer:started`, `finalizer:failed` | `finalizer` | `reobserve` |
| `finalizer:verified` | `finalizer` | `complete` |
| `verified`, `compensated` | `terminal` | `complete` |

An unknown checkpoint has no permissive fallback. Confirmed recovery returns a `rollback.planning-incomplete` safe hold before provider observation or mutation. An expired active group at a compensation or restored-health checkpoint re-enters the compensation lane directly: it re-observes the exact inverse before any retry and never replays a forward node merely because its compensation result row lagged the external effect. Finalizers must reconcile their own persisted resource state, so replay either proves the prior result or remains interrupted; it cannot treat a prior return as proof that no effect occurred.

The checkpoint inventory remains owned by its existing bounded authorities. The LaunchAgent controller uses every `DaemonLifecycleCheckpoint`; distribution uses every `DistributionLifecycleCheckpoint`; runtime migration uses every `RuntimeProviderMigrationCheckpoint`; storage attachments, snapshots, backups, capacity admission, reclaim, and state restore/repair use their typed checkpoint records; image, registry, secret, network, DNS, port, and tunnel coordinators use their existing fenced operation groups and journals. Gate 8 qualifies those authorities but does not replace them with a generic workflow engine. Phase 08 retention/GC and observability records do not yet have external-effect checkpoints at this gate; their owning Gates 10–15 must add only their issue-required durable boundaries before claiming support.

Phase 08 rollback uses the same saga and persisted recovery driver. Reverse compensation cannot finish merely because inverse runtime calls returned: Hostwright re-observes one exact owned prior resource per service, verifies provider/capability and resource UUID/generation, requires `running`, and executes every configured startup, readiness, and liveness probe. Explicit rollback plans append those verification nodes after all inverses. A failed or ambiguous restored-health check enters `rollback.restored-health-failed` safe hold and preserves the restored resource; it never compensates the rollback by recreating the failed candidate. Safe holds expose a schema-v1 reason code, bounded redacted explanation, affected nodes, and exact persisted-group recovery commands.

`hostwrightd --foreground` and the exact managed `--service` mode run the same level-triggered reconciliation loop. Healthy scheduling begins immediately and repeats within five seconds without a filesystem event. The daemon validates the explicit config, observes through `RuntimeAdapter`, computes health and restart inputs, and invokes the existing CLI lifecycle compiler/live driver/saga for `up`. An empty DAG records convergence; a nonempty DAG requires fresh observation, exact confirmation, one project lease, durable intent, fencing, bounded execution, and verification. Compensation, interruption, ambiguity, or safe hold remains visible and triggers bounded backoff rather than a success claim.

The daemon does not maintain a second executor. CLI and daemon execution therefore share provider selection, image binding, network/storage preflight, operation groups, checkpoints, compensation, and cleanup behavior. The outer daemon loop does not publish a candidate manifest over the authoritative healthy desired revision before the saga has recorded mutation intent.

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

The lifecycle planner also detects replica, dependency, revision, probe, and ownership/fence drift. Named volumes and Phase 07 networking compile through their exact provider boundaries; unavailable secrets, providers, enforcement capabilities, architecture/Apple options, and missing local images fail before external mutation.

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
- Missing or unknown lifecycle checkpoint identities must fail before provider mutation.
- Process loss after a compensation or finalizer effect must re-observe that exact effect before replay.
- Readiness must gate dependency release and rollout promotion; liveness restarts remain bounded by policy.
- Removal must verify exact runtime absence before deleting ownership state.
- Unmanaged collisions and later-phase capability gaps must fail before mutation.
