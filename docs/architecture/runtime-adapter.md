# Runtime Adapter Boundary

All runtime-related behavior must go through `RuntimeAdapter`.

## Why This Exists

Hostwright needs to observe, plan, and eventually mutate container runtime state without scattering shell commands across CLI, daemon, reconciler, state, health, or cleanup code. The adapter boundary keeps runtime assumptions isolated, typed, redacted, and testable.

## Current State

Hostwright has Apple container observation infrastructure behind `RuntimeAdapter` and one mutation-capable adapter path, limited to create-missing-service, restart-policy-gated managed start, restart-policy-gated managed restart, bounded logs, and ownership-gated cleanup delete.

Implemented:

- typed versioned runtime service identity, exact observed resource identifiers, desired service, observed service, lifecycle state, health state, ports, networks, mounts, environment values, events, capabilities, and adapter metadata;
- expanded `RuntimeAdapter` protocol for metadata, capability discovery, read-only observation, planning, bounded logs, and mutation hooks;
- test-only `ScriptedRuntimeAdapter` for deterministic contracts without live process execution;
- runtime command specs, command results, command classification, timeout model, and process runner protocol;
- test-only scripted process runner for deterministic result and failure injection;
- `SecureRuntimeProcessRunner` for policy-approved read-only runtime commands and the supported mutation specs;
- root-owned executable resolution through `RuntimeExecutableResolver`;
- `AppleContainerReadOnlyAdapter` for read-only observation attempts;
- `AppleContainerApplyAdapter` for narrow create, start, managed restart, and delete mutation;
- fixture-defined observation parser for empty and running service snapshots;
- redaction policy for command args, env values, stdout, stderr, parser errors, and runtime errors.

Not implemented:

- public stop/restart commands, broad remove, run, pull, build, exec, image delete, volume delete, or prune;
- daemon restart loops;
- daemon runtime loop;
- broad cleanup or unmanaged cleanup.

Runtime mutation is limited to create-missing-service, restart-policy-allowed managed start, restart-policy-allowed managed restart, and exact cleanup-eligible managed container delete.

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

`SecureRuntimeProcessRunner` is not a general shell-out path. Before any live process can run:

- the command must be represented as `RuntimeCommandSpec`;
- the executable must be resolved through `RuntimeExecutableResolver`;
- read-only commands must pass read-only policy;
- mutating commands must be classified as `mutating` and carry a supported mutation kind;
- forbidden, unknown, unsupported mutating, and unresolved specs are rejected;
- exact argv, a minimal non-inherited environment, descriptor-pinned working directory, timeout, cancellation, separate output limits, and owned process-group cleanup are enforced;
- command args, env, stdout, stderr, and errors are redacted.

The shared launch and recovery contract is documented in [Secure Process Execution](../reference/process-execution.md). Unit-contract tests retain scripted failure injection for adapter policy only. The process boundary itself is exercised with compiled executables, real pipes, real signals, cancellation races, descriptor checks, and real child processes. Live observation and supported mutation remain allowed only through RuntimeAdapter implementations in `HostwrightRuntime`.

## Command Classification

`RuntimeCommandClassification` has four values:

- `readOnly`;
- `mutating`;
- `forbidden`;
- `unknown`.

The current policy permits read-only command specs and four behavior-named mutating command kinds: `createMissingService`, `startManagedService`, `restartManagedService`, and `deleteManagedContainer`. Forbidden, unknown, unresolved, and unsupported mutating specs are rejected before execution.

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

Exit status is zero-only by default. The sole current exception is the exact read-only Apple `container system status --format json` contract: the [Apple 1.1.0 implementation](https://github.com/apple/container/blob/1.1.0/Sources/ContainerCommands/System/SystemStatus.swift) emits typed not-running or unregistered JSON with exit status 1, matching 1.0.0. A dedicated policy accepts only status 0 or 1 for that exact argument vector so the adapter can parse the state; the policy is rejected for mutations and unrelated read-only commands.

The live runner enforces timeout and task cancellation by terminating the owned session process group and returning a distinct redacted error with bounded partial output. Output overflow, I/O failure, unexpected descendants, and cleanup non-convergence are separately typed. Foreground daemon shutdown still stops between loop iterations and during daemon sleep; the daemon does not yet hold and cancel an in-flight runtime task.

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
- Safe host diagnostics such as file reads, manifest presence, public interface/memory/thermal facts, signing assessment, and executable lookup may remain outside `RuntimeAdapter` when they are not runtime behavior. Doctor's Apple CLI version and structured service-status probes use `RuntimeAdapter.runtimeReadiness()`; no CLI or health layer may execute them directly.

## Parser Boundary

`AppleContainerObservationParser` accepts the fixture-defined JSON schema `hostwright.apple-container.observation.v1`, the verified real empty Apple container list output, Apple builder output as ignored runtime state, state-backed legacy identifiers, and labeled Apple container 1.0.0 rows. Current-project v2 labels are bound to the exact identifier, labeled orphans remain visible, unrelated labeled projects are ignored, and malformed current-project ownership fails closed. Real network parsing records hostname, IPv4/IPv6 address, gateway, MAC address, network name, and MTU.

If broader real Apple container output does not match one of those reviewed shapes, Hostwright reports a parse failure instead of guessing. This protects the runtime boundary from turning unverified Apple CLI output into fake product truth.

## Mutation Boundary

Apply and cleanup support only:

- `container image list --format json` as a read-only local-image availability gate;
- `container create --name <versioned-id> --label <exact-ownership-label> ... --env KEY=value --publish 127.0.0.1:host:container <image> [command...]`.
- `container start <id>` for exact Hostwright-owned stopped/created/exited services when restart policy allows managed start.
- internal `container stop <id>` then `container start <id>` for exact Hostwright-owned running/unhealthy services when restart policy allows managed restart.
- `container delete <id>` for exact cleanup-eligible Hostwright-owned stopped/created/exited containers after dry-run token confirmation.

The adapter rejects mounts, DNS, custom networks, capabilities, Rosetta, virtualization, custom runtime/kernel, SSH forwarding, `--rm`, `run`, image pull, public stop/restart commands, remove, broad cleanup, prune, build, exec, attach, interactive, `--all`, `--force`, image delete, and volume delete.

The latest live identity proof used the existing local `docker.io/library/python:alpine` image without pulling. Two projects whose legacy identifiers were identical produced distinct v2 identifiers and labels, were observed concurrently with Apple container 1.0.0 network metadata, exited naturally, and were removed through exact token-confirmed Hostwright cleanup. Apple builder runtime state and the base image remained outside Hostwright ownership. Localhost HTTP forwarding is not claimed by that proof because macOS Local Network access for `container-runtime-linux` is disabled on the proof host.
