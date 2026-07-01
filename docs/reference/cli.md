# CLI Reference

The current CLI provides a dependency-free, non-mutating `hostwright` command surface.

## Commands

```bash
hostwright --version
hostwright init
hostwright validate [path]
hostwright plan [path]
hostwright status [path]
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

Reads and validates the manifest, then prints a non-mutating dry-run plan.

Runtime observation infrastructure exists behind `RuntimeAdapter`, but `hostwright plan` does not inspect Apple container and does not claim resources are running, stopped, healthy, or unhealthy.

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
