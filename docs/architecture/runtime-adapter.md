# Runtime Adapter Boundary

All runtime-related behavior must go through `RuntimeAdapter`.

## Why This Exists

Hostwright needs to observe, plan, and eventually mutate container runtime state without scattering shell commands across CLI, daemon, reconciler, state, health, or cleanup code. The adapter boundary keeps runtime assumptions isolated, typed, redacted, and testable.

## Current State

Phase 03 implements two Runtime Provider API v2 providers behind `RuntimeAdapter`: `apple-container-cli` and `apple-containerization`. Each exposes only capabilities it passed in the shared conformance suite. Phase 04 composes those qualified primitives into the confirmed single-host lifecycle, probes, bounded interactive operations, rolling/recreate updates, rollback, and recovery. Provider capability snapshots remain authoritative; an unavailable operation fails before execution.

Implemented:

- typed versioned runtime service identity, exact observed resource identifiers, desired service, observed service, lifecycle state, health state, ports, networks, mounts, environment values, events, capabilities, and adapter metadata;
- immutable canonical capability snapshots and digests covering provider, component, host, protocol, and per-feature compatibility;
- explicit Apple `container` 1.0.0 and 1.1.0 structured codecs for status, containers, images, networks, volumes, machines, and stats;
- deterministic bounded inventories for containers, images, networks, volumes, mounts, ports, resources, init processes, lifecycle, available health, labels, services, and machine state;
- normalized provider outcomes with stable categories, retry disposition, redacted guidance, and observation-before-retry for ambiguous effects;
- expanded `RuntimeAdapter` protocol for metadata, capability discovery, read-only observation, planning, bounded logs, and mutation hooks;
- test-only `ScriptedRuntimeAdapter` for deterministic contracts without live process execution;
- runtime command specs, command results, command classification, timeout model, and process runner protocol;
- test-only scripted process runner for deterministic result and failure injection;
- `SecureRuntimeProcessRunner` for policy-approved read-only runtime commands and the supported mutation specs;
- root-owned executable resolution through `RuntimeExecutableResolver`;
- `AppleContainerReadOnlyAdapter` and `AppleContainerApplyAdapter` for the versioned Apple CLI path;
- an on-demand authenticated `hostwright-containerization-helper` process that alone links exact Containerization 0.35.0;
- helper protocol v1 over a private Unix socket using bounded length-prefixed canonical JSON frames, request IDs, deadlines, capability digests, mutation context, and idempotency keys;
- project-generation provider binding, dry-run/confirmation migration, fencing, compensation, and checkpoint recovery in existing schema-v7 state;
- redaction policy for command args, env values, stdout, stderr, parser errors, and runtime errors.

The helper uses a private mode-`0700` runtime directory and mode-`0600` socket, authenticates same-UID peers plus the signed Hostwright code requirement, limits frames to 8 MiB, and rejects replay, duplicate IDs, truncation, overflow, protocol mismatch, unsafe paths, and replaced binaries. It implements only negotiate, observe, local-image evidence, resource usage, bounded logs, create, start, managed restart, delete, cancellation, and idle shutdown. Images must already exist locally.

Not implemented:

- image pull, build, load, push, tag, image delete, or prune;
- named-volume lifecycle, snapshots, custom networks, DNS, ingress, or broad bind exposure;
- unattended daemon runtime mutation;
- broad or unmanaged cleanup.

Runtime mutation remains plan-confirmed and ownership-scoped. Lifecycle commands can create, start, stop, restart, and remove exact managed instances; update composes those primitives with health-gated promotion and compensation. Interactive operations use their own bounded provider interface and are advertised only after qualification.

## RuntimeAdapter Protocol Shape

The adapter exposes:

- `metadata()` for adapter/runtime identity;
- `capabilities()` for supported capability discovery;
- `observe(desiredState:)` for future read-only runtime snapshots;
- `plan(desiredState:observedState:)` for adapter-aware planning hooks;
- `logs(for:tail:)` for bounded read-only log output;
- `execute(_:confirmation:)` for future mutation hooks.

`execute(_:confirmation:)` performs one supported provider mutation action only after confirmation, plan hash, policy validation, state persistence, identity, generation, capability, ownership, and fence gates have passed. The lifecycle saga is responsible for composing those individual actions.

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

Apple container command strings live only in `AppleContainerCommand` and runtime adapters. The supported command shapes are selected by exact Apple CLI/API versions 1.0.0 or 1.1.0 and guarded by fail-closed structured parsing and policy checks; they are not a compatibility claim for other versions.

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

The Apple provider selects explicit 1.0.0 or 1.1.0 codecs after version negotiation. It accepts unknown non-semantic fields but rejects duplicate critical keys, partial documents, unknown required enum values, conflicting identity, and oversized output. Current-project UUID labels are bound to exact identifiers, labeled orphans remain visible, unrelated projects are ignored, names never grant ownership, and every collection is sorted before its semantic digest is calculated.

If real Apple container output does not match the selected reviewed codec, Hostwright reports an incompatible or invalid-response outcome instead of guessing. This protects the runtime boundary from turning unverified Apple CLI output into product truth.

## Provider Selection, Migration, And Recovery

An existing schema-v7 project-generation binding is authoritative. An unbound `auto` selection prefers a compatible Apple CLI provider and chooses Containerization only when the CLI is unavailable and the helper is fully capable. A requested provider that differs from an existing binding is refused and directed to `hostwright runtime migrate`.

Migration binds its dry-run token to source observation, source and target capability digests, state, planned effects, and rollback actions. Confirmed migration acquires an operation group and new fence before either provider mutates, verifies UUID-backed ownership and target continuity, and advances the provider generation only after durable verification. Recovery re-probes and re-observes after CLI/API/helper/framework/protocol/macOS changes, helper or service restart, Hostwright termination, timeout, cancellation, or ambiguous effect. Incompatible downgrade or future protocol versions stop safely rather than replaying an operation.

## Mutation Boundary

Phase 04 lifecycle support uses:

- structured local-image evidence before creation;
- exact UUID/fence-labeled create with localhost-only port publishing and supported bind mounts;
- start, stop, managed restart, and delete for exact Hostwright-owned identifiers;
- structured observation after every ambiguous or completed effect;
- bounded exec, attach, copy, export, inspect, stats, and log-follow operations only when the selected provider advertises them.

The lifecycle planner, not a raw provider command, implements replicas, dependencies, probes, rolling/recreate updates, rollback, and checkpoint recovery. The adapter still rejects image pull/build/load, named volumes, DNS, custom networks, broad bind exposure, custom runtime/kernel, SSH forwarding, `--all`, `--force`, image deletion, volume deletion, and unmanaged cleanup.

The latest live identity proof used the existing local `docker.io/library/python:alpine` image without pulling. Two projects whose legacy identifiers were identical produced distinct v2 identifiers and labels, were observed concurrently with Apple container 1.0.0 network metadata, exited naturally, and were removed through exact token-confirmed Hostwright cleanup. Apple builder runtime state and the base image remained outside Hostwright ownership. Localhost HTTP forwarding is not claimed by that proof because macOS Local Network access for `container-runtime-linux` is disabled on the proof host.
