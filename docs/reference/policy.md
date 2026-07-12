# Policy Reference

Hostwright policy is local and deterministic. It explains why a planned input is allowed, warned, or blocked before any supported mutation path can run.

## Decision Shape

Policy decisions include:

- `category`: the policy area, such as `port`, `mount`, `image`, `secret`, `cleanup`, or `accelerator`;
- `reasonCode`: a stable machine-readable reason;
- `severity`: `allow`, `warning`, or `blocker`;
- `message`: human-readable explanation;
- `remediation`: operator guidance;
- `stableDetailKey`: deterministic ordering and comparison detail.

## Current Defaults

- Host publishes remain localhost-first.
- Broad bind addresses are blocked.
- Duplicate desired host ports and observed non-target host-port conflicts are blocked.
- Privileged host ports produce warnings in planning and are rejected by the current create path before mutation.
- Host-root and parent-traversal mount sources are blocked.
- Secret-like environment values are redacted from plans.
- Unresolved secret references block mutation.
- Cleanup deletes only resources classified as exact Hostwright-owned non-running eligible containers after dry-run token confirmation.
- Unsupported manifest fields, secure exposure, broad lifecycle actions, and accelerator requests fail closed.
- Stack-file import uses local policy reason codes when unsupported fields map to untrusted manifest, secure exposure, lifecycle, or mount-safety blockers.
- Advisory scheduling consumes local policy decisions for placement explanations and scores without changing the underlying policy gates.
- Extension declarations can be evaluated as local data. Built-in or reviewed-local non-mutating declarations can receive allow decisions only when required RuntimeAdapter, HostwrightState, local policy, redaction, audit, explicit-state-path, local-only, ownership, confirmation, and no-runtime-mutation boundaries are declared.
- Third-party, untrusted, unsupported-version, empty, missing-boundary, runtime-mutation, state-write, networking-provider, tunnel-provider, secret-resolution, and accelerator extension declarations fail closed.
- Team policy profiles can be evaluated as local data. Profiles must be explicit opt-in, versioned, auditable, and preserve required runtime, state, policy, redaction, audit, confirmation, ownership, local-only, and no-telemetry gates.
- Operational team profiles can only add stricter digest or manifest-review requirements. Approval records authorize one exact bound mutation; they never weaken or override required gates.

## What Policy Does Not Do

Policy evaluation does not:

- run Apple container commands;
- create, stop, start, restart, or delete containers;
- read or write SQLite directly;
- contact image registries;
- pull images;
- verify signatures, SBOMs, vulnerability reports, or provenance;
- upload telemetry;
- install DNS, tunnels, reverse proxies, or cloud integration;
- convert broad Docker Compose or orchestrator semantics into runtime behavior;
- expose Apple GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, or host-native accelerator helpers.
- place workloads, reserve capacity, expose a scheduler API, or perform remote placement.
- load, install, distribute, or execute plugins;
- contact a plugin registry;
- allow extension declarations to bypass RuntimeAdapter, HostwrightState, local policy, redaction, audit, confirmation, or ownership gates.
- provide a cloud team service, hosted audit log, central remote control, user tracking, enterprise support workflow, or remote policy distribution.

## Team Policy Boundary

There is no remote policy service, silent bypass, or runtime-mutating policy action. Team profiles are local, explicit opt-in, and enforced by the command layer only when an operator supplies their path. Exact approval records authorize a reviewed operation without bypassing hard-coded Hostwright safety gates.
