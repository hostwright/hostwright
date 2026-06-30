# Devlog 0002: CLI and Manifest Foundation

## Goal

Add Phase 2 non-mutating CLI commands and a minimal `hostwright.yaml` manifest model while preserving the runtime safety boundary.

## Files Changed

- `Package.swift`
- `Sources/HostwrightCLI/*`
- `Sources/HostwrightCore/HostwrightIdentity.swift`
- `Sources/HostwrightManifest/*`
- `Sources/HostwrightReconciler/ReconciliationPlanner.swift`
- `Sources/HostwrightHealth/DoctorModels.swift`
- `Sources/HostwrightRuntime/RuntimeAdapter.swift`
- `Tests/Hostwright*/*`
- `README.md`
- `docs/reference/*`
- `docs/architecture/*`
- `docs/learning/MAINTAINER_SESSION_NOTES.md`
- `examples/*/hostwright.yaml`
- `schemas/hostwright-yaml.schema.json`

## Concepts Learned

- CLI command routing should not own manifest validation.
- A restricted manifest subset parser is safer than pretending to support all YAML without a dependency.
- `plan` can be useful while still being explicitly non-mutating.
- `status` must not fake runtime health.
- `doctor` can safely check local prerequisites without touching runtime state.

## Commands Run

```bash
swift build
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

## Risks

- The parser intentionally rejects unsupported YAML features.
- Smoke tests are not full unit tests because `XCTest` and Swift Testing are unavailable in this local toolchain.
- Runtime observation remains stubbed.
- Apple container CLI behavior is still unverified.

## Unknowns

- Whether a future dependency decision should use Swift ArgumentParser.
- Whether a future dependency decision should use a real YAML parser.
- Exact Apple container structured output and runtime behavior.
- Final SQLite implementation strategy.

## What I Need To Understand

- What each CLI command actually does.
- What each CLI command refuses to do.
- Why the manifest module exists.
- Why the parser fails closed.
- Why runtime mutation is still absent.

## Next Action

Do not implement `apply` yet. The next safe task is to harden tests and decide whether to add approved dependencies for ArgumentParser and YAML parsing.
