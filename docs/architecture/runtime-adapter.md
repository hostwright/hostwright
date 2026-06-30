# Runtime Adapter Boundary

All runtime-related behavior must go through `RuntimeAdapter`.

## Why This Exists

Hostwright needs to observe, plan, and eventually mutate container runtime state without scattering shell commands across CLI, daemon, reconciler, state, health, or cleanup code. The adapter boundary keeps runtime assumptions isolated, typed, redacted, and testable.

## Phase 4 State

Phase 4 builds runtime contract infrastructure only.

Implemented in Phase 4:

- typed runtime service identity, desired service, observed service, lifecycle state, health state, ports, mounts, environment values, events, capabilities, and adapter metadata;
- expanded `RuntimeAdapter` protocol for metadata, capability discovery, read-only observation, planning, and future mutation hooks;
- `MockRuntimeAdapter` for deterministic tests without live process execution;
- runtime command specs, command results, command classification, timeout model, and process runner protocol;
- fake process runner for tests;
- redaction policy for command args, env values, stdout, stderr, and runtime errors.

Not implemented in Phase 4:

- Apple container observation;
- Apple container mutation;
- `hostwright apply`;
- SQLite state;
- cleanup;
- restart policy execution;
- live runtime process execution.

Apple container observation begins in Phase 5. Runtime mutation begins only in Phase 8.

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

Phase 4 includes only fake process execution for tests. No live Apple container command is executed.

## Command Classification

`RuntimeCommandClassification` has four values:

- `readOnly`;
- `mutating`;
- `forbidden`;
- `unknown`.

Phase 4 permits only read-only command specs through the policy gate, and only in fake process-runner tests. Mutating, forbidden, and unknown command specs are rejected.

Examples in code are illustrative Hostwright command specs. They are not claims about verified Apple container command semantics. Exact Apple container behavior must be verified in Phase 5 before becoming implementation truth.

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

Live cancellation behavior is not implemented in Phase 4 because no live process runner exists yet. The contract exists so Phase 5 can implement read-only execution safely.

## Redaction Rules

Runtime redaction applies to:

- command arguments;
- environment variables;
- stdout;
- stderr;
- runtime error messages.

The default policy redacts key/value patterns and sensitive key fragments such as token, password, secret, credential, auth, and key. Tests use fake placeholder values only.

## Layer Rules

- CLI code must not directly call Apple container for runtime behavior.
- Reconciler code must not shell out.
- State code must not shell out.
- Health code must not mutate runtime state.
- Runtime-related process execution must not bypass `RuntimeAdapter`.
- Safe local diagnostics, such as reading files, checking manifest presence, executable lookup, and current `swift --version` doctor behavior, may remain outside `RuntimeAdapter` when they are not runtime behavior.
