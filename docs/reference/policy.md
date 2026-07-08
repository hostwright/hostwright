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
- expose Apple GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, or host-native accelerator helpers.

## Override Boundary

There is no remote policy service, team policy workflow, silent bypass, or runtime-mutating policy action in this phase. Future policy profiles or team defaults require a separate issue and must preserve local deterministic evaluation first.
