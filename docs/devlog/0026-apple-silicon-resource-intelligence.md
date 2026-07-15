# Phase 26: Apple Silicon Resource Intelligence

Phase 26 adds a local resource-intelligence report boundary for Apple silicon development machines.

## What Changed

- Added health-layer resource report models for measurement method, hardware, OS, Apple container version evidence, workload profile, thermal state, unmeasured benchmark dimensions, architecture warnings, and limits.
- Wired `hostwright doctor --output json` to include resource reports when a local or injected resource snapshot is available.
- At Phase 26, kept the extended doctor resource report limited to ProcessInfo-backed host facts and Apple container executable lookup. Phase 02 issue #117 later added a separate bounded RuntimeAdapter CLI/service readiness probe without changing this resource-report methodology.
- Added fixture-backed parser tests and architecture-warning tests for non-arm64 image evidence.
- Added resource-intelligence methodology docs covering benchmark inputs, blocked evidence, and rejected claims.

## Rejected Paths

- No production density or capacity guarantee.
- No automatic placement or resource reservation.
- No GPU, ANE, Metal, Core ML, MLX, or accelerator scheduling support.
- No telemetry upload.
- No image pull or runtime mutation for resource-intelligence reporting.

## Evidence Boundary

Runtime density, VM-per-container overhead, boot latency, polling overhead, battery impact, sleep/wake behavior, and workload memory pressure remain unmeasured unless a future controlled disposable proof records them explicitly.
