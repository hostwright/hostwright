# Apple Container Boundary

Apple container is the first planned runtime substrate.

## Boundary

Hostwright may adapt documented Apple container CLI behavior after local verification. It must not depend on private helper internals or undocumented behavior.

## Phase 5 State

`AppleContainerReadOnlyAdapter` can attempt read-only observation through `RuntimeAdapter`.

The adapter:

- resolves the `container` executable through `RuntimeExecutableResolver`;
- builds read-only command specs in `AppleContainerCommand`;
- runs only policy-approved read-only specs through `FoundationRuntimeProcessRunner`;
- parses only fixture-defined observation output;
- reports missing executables as runtime unavailable;
- reports unsupported output as parse failure.

The current list-style command shape is a Phase 5 adapter assumption, not a public Apple CLI compatibility claim. If local output does not match the Phase 5 parser schema, Hostwright must fail closed.

The adapter does not create, start, stop, delete, restart, remove, clean up, apply, install, or mutate anything.

## Future Requirements

- Verify actual Apple container read-only output shape before documenting public command compatibility.
- Prefer documented structured output when available.
- Convert runtime errors into Hostwright errors.
- Keep shell/process execution behind `RuntimeAdapter` and `RuntimeProcessRunning`.
- Document unverified Apple container behavior in `docs/BUILD_STATUS.md`.
