# Apple Silicon Constraints

Hostwright targets Apple silicon Macs on macOS 26+ for the first supported release.

## Phase 1 State

The Swift package declares macOS 26 as the package platform. Runtime compatibility checks are modelled in code but do not inspect Apple container state.

## Constraints

- Intel Macs are not part of the first supported release.
- macOS versions before 26 are not part of the first supported release.
- GPU, ANE, Metal, Core ML, and MLX support inside containers is not claimed.
- Rosetta behavior is not claimed.
- Sleep/wake, memory pressure, and thermal behavior require future measurement.

