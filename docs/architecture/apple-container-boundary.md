# Apple Container Boundary

Apple container is the first planned runtime substrate.

## Boundary

Hostwright may adapt documented Apple container CLI behavior after local verification. It must not depend on private helper internals or undocumented behavior.

## Current State

`AppleContainerReadOnlyAdapter` can attempt read-only observation through `RuntimeAdapter`. `AppleContainerApplyAdapter` can execute only the currently supported narrow mutation commands through the same boundary.

The adapters:

- resolves the `container` executable through `RuntimeExecutableResolver`;
- build command specs in `AppleContainerCommand`;
- run only policy-approved specs through `FoundationRuntimeProcessRunner`;
- parse only fixture-defined and locally verified observation output;
- reports missing executables as runtime unavailable;
- reports unsupported output as parse failure.

The current list-style command shape is an adapter assumption based on verified local output, not a public Apple CLI compatibility claim. If local output does not match the supported parser schema, Hostwright must fail closed.

Supported mutation is limited to:

- create one missing Hostwright-managed service after plan-hash confirmation and local-image checks;
- start one exact Hostwright-managed stopped/created/exited service when restart policy allows it;
- internally stop then start one exact Hostwright-managed running/unhealthy service when restart policy allows managed restart;
- delete exact cleanup-eligible Hostwright-owned stopped/created/exited containers after dry-run token confirmation.

The adapter does not expose public stop/restart commands, remove broadly, run, pull, push, build, exec, attach, use `--all`, use `--force`, delete images, delete volumes, install services, or mutate unmanaged resources.

## Future Requirements

- Verify additional Apple container output shapes before documenting broader command compatibility.
- Prefer documented structured output when available.
- Convert runtime errors into Hostwright errors.
- Keep shell/process execution behind `RuntimeAdapter` and `RuntimeProcessRunning`.
- Document unverified Apple container behavior in `docs/BUILD_STATUS.md`.
