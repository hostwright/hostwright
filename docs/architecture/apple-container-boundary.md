# Apple Container Boundary

Apple container is the first planned runtime substrate.

## Boundary

Hostwright may adapt documented Apple container CLI behavior after local verification. It must not depend on private helper internals or undocumented behavior.

## Phase 1 State

The `AppleContainerCLIAdapter` type exists only as a non-mutating scaffold. It does not run `container`, inspect runtime state, or apply actions.

## Future Requirements

- Detect whether Apple container is installed.
- Prefer structured output when available.
- Convert runtime errors into Hostwright errors.
- Keep shell/process execution behind a single execution layer.
- Document unverified Apple container behavior in `docs/BUILD_STATUS.md`.

