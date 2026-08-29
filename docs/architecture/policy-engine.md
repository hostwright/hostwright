# Policy Engine

Status: Experimental Phase 10 policy-to-admission boundary.

Hostwright now has a local policy module, `HostwrightPolicy`, for deterministic and explainable safety decisions. The policy engine does not call Apple container, write SQLite, contact registries, upload telemetry, or mutate runtime state.

## Implemented Scope

- `LocalPolicyEvaluator` evaluates policy subjects in memory.
- `PolicyDecision` records category, reason code, severity, subject, message, remediation, and stable detail key.
- Planner safety checks for desired identities, host ports, broad bind addresses, privileged ports, mounts, and secret-like environment values are routed through the policy evaluator before becoming reconciler `PlanIssue` values.
- Cleanup classification uses policy decisions for ownership-backed and observed-only resources while preserving the existing dry-run/token/confirmation/delete gates.
- Image policy decisions explain local digest-policy failures without registry calls.
- Secret-reference decisions fail closed without carrying raw keychain labels in messages or stable keys.
- Untrusted-manifest and secure-exposure requests have fail-closed policy decisions; lifecycle and accelerator/provider claims are admitted only through the Phase 10 profile and runtime-enforcement gates.
- Experimental Phase 10 scheduler admission consumes validated policy decisions as placement, capacity, and runtime gates without changing policy semantics.

## Categories

| Category | Current policy behavior |
| --- | --- |
| Identity | Empty project or service identity is a blocker before planning or mutation. |
| Ports | Duplicate desired host ports and observed non-target host-port conflicts are blockers. Privileged host ports are warnings because the narrower create path rejects them before mutation. |
| Exposure | Localhost remains the default. Unqualified broad binds are blockers; Phase 07 LAN, ingress, DNS, and tunnel paths proceed only through their separate exact policy, identity, capability, and confirmation gates. Cloud exposure remains unsupported. |
| Mounts | Ambiguous mount references, host-root mounts, and parent-traversal sources are blockers. |
| Images | `imagePolicy: require-digest` failures are local string-policy blockers only. |
| Environment and secrets | Secret-like environment values are warning decisions for plan redaction; unresolved secret references are blockers before mutation. |
| Cleanup | Only exact Hostwright-owned non-running containers can become eligible; every other classification fails closed. |
| Lifecycle | Only existing narrow create, managed-start, managed-restart, and cleanup gates are allowed. Broad lifecycle actions are blockers. |
| Untrusted manifests | Unsupported fields are blockers. |
| Accelerators | Accelerator claims are profile-gated and map to the scheduler contract, but selected runtime enforcement and host-native execution remain unavailable until their Phase 10 qualification gates pass. |
| Scheduling | The single `HostwrightScheduler` admission boundary consumes validated policy decisions for placement and capacity; policy evaluation itself remains non-mutating. |

## Defaults And Overrides

The default policy is local, deterministic, and fail-closed. Current overrides are code-level test/configuration inputs only: privileged-port warning threshold, broad-bind block list, redaction policy, and image digest policy.

There is no remote policy service, central policy distribution, silent bypass, runtime mutation from policy, or automatic override path. Phase 34 consumes deterministic decisions through explicit local profile and approval files; policy evaluation remains non-mutating and strict-only.

## Boundaries Preserved

- Runtime execution still goes through `RuntimeAdapter`.
- SQLite access stays inside `HostwrightState`.
- Cleanup remains destructive only after dry-run, exact ownership, live observation, eligible lifecycle, token confirmation, and exact identifiers.
- Secret values and keychain reference labels are redacted from display, state, diagnostics, and policy-facing error surfaces.
- Policy decisions are diagnostic and gating data. They do not perform remediation automatically.
- `HostwrightScheduler` admission consumes policy output at the lifecycle/control boundary; it does not create a second advisory scheduler, bypass runtime/state gates, or mutate state from policy evaluation.
