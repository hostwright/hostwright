# Resource Intelligence Methodology

Status: Phase 26 local reporting boundary.

Phase 26 adds resource intelligence as local diagnostic reporting, not capacity management. The report model records the measurement method, host facts, Apple container version evidence, workload profile, unmeasured dimensions, architecture warnings, and limits.

## Implemented Report Fields

- Measurement method: `localProcessInfoSnapshot` for live doctor facts, or `fixture` for parser tests and reviewed evidence.
- Hardware: architecture, active processor count, physical memory bytes, and a unified-memory note.
- Operating system: OS description and macOS major version.
- Apple container: executable path and version evidence. Live `doctor` does not run Apple container commands, so version is unavailable unless supplied by an injected fixture.
- Workload profile: general local containers or local AI memory-pressure study.
- Resource observations: memory pressure, boot latency, polling overhead, sleep/wake, battery, and thermal state.
- Architecture warnings: non-arm64 image warnings only when a runtime or fixture reports image architecture evidence.
- Limits: no production density guarantee, no accelerator scheduling, no telemetry upload, and no resource-intelligence runtime mutation.

## Live Proof Boundary

Live `doctor` uses local process information only:

- `ProcessInfo.physicalMemory`
- `ProcessInfo.activeProcessorCount`
- `ProcessInfo.thermalState`
- OS version and architecture from the existing compatibility snapshot
- Apple container executable lookup only

It does not create, start, stop, delete, inspect, or observe containers. It does not run `container --version`, pull images, run benchmarks, or write state.

## Benchmark Methodology

Future benchmark runs must record:

- Host model, CPU architecture, memory, OS version, Apple container version, power state, and thermal state.
- Exact image reference and reported image architecture.
- Whether the image was already local before the run.
- Number of containers, workload class, command, runtime duration, and cleanup evidence.
- Boot latency, polling overhead, memory pressure, battery state, sleep/wake behavior, and thermal behavior as separate observations.
- Whether the run used a disposable Hostwright-owned resource.

If any dimension is not measured, the report must say `unmeasured` instead of inferring a value.

## Blocked Evidence

The current implementation does not measure runtime density, VM-per-container overhead, boot latency, polling overhead, battery impact, sleep/wake behavior, or workload memory pressure. These require controlled disposable runtime proofs and maintainer-approved cleanup for every created resource.

Apple container version drift monitoring remains a reporting input, not a live command in `doctor`. A future implementation can add a RuntimeAdapter-backed version probe or a separate benchmark command only after the command shape, timeout, redaction, and no-mutation boundary are reviewed.

Phase 31 advisory scheduling may consume resource reports as coarse local host facts, but it must keep capacity, memory pressure, density, and placement claims advisory. It does not turn resource intelligence into reservation, automatic placement, or production capacity planning.

Accelerator evidence remains separate from resource intelligence. See [Accelerator Boundary Research](accelerator-boundary-research.md) for the Phase 27 decision record covering Apple GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator helpers, and scheduler placeholders.

## Rejected Claims

Resource intelligence is not:

- production capacity planning;
- automatic placement or resource reservation;
- accelerator-aware scheduling;
- GPU, ANE, Metal, Core ML, or MLX support;
- external telemetry;
- hosted diagnostics;
- automatic image pull or registry inspection.
