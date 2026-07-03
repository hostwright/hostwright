# CLI Reference

The current CLI provides a dependency-free `hostwright` command surface with one narrow create-only mutation gate.

## Commands

```bash
hostwright --version
hostwright init
hostwright validate [path]
hostwright plan [path]
hostwright status [path]
hostwright apply [path] --state-db <path> --confirm-plan <hash>
hostwright doctor
```

## `hostwright --version`

Prints the development version:

```text
0.0.0-dev
```

## `hostwright init`

Creates `hostwright.yaml` in the current directory only when the file does not already exist.

`--force` is not implemented; existing manifests are not overwritten.

## `hostwright validate [path]`

Reads `hostwright.yaml` by default, or a provided path, and validates the restricted Hostwright manifest shape.

It does not:

- contact registries;
- contact Apple container;
- check whether images exist remotely;
- mutate runtime state.

## `hostwright plan [path]`

Reads and validates the manifest, maps the supported manifest subset into runtime-shaped desired state, runs planning policy checks, and prints a non-mutating dry-run plan.

The output includes a deterministic plan hash, typed issues, typed planned actions, and an explicit execution-unavailable notice.

Runtime observation infrastructure exists behind `RuntimeAdapter`, but `hostwright plan` does not inspect Apple container by default and does not claim resources are running, stopped, healthy, or unhealthy.

## `hostwright apply [path] --state-db <path> --confirm-plan <hash>`

Runs the create-only apply gate.

This command:

- validates the manifest;
- observes Apple container through `RuntimeAdapter`;
- recomputes the deterministic plan;
- requires an explicit state database path;
- requires the supplied plan hash to match the current observed plan;
- persists desired state, observed state, operation intent, and an apply-start event before mutation;
- executes exactly one `createMissingService` action through `RuntimeAdapter`;
- records success or failure events and operation status.

It refuses mutation when:

- `--state-db` is missing;
- `--confirm-plan` is missing or mismatched;
- runtime observation fails;
- the plan has blockers;
- zero executable create actions exist;
- more than one executable create action exists;
- the service uses mounts, sensitive environment values, privileged host ports, or broad bind addresses;
- the local Apple container image cannot be confirmed.

It does not implement start, stop, delete, restart, remove, cleanup, rollback, image pull, daemon loops, or multi-action apply.

## `hostwright status [path]`

Reports manifest-level status only.

It does not inspect runtime state and must not be interpreted as service status.

## `hostwright doctor`

Runs safe local checks only:

- OS version string;
- architecture/macOS compatibility gate;
- Swift toolchain version through a controlled `swift --version` process;
- `container` executable lookup only;
- `hostwright.yaml` presence.

`doctor` does not run Apple container commands.
