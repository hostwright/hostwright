# Doctor Checks

`hostwright doctor` performs safe local checks only.

## Implemented Checks

- Operating system version string.
- Apple silicon architecture and macOS 26+ compatibility.
- Swift toolchain version through a controlled `swift --version` process.
- Apple container CLI presence by executable lookup only.
- `hostwright.yaml` presence in the current directory.
- Explicit state database path policy.
- Local-only telemetry policy.
- Resource intelligence reporting with local host facts, explicit unmeasured benchmark dimensions, and no capacity guarantee.

## Safety Boundary

`doctor` does not run Apple container commands. It does not inspect containers, networks, volumes, images, logs, or runtime state. Runtime observation exists only behind `RuntimeAdapter`; doctor remains a diagnostic executable-presence check plus local policy and resource reporting.

The resource intelligence report uses local process information for hardware, OS, and current thermal facts. Apple container version is unavailable in live doctor output unless supplied by an injected or fixture-backed report. Boot latency, runtime density, VM overhead, polling overhead, sleep/wake behavior, battery behavior, and workload memory pressure remain unmeasured in doctor; `hostwright benchmark` records a separate explicit local evidence report for its supported bounded dimensions.

If `container` is missing, `doctor` reports a warning instead of crashing.
