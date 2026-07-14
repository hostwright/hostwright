# Plugin And Extension Architecture

Status: Phase 33 declaration policy plus Phase 41 reviewed-local handshake host.

Hostwright does not provide generic plugin loading, installation, distribution, discovery, or capability invocation. Phase 33 adds a typed declaration model and local policy evaluator. Phase 41 adds one explicit, reviewed-local executable handshake so a caller can verify a locally reviewed binary and declaration against that policy before any future capability API is designed.

## Implemented Scope

- `HostwrightExtensionDeclaration` describes an extension identifier, kind, declaration API version, trust level, and requested capabilities.
- `HostwrightExtensionCapabilityDeclaration` records a capability, purpose, and the Hostwright boundaries it claims to use.
- `ExtensionPolicyEvaluator` evaluates declarations in memory and returns deterministic `PolicyDecision` values.
- Declaration API version `1` is the only accepted version.
- Built-in and reviewed-local declarations are the only trust levels that can receive allow decisions.
- Third-party and untrusted declarations are blockers in current core scope.
- Empty declarations fail closed instead of disappearing from policy output.

Phase 33 remains a non-mutating declaration model. Phase 41 can execute only the fixed `hostwright-extension-handshake-v1` protocol operation; it does not send capability payloads or grant runtime, state, secret, networking, tunnel, accelerator, or control-plane access.

## Executable Handshake Scope

`hostwright extension check --declaration <absolute-path> --executable <absolute-path>` requires:

- a strict flat JSON declaration with exactly one capability;
- declaration API and process protocol version 1;
- `reviewedLocal` trust;
- a kind/capability pairing accepted by the executable-host allowlist;
- every boundary required by `ExtensionPolicyEvaluator`;
- the exact lowercase SHA-256 of the executable;
- declaration and executable files owned by the invoking user, with no symlink, group-write, or world-write path;
- an owner-executable binary copied from an open descriptor into a private mode-`0500` staging directory.

The staged process receives one fixed argument, a minimal `LANG`/`LC_ALL` environment, `/` as its working directory, and one bounded JSON request on stdin. The host concurrently drains bounded stdout and stderr, enforces a timeout, requires exit 0 and empty stderr, rejects unknown or duplicate response fields, and verifies the exact request ID, declaration digest, identifier, protocol version, capability, and ready status. The staged file and directory must be removed before success is returned.

A passing check proves only that the exact reviewed file completed this protocol handshake. The protocol supplies no Hostwright capability handle or payload, but the executable still has the invoking macOS account's ambient operating-system privileges. Hostwright cannot prevent that reviewed code from opening accessible files or network connections, invoking absolute-path tools, or spawning descendants. It does not prove that an extension capability works, that the code is sandboxed, that descendant processes are contained, or that the executable is suitable for distribution.

## Extension Types

| Type | Current decision |
| --- | --- |
| Policy pack | Declaration-only non-mutating policy evaluation can be allowed when local policy, redaction, audit, and no-runtime-mutation boundaries are declared. |
| Control-surface integration | Declaration-only read integration can be allowed when it preserves local policy, redaction, audit, secure selected state paths, and no-runtime-mutation boundaries. |
| Diagnostics integration | Declaration-only read/export integration can be allowed when it preserves `HostwrightState`, secure selected state paths, redaction, audit, local-only/no-upload, and no-runtime-mutation boundaries. |
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
- bypassing secure state-path selection or writing SQLite outside `HostwrightState`;
- weakening local policy gates through a silent override;
- leaking raw secrets or keychain labels through diagnostics, events, or errors;
- bypassing plan-hash confirmation, cleanup tokens, ownership checks, or audit records;
- adding tunnel, DNS, cloud, networking, accelerator, or remote-control behavior as an extension side effect;
- loading untrusted code or remote registry content into the local control plane.

Controls in this phase:

- declarations remain policy data and the executable path is explicit;
- evaluation is local, deterministic, and non-mutating;
- untrusted and third-party declarations block;
- mutating, state-writing, networking, tunnel, secret-resolution, and accelerator capabilities block;
- every allowed declaration must include redaction and audit boundaries;
- runtime observation declarations must include `RuntimeAdapter` and `noRuntimeMutation`;
- state-read declarations must include `HostwrightState` and secure selected state paths.
- only the fixed version-1 handshake executes, with no capability input or Hostwright authority;
- executable bytes are hash-bound and privately staged before launch;
- process time and output are bounded, raw stderr is never surfaced, and exact staging cleanup is required.

## Non-Goals

- Generic plugin loader or capability invocation.
- Remote plugin registry.
- Binary plugin distribution.
- Untrusted code execution.
- Sandboxing or descendant-process containment guarantees.
- Runtime mutation extension path.
- Provider networking, DNS, tunnel, reverse proxy, or cloud exposure integration.
- Secret backend extension path.
- Accelerator integration.
- GUI implementation.

## Review Requirements For Future Work

Any later extension capability implementation requires a separate scoped issue with:

- exact capability and trust level;
- threat model and failure mode review;
- declared runtime, state, policy, redaction, audit, and confirmation boundaries;
- tests proving no direct Apple container shell-out outside `HostwrightRuntime`;
- tests proving SQLite access remains inside `HostwrightState`;
- redaction tests for events, diagnostics, errors, and display output;
- explicit maintainer approval for dependencies, distribution, runtime mutation, networking, secrets, accelerators, or external integrations.
