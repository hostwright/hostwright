# Runtime Adapter Boundary

All runtime-related behavior must go through `RuntimeAdapter`.

## Why This Exists

Hostwright needs to observe, plan, and eventually mutate container runtime state without scattering shell commands across CLI, daemon, reconciler, state, health, or cleanup code. The adapter boundary keeps runtime assumptions isolated, typed, redacted, and testable.

## Phase 5 State

Phase 5 adds read-only Apple container observation infrastructure behind `RuntimeAdapter`.

Implemented by Phase 5:

- typed runtime service identity, desired service, observed service, lifecycle state, health state, ports, mounts, environment values, events, capabilities, and adapter metadata;
- expanded `RuntimeAdapter` protocol for metadata, capability discovery, read-only observation, planning, and future mutation hooks;
- `MockRuntimeAdapter` for deterministic tests without live process execution;
- runtime command specs, command results, command classification, timeout model, and process runner protocol;
- fake process runner for tests;
- Foundation-backed process runner for policy-approved read-only runtime commands;
- executable resolution through `RuntimeExecutableResolver`;
- `AppleContainerReadOnlyAdapter` for read-only observation attempts;
- fixture-defined observation parser for empty and running service snapshots;
- redaction policy for command args, env values, stdout, stderr, parser errors, and runtime errors.

Not implemented in Phase 5:

- Apple container mutation;
- `hostwright apply`;
- SQLite state;
- cleanup;
- restart policy execution;
- daemon runtime loop;
- CLI status backed by observed runtime state.

Runtime mutation begins only in Phase 8.

## RuntimeAdapter Protocol Shape

The adapter exposes:

- `metadata()` for adapter/runtime identity;
- `capabilities()` for supported capability discovery;
- `observe(desiredState:)` for future read-only runtime snapshots;
- `plan(desiredState:observedState:)` for adapter-aware planning hooks;
- `execute(_:confirmation:)` for future mutation hooks.

In Phase 4, mutation hooks exist only so callers can compile against the future shape. Implementations must return mutation-unavailable errors.

## Process Runner Boundary

Runtime process execution is modeled by `RuntimeProcessRunning` and `RuntimeCommandSpec`.

The command spec records:

- executable path;
- arguments;
- environment;
- working directory;
- timeout;
- classification;
- purpose.

Phase 5 includes `FoundationRuntimeProcessRunner`, but it is not a general shell-out path. Before any live process can run:

- the command must be represented as `RuntimeCommandSpec`;
- the command classification must be `readOnly`;
- the executable must be resolved through `RuntimeExecutableResolver`;
- mutating, forbidden, unknown, and unresolved specs are rejected;
- timeout and output capture are enforced;
- command args, env, stdout, stderr, and errors are redacted.

Tests use fake process execution and fixtures. Local live observation is allowed only through `AppleContainerReadOnlyAdapter`.

## Command Classification

`RuntimeCommandClassification` has four values:

- `readOnly`;
- `mutating`;
- `forbidden`;
- `unknown`.

Phase 5 permits only read-only command specs through the policy gate. Mutating, forbidden, unknown, and unresolved command specs are rejected before execution.

Apple container command strings live only in `AppleContainerCommand` and the read-only adapter. The current list-style command shape is a Phase 5 adapter assumption guarded by fail-closed parsing; it is not a public compatibility claim.

## Timeout And Cancellation Model

`RuntimeCommandTimeout` defines:

- default timeout: 30 seconds;
- maximum timeout: 300 seconds;
- minimum timeout: 1 second.

The command result model records:

- exit status;
- stdout;
- stderr;
- whether the command timed out;
- whether the command was cancelled.

The live runner enforces timeout by terminating the process and returning a redacted timeout error with partial output. Cancellation remains represented in the result model and should be tightened when the daemon loop exists.

## Redaction Rules

Runtime redaction applies to:

- command arguments;
- environment variables;
- stdout;
- stderr;
- parser errors;
- runtime error messages.

The default policy redacts key/value patterns and sensitive key fragments such as token, password, secret, credential, auth, and key. Tests use fake placeholder values only.

## Layer Rules

- CLI code must not directly call Apple container for runtime behavior.
- Reconciler code must not shell out.
- State code must not shell out.
- Health code must not mutate runtime state.
- Runtime-related process execution must not bypass `RuntimeAdapter`.
- Safe local diagnostics, such as reading files, checking manifest presence, executable lookup, and current `swift --version` doctor behavior, may remain outside `RuntimeAdapter` when they are not runtime behavior.

## Parser Boundary

`AppleContainerObservationParser` accepts only the Phase 5 fixture-defined JSON schema `hostwright.apple-container.observation.v1`. It fails closed on malformed output, unsupported schema names, unknown keys, unsupported lifecycle values, unsupported health values, unsupported protocols, and unsupported mount access values.

If real Apple container output does not match this schema, Hostwright reports a parse failure instead of guessing. This protects the runtime boundary from turning unverified Apple CLI output into fake product truth.
