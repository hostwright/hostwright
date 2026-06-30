# Devlog 0001: Phase 0/1 Foundation

## Goal

Turn the local Hostwright source-material folder into a serious repository foundation without deleting original material, overclaiming runtime behavior, or implementing unsafe infrastructure features too early.

Phase 0 established preservation, naming, documentation, examples, scripts, and safety boundaries. Phase 1 established a dependency-free Swift Package Manager skeleton with CLI, daemon, library modules, and compile-only smoke test targets.

## Files Changed

Created top-level project files:

- `README.md`
- `LICENSE`
- `CONTRIBUTING.md`
- `SECURITY.md`
- `GOVERNANCE.md`
- `CODE_OF_CONDUCT.md`
- `.gitignore`
- `Package.swift`

Created Swift source layout:

- `Sources/HostwrightCLI/`
- `Sources/HostwrightDaemon/`
- `Sources/HostwrightCore/`
- `Sources/HostwrightRuntime/`
- `Sources/HostwrightState/`
- `Sources/HostwrightReconciler/`
- `Sources/HostwrightHealth/`
- `Sources/HostwrightNetworking/`
- `Sources/HostwrightObservability/`

Created smoke test layout:

- `Tests/HostwrightCLITests/`
- `Tests/HostwrightCoreTests/`
- `Tests/HostwrightRuntimeTests/`
- `Tests/HostwrightStateTests/`
- `Tests/HostwrightReconcilerTests/`
- `Tests/HostwrightHealthTests/`
- `Tests/HostwrightNetworkingTests/`
- `Tests/HostwrightObservabilityTests/`

Created documentation:

- `docs/IMPLEMENTATION_PLAN.md`
- `docs/RISK_REGISTER.md`
- `docs/PROJECT_CHARTER.md`
- `docs/BUILD_STATUS.md`
- `docs/source-material/README.md`
- `docs/naming/*`
- `docs/architecture/*`
- `docs/design/*`
- `docs/reference/*`
- `docs/learning/MAINTAINER_SESSION_NOTES.md`

Created support material:

- `examples/single-service/hostwright.yaml`
- `examples/api-redis/hostwright.yaml`
- `schemas/hostwright-yaml.schema.json`
- `scripts/dev.sh`
- `scripts/test.sh`
- `scripts/lint.sh`
- `scripts/grep-orchard.sh`
- `.github/*`
- `assets/brand/README.md`

Preserved copied originals:

- `docs/source-material/originals/*`
- `assets/brand/originals/*`

The original root source documents and PNGs were left in place.

## Concepts Learned

- Source material is evidence. Preserve it before normalizing a repository.
- Hostwright is the canonical public identity; the old codename is historical source-material context only.
- A Swift package is organized around products and targets.
- Executable targets produce binaries such as `hostwright` and `hostwrightd`.
- Library targets define module boundaries.
- Runtime behavior must go through `RuntimeAdapter`.
- A daemon scaffold is not the same as an installed daemon or background service.
- Desired state, observed state, and runtime plans are separate concepts.
- Dry-run planning must exist before runtime mutation.
- Apple container behavior should not be claimed until verified locally.
- Compile-only smoke tests prove module imports and type-checking, not full behavioral correctness.

## Commands Run

Preservation and inspection:

```bash
shasum -a 256 <source files>
find docs/source-material/originals assets/brand/originals -type f -print0 | sort -z | xargs -0 shasum -a 256
```

SwiftPM platform and test probes:

```bash
swift package dump-package
swift test --package-path <scratch probe>
```

Approved verification:

```bash
swift build
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

## Verification Result

- `swift build` passed.
- `swift test` passed as compile-only smoke verification.
- `scripts/test.sh` passed.
- `scripts/grep-orchard.sh .` reported only allowed historical naming references.

## Risks

- The current test targets are smoke checks, not full unit tests.
- `hostwrightd` is only a scaffold and does not run a daemon loop.
- `AppleContainerCLIAdapter` does not observe or mutate Apple container runtime state.
- SQLite is not implemented yet.
- Manifest parsing is not implemented yet.
- The schema is a draft and is not wired into Swift code.
- The CI workflow is a local template and has not been run on a hosted runner.
- PNG assets are source material only, not final transparent/vector production assets.

## Unknowns

- Whether Apple container CLI is installed and what structured output is available.
- Exact Apple container commands and failure modes to support first.
- Final SQLite dependency decision and migration strategy.
- Whether local development should use XCTest, Swift Testing, or another approved test setup once the toolchain issue is resolved.
- Whether the hosted CI runner label in `.github/workflows/ci.yml` is valid.
- Final public GitHub/domain ownership status.

## What I Need To Understand

- Why Phase 0 was preservation and repo normalization, not feature implementation.
- Why Phase 1 created module boundaries before implementing behavior.
- Why `RuntimeAdapter` is the critical safety boundary.
- Why shelling out must not be scattered through CLI, daemon, or reconciler code.
- Why runtime mutation waits until dry-run planning, confirmation design, and adapter behavior exist.
- Why old codename references are allowed only in source-material and naming-history contexts.
- Why current tests are weaker than true unit tests.

## Next Action

Do not implement runtime mutation next.

The next safe task is Phase 2 CLI skeleton work for non-mutating commands only:

1. Define command parsing approach without adding dependencies unless approved.
2. Implement `hostwright --version`.
3. Implement `hostwright doctor` as local environment checks only.
4. Keep `hostwright plan`, `validate`, and `status` non-mutating.
5. Add real tests once a supported test framework path is available.
