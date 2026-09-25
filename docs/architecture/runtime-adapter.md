# Runtime providers

`RuntimeAdapter` isolates runtime access from the CLI, daemon, planner, state store, and health modules. Runtime Provider API v2 has two provider IDs: `apple-container-cli` and `apple-containerization`.

## Provider capabilities

The CLI provider selects versioned codecs for Apple `container` 1.0.0 or 1.1.0. The native provider runs pinned Containerization 0.35.0 in `hostwright-containerization-helper`. Each provider publishes its capability snapshot; callers reject operations absent from that snapshot.

The helper requires local images. Its private Unix socket uses bounded, length-prefixed canonical JSON, request identities, deadlines, capability digests, mutation context, and idempotency keys. It authenticates the peer UID and signed code requirement. Private directories use mode `0700`, the socket uses `0600`, and frames are capped at 8 MiB.

## RuntimeAdapter Protocol Shape

The adapter supplies metadata, capability discovery, observation, planning, logs, readiness, and provider operations. A lifecycle operation checks confirmation, policy, ownership, generation, and the current fence before a provider call. The coordinator records durable intent before effects and verifies the result afterward.

Lifecycle commands compose create, start, stop, restart, and removal with dependency, health, update, and recovery rules. Image, network, storage, and interactive commands use their corresponding provider contracts. They remain unavailable when a provider cannot enforce the requested behavior.

## Process Runner Boundary

`RuntimeCommandSpec` carries the executable, argument vector, minimal environment, working directory, timeout, classification, and mutation kind. `RuntimeExecutableResolver` verifies the executable path. `SecureRuntimeProcessRunner` checks policy, pins the working directory, limits output, handles cancellation, and cleans up the owned process group.

The runner rejects unknown, forbidden, unresolved, and unsupported specifications before execution. Command arguments, environment values, output, and errors pass through redaction. See [process execution](../reference/process-execution.md) for the complete subprocess contract.

## Command Classification

Commands are `readOnly`, `mutating`, `forbidden`, or `unknown`. Mutation kinds include managed lifecycle, image lifecycle, and network lifecycle. A kind identifies the policy to apply; it does not bypass plan, capability, or ownership checks.

Apple command strings belong in the runtime module. Read-only host diagnostics may live elsewhere, but Apple runtime probes, including doctor readiness checks, use the adapter.

## Timeout And Cancellation Model

Runtime command timeouts default to 30 seconds and range from 1 to 300 seconds. Cancellation, timeout, output overflow, I/O failure, unexpected descendants, and incomplete cleanup have distinct outcomes. Ambiguous effects require observation before retry.

Exit status must be zero except for the exact read-only `container system status --format json` command, whose reviewed contract also permits status 1 with a typed not-running or unregistered response. That exception does not apply to mutations or other commands.

## Redaction Rules

Redaction covers arguments, environment, stdout, stderr, parser errors, and runtime errors. It combines sensitive-key patterns with exact known secret values. Keep credentials out of command arguments and evidence; redact before persisting or reporting failures.

## Layer Rules

CLI, daemon, reconciler, state, and health code access runtime behavior through the adapter. They must not construct independent Apple container subprocesses. Test doubles exercise policy and failure cases; live conformance and lifecycle runs establish support for the declared provider capabilities.

## Parser Boundary

Versioned codecs reject duplicate critical keys, partial documents, unknown required enum values, conflicting identity, and oversized output. They bind current-project UUIDs to exact identifiers, retain visible labeled orphans, and sort collections before calculating semantic digests. Names alone never establish ownership.

## Provider Selection, Migration, And Recovery

A project-generation binding remains authoritative. For an unbound project, `auto` prefers a compatible CLI provider and uses the native helper only when the CLI is unavailable and the helper can enforce the requested capabilities. Switching an existing project requires `hostwright runtime migrate`.

Migration binds confirmation to observations, capability digests, state, effects, and rollback actions. It acquires a new fence, verifies ownership and continuity, and advances the provider generation only after verification. Recovery rechecks the environment after provider, helper, OS, or process changes. Unsupported downgrades and future protocols stop safely.

## Mutation Boundary

Only current UUID-backed ownership authorizes managed changes. Creation requires local-image evidence and capability-qualified configuration. Completion and ambiguous effects require observation. The lifecycle coordinator composes replicas, dependencies, probes, updates, rollback, networking, and recovery; the provider executes bounded operations.

See [compatibility](../reference/compatibility.md) for the declared matrix and [limitations](../reference/limitations.md) for deferred behavior.
