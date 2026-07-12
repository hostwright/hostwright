# Policy Engine

Status: Phase 32 local policy boundary.

Hostwright now has a local policy module, `HostwrightPolicy`, for deterministic and explainable safety decisions. The policy engine does not call Apple container, write SQLite, contact registries, upload telemetry, or mutate runtime state.

## Implemented Scope

- `LocalPolicyEvaluator` evaluates policy subjects in memory.
- `PolicyDecision` records category, reason code, severity, subject, message, remediation, and stable detail key.
- Planner safety checks for desired identities, host ports, broad bind addresses, privileged ports, mounts, and secret-like environment values are routed through the policy evaluator before becoming reconciler `PlanIssue` values.
- Cleanup classification uses policy decisions for ownership-backed and observed-only resources while preserving the existing dry-run/token/confirmation/delete gates.
- Image policy decisions explain local digest-policy failures without registry calls.
- Secret-reference decisions fail closed without carrying raw keychain labels in messages or stable keys.
- Untrusted-manifest, secure-exposure, lifecycle, and accelerator requests have fail-closed policy decisions for current unsupported scope.
- Advisory scheduling consumes local policy decisions as explanation and scoring inputs without changing policy semantics.

## Categories

| Category | Current policy behavior |
| --- | --- |
| Identity | Empty project or service identity is a blocker before planning or mutation. |
| Ports | Duplicate desired host ports and observed non-target host-port conflicts are blockers. Privileged host ports are warnings because the narrower create path rejects them before mutation. |
| Exposure | Broad bind addresses are blockers. Secure exposure scopes such as tunnels, DNS, cloud, and reverse proxy setup remain unsupported. |
| Mounts | Ambiguous mount references, host-root mounts, and parent-traversal sources are blockers. |
| Images | `imagePolicy: require-digest` failures are local string-policy blockers only. |
| Environment and secrets | Secret-like environment values are warning decisions for plan redaction; unresolved secret references are blockers before mutation. |
| Cleanup | Only exact Hostwright-owned non-running containers can become eligible; every other classification fails closed. |
| Lifecycle | Only existing narrow create, managed-start, managed-restart, and cleanup gates are allowed. Broad lifecycle actions are blockers. |
| Untrusted manifests | Unsupported fields are blockers. |
| Accelerators | Apple GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native helpers, and accelerator scheduler dimensions are blockers in current core scope. |
| Scheduling | Local advisory scheduler reports can reuse policy blockers and warnings, but policy does not place workloads or reserve capacity. |

## Defaults And Overrides

The default policy is local, deterministic, and fail-closed. Current overrides are code-level test/configuration inputs only: privileged-port warning threshold, broad-bind block list, redaction policy, and image digest policy.

There is no remote policy service, central policy distribution, silent bypass, runtime mutation from policy, or automatic override path. Phase 34 consumes deterministic decisions through explicit local profile and approval files; policy evaluation remains non-mutating and strict-only.

## Boundaries Preserved

- Runtime execution still goes through `RuntimeAdapter`.
- SQLite access stays inside `HostwrightState`.
- Cleanup remains destructive only after dry-run, exact ownership, live observation, eligible lifecycle, token confirmation, and exact identifiers.
- Secret values and keychain reference labels are redacted from display, state, diagnostics, and policy-facing error surfaces.
- Policy decisions are diagnostic and gating data. They do not perform remediation automatically.
- Advisory scheduling remains in memory and non-mutating; it does not change `ReconciliationPlan` hashes, execute runtime actions, or write scheduler state.
