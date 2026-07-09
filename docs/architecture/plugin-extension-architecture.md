# Plugin And Extension Architecture

Status: Phase 33 declaration policy and architecture boundary.

Hostwright does not load, install, distribute, or execute plugins. Phase 33 adds a typed declaration model and local policy evaluator so future extension proposals can be reviewed against the same runtime, state, policy, redaction, audit, and confirmation gates before implementation.

## Implemented Scope

- `HostwrightExtensionDeclaration` describes an extension identifier, kind, declaration API version, trust level, and requested capabilities.
- `HostwrightExtensionCapabilityDeclaration` records a capability, purpose, and the Hostwright boundaries it claims to use.
- `ExtensionPolicyEvaluator` evaluates declarations in memory and returns deterministic `PolicyDecision` values.
- Declaration API version `1` is the only accepted version.
- Built-in and reviewed-local declarations are the only trust levels that can receive allow decisions.
- Third-party and untrusted declarations are blockers in current core scope.
- Empty declarations fail closed instead of disappearing from policy output.

This is a non-mutating prototype. It does not run extension code.

## Extension Types

| Type | Current decision |
| --- | --- |
| Policy pack | Declaration-only non-mutating policy evaluation can be allowed when local policy, redaction, audit, and no-runtime-mutation boundaries are declared. |
| Control-surface integration | Declaration-only read integration can be allowed when it preserves local policy, redaction, audit, explicit state paths, and no-runtime-mutation boundaries. |
| Diagnostics integration | Declaration-only read/export integration can be allowed when it preserves `HostwrightState`, explicit state paths, redaction, audit, local-only/no-upload, and no-runtime-mutation boundaries. |
| Runtime adapter | Runtime observation declarations can be evaluated only as non-mutating paths behind `RuntimeAdapter`; runtime mutation remains unsupported for extensions. |
| Networking provider | Current core blocks provider networking configuration. |
| Tunnel provider | Current core blocks tunnels, DNS, reverse proxy setup, and public exposure. |
| Scheduler integration | Declaration-only scheduler advice can be allowed when it stays advisory, local, redacted, audited, and non-mutating. |
| Future extension | Must fail closed until a separate issue defines capability, threat model, and proof. |

## Capability Rules

Allowed in current declaration policy when required boundaries are present:

- `policyEvaluation`
- `controlSurfaceRead`
- `diagnosticsRead`
- `runtimeObservation`
- `stateRead`
- `schedulerAdvice`

Blocked in current core scope:

- `runtimeMutation`
- `stateWrite`
- `networkingConfiguration`
- `tunnelExposure`
- `secretResolution`
- `acceleratorAccess`

Blocked capabilities still report missing required boundaries, which keeps review output actionable without allowing the capability.

## Required Boundaries

Extension declarations use explicit boundary labels:

- `runtimeAdapter`
- `stateStore`
- `localPolicy`
- `redaction`
- `auditTrail`
- `confirmationGate`
- `ownershipGate`
- `explicitStatePath`
- `localOnlyNoUpload`
- `noRuntimeMutation`

A future extension path must declare the relevant boundaries before it can be reviewed. Missing boundaries are blockers.

## Threat Model

Primary risks:

- bypassing `RuntimeAdapter` with direct Apple container calls;
- bypassing explicit state paths or writing SQLite outside `HostwrightState`;
- weakening local policy gates through a silent override;
- leaking raw secrets or keychain labels through diagnostics, events, or errors;
- bypassing plan-hash confirmation, cleanup tokens, ownership checks, or audit records;
- adding tunnel, DNS, cloud, networking, accelerator, or remote-control behavior as an extension side effect;
- loading untrusted code or remote registry content into the local control plane.

Controls in this phase:

- declarations are data only;
- evaluation is local, deterministic, and non-mutating;
- untrusted and third-party declarations block;
- mutating, state-writing, networking, tunnel, secret-resolution, and accelerator capabilities block;
- every allowed declaration must include redaction and audit boundaries;
- runtime observation declarations must include `RuntimeAdapter` and `noRuntimeMutation`;
- state-read declarations must include `HostwrightState` and explicit state paths.

## Non-Goals

- Plugin loader.
- Remote plugin registry.
- Binary plugin distribution.
- Untrusted code execution.
- Runtime mutation extension path.
- Provider networking, DNS, tunnel, reverse proxy, or cloud exposure integration.
- Secret backend extension path.
- Accelerator integration.
- GUI implementation.

## Review Requirements For Future Work

Any later extension implementation requires a separate scoped issue with:

- exact capability and trust level;
- threat model and failure mode review;
- declared runtime, state, policy, redaction, audit, and confirmation boundaries;
- tests proving no direct Apple container shell-out outside `HostwrightRuntime`;
- tests proving SQLite access remains inside `HostwrightState`;
- redaction tests for events, diagnostics, errors, and display output;
- explicit maintainer approval for dependencies, distribution, runtime mutation, networking, secrets, accelerators, or external integrations.
