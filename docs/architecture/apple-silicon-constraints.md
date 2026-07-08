# Apple Silicon Constraints

Hostwright targets Apple silicon Macs on macOS 26+ for the first supported release.

## Current State

The Swift package declares macOS 26 as the package platform. Runtime compatibility checks are modelled in code, and `hostwright doctor` can emit a local resource intelligence report based on host `ProcessInfo` facts and Apple container executable lookup.

The resource report records hardware, OS, workload profile, current thermal state, and unmeasured benchmark dimensions separately. It does not inspect Apple container state, run Apple container commands, pull images, create proof containers, or write state.

See [Resource Intelligence Methodology](resource-intelligence.md) for the Phase 26 measurement boundary and [Accelerator Boundary Research](accelerator-boundary-research.md) for the Phase 27 accelerator decision record.

## Constraints

- Intel Macs are not part of the first supported release.
- macOS versions before 26 are not part of the first supported release.
- GPU, ANE, Metal, Core ML, and MLX support inside containers is not claimed.
- PyTorch MPS, host-native accelerator helpers, accelerator device exposure, and accelerator-aware scheduling are not implemented.
- Non-arm64 image architecture warnings require explicit runtime or fixture evidence; Hostwright does not infer Rosetta behavior without that evidence.
- Runtime density, VM-per-container overhead, boot latency, memory pressure, polling overhead, sleep/wake, battery, and workload memory-pressure behavior require controlled future measurement before any capacity claim.
