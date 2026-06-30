# Doctor Checks

`hostwright doctor` performs safe local checks only.

## Implemented Checks

- Operating system version string.
- Apple silicon architecture and macOS 26+ compatibility.
- Swift toolchain version through a controlled `swift --version` process.
- Apple container CLI presence by executable lookup only.
- `hostwright.yaml` presence in the current directory.

## Safety Boundary

`doctor` does not run Apple container commands. It does not inspect containers, networks, volumes, images, logs, or runtime state.

If `container` is missing, `doctor` reports a warning instead of crashing.

