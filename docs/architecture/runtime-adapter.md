# Runtime Adapter Boundary

All runtime-related behavior must go through `RuntimeAdapter`.

## Why This Exists

Hostwright needs to observe, plan, and eventually mutate container runtime state without scattering shell commands across CLI, daemon, reconciler, state, health, or cleanup code. The adapter boundary keeps runtime assumptions isolated, typed, redacted, and testable.

## Current State

Hostwright has Apple container observation infrastructure behind `RuntimeAdapter` and one mutation-capable adapter path, limited to create-missing-service, restart-policy-gated managed start, bounded logs, and ownership-gated cleanup delete.

Implemented:

- typed runtime service identity, desired service, observed service, lifecycle state, health state, ports, mounts, environment values, events, capabilities, and adapter metadata;
- expanded `RuntimeAdapter` protocol for metadata, capability discovery, read-only observation, planning, bounded logs, and mutation hooks;
- `MockRuntimeAdapter` for deterministic tests without live process execution;
- runtime command specs, command results, command classification, timeout model, and process runner protocol;
- fake process runner for tests;
- Foundation-backed process runner for policy-approved read-only runtime commands and the supported mutation specs;
- executable resolution through `RuntimeExecutableResolver`;
- `AppleContainerReadOnlyAdapter` for read-only observation attempts;
- `AppleContainerApplyAdapter` for narrow create, start, and delete mutation;
- fixture-defined observation parser for empty and running service snapshots;
- redaction policy for command args, env values, stdout, stderr, parser errors, and runtime errors.

Not implemented:

- stop, restart, remove, run, pull, build, exec, image delete, volume delete, or prune;
- daemon restart loops;
- daemon runtime loop;
- broad cleanup or unmanaged cleanup.

Runtime mutation is limited to create-missing-service, restart-policy-allowed managed start, and exact cleanup-eligible managed container delete.

## RuntimeAdapter Protocol Shape

The adapter exposes:

- `metadata()` for adapter/runtime identity;
- `capabilities()` for supported capability discovery;
- `observe(desiredState:)` for future read-only runtime snapshots;
- `plan(desiredState:observedState:)` for adapter-aware planning hooks;
- `logs(for:tail:)` for bounded read-only log output;
- `execute(_:confirmation:)` for future mutation hooks.

`execute(_:confirmation:)` may perform exactly one supported mutation action when confirmation, plan hash, policy validation, and any state persistence gates have passed.

## Process Runner Boundary

Runtime process execution is modeled by `RuntimeProcessRunning` and `RuntimeCommandSpec`.

The command spec records:

- executable path;
- arguments;
- environment;
- working directory;
- timeout;
- classification;
- mutation kind, when classification is mutating;
- purpose.

`FoundationRuntimeProcessRunner` is not a general shell-out path. Before any live process can run:

- the command must be represented as `RuntimeCommandSpec`;
- the executable must be resolved through `RuntimeExecutableResolver`;
- read-only commands must pass read-only policy;
- mutating commands must be classified as `mutating` and carry a supported mutation kind;
- forbidden, unknown, unsupported mutating, and unresolved specs are rejected;
- timeout and output capture are enforced;
- command args, env, stdout, stderr, and errors are redacted.

Tests use fake process execution and fixtures. Local live observation and supported mutation are allowed only through RuntimeAdapter implementations in `HostwrightRuntime`.

## Command Classification

`RuntimeCommandClassification` has four values:

- `readOnly`;
- `mutating`;
- `forbidden`;
- `unknown`.

The current policy permits read-only command specs and three behavior-named mutating command kinds: `createMissingService`, `startManagedService`, and `deleteManagedContainer`. Forbidden, unknown, unresolved, and unsupported mutating specs are rejected before execution.

Apple container command strings live only in `AppleContainerCommand` and runtime adapters. The current list-style command shape and create command shape are based on local Apple container 1.0.0 help output and guarded by fail-closed parsing and policy checks; they are not broad Apple CLI compatibility claims.

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

`AppleContainerObservationParser` accepts the fixture-defined JSON schema `hostwright.apple-container.observation.v1`, the verified real empty Apple container list output, the verified Apple builder-container output as ignored non-Hostwright runtime state, and the verified created/stopped `hostwright-proof-web` proof container output.

If broader real Apple container output does not match one of those reviewed shapes, Hostwright reports a parse failure instead of guessing. This protects the runtime boundary from turning unverified Apple CLI output into fake product truth.

## Mutation Boundary

Apply and cleanup support only:

- `container image list --format json` as a read-only local-image availability gate;
- `container create --name <name> --env KEY=value --publish 127.0.0.1:host:container <image> [command...]`.
- `container start <id>` for exact Hostwright-owned stopped/created/exited services when restart policy allows managed start.
- `container delete <id>` for exact cleanup-eligible Hostwright-owned stopped/created/exited containers after dry-run token confirmation.

The adapter rejects mounts, DNS, custom networks, capabilities, Rosetta, virtualization, custom runtime/kernel, SSH forwarding, `--rm`, `run`, image pull, stop, restart, remove, broad cleanup, prune, build, exec, attach, interactive, `--all`, `--force`, image delete, and volume delete.

The live proof used an explicitly approved disposable local image and created exactly one container named `hostwright-proof-web`. A stale repeat apply was rejected before mutation because the recomputed plan hash changed. Cleanup removed only the exact proof container and proof image. Apple builder runtime state and the downloaded base image remain outside Hostwright ownership.
