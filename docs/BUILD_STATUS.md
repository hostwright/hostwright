# Build Status

## Local Environment

- macOS 26.5
- Apple silicon (`arm64`)
- Swift 6.3.2 through full Xcode developer tools

## Verified On 2026-07-01

- `swift build` succeeds after the XCTest foundation changes.
- `swift test list` lists real XCTest cases across Hostwright test targets.
- `swift test` executes real XCTest assertions across CLI, core, health, manifest, networking, observability, reconciler, runtime, and state targets.
- `scripts/grep-orchard.sh .` succeeds and reports historical references only in `docs/source-material/` and `docs/naming/`.
- `scripts/test.sh` succeeds and runs `swift build` plus `swift test`.

## Current Implementation Truth

- Phase 5 adds read-only Apple container observation infrastructure behind `RuntimeAdapter`.
- Phase 6 adds SQLite-backed local state for explicit database paths.
- Phase 7 adds deterministic non-mutating desired-vs-observed planning, typed drift records, typed plan issues, typed planned actions, and a deterministic plan hash.
- No Apple container command was called by Phase 6.
- `FoundationRuntimeProcessRunner` exists for policy-approved read-only command specs, but local verification in this session used fake process execution only.
- `AppleContainerReadOnlyAdapter` reports missing `container` as runtime unavailable and rejects mutation through the adapter contract.
- `AppleContainerObservationParser` accepts only the fixture-defined `hostwright.apple-container.observation.v1` schema and fails closed on unsupported output.
- `SQLiteStateStore` uses system `SQLite3`, schema migrations, transactions, and repository APIs for desired services, observed snapshots, events, operations, and ownership records.
- Phase 6 state tests use explicit temporary database paths only.
- Phase 7 planner tests use in-memory desired and observed runtime models only.
- No default user database path, hidden global database write, `apply`, cleanup, daemon loop, runtime mutation, CLI live runtime observation, or guaranteed live Apple container observation was implemented.

## SwiftPM Fixture Resources

The three Phase 5 text fixtures under `Tests/HostwrightRuntimeTests/Fixtures/` are declared as `HostwrightRuntimeTests` resources in `Package.swift`:

- `apple-container-list-empty.txt`
- `apple-container-list-running.txt`
- `apple-container-list-redaction.txt`

SwiftPM copies them during `swift test`, and the unhandled-resource warning is gone.

## XCTest Status

XCTest is available through a real SwiftPM test target in the current full Xcode toolchain.

Important diagnostic correction:

- `swift -e 'import XCTest'` can still fail and is not the correct gate.
- A minimal SwiftPM XCTest probe passed after Xcode was fixed.
- `swift test list` is the local proof that Hostwright now exposes real XCTest cases.
- `swift test` executes 59 XCTest cases after Phase 7.

The old top-level smoke/precondition posture has been replaced with XCTest assertions. Some test file names still include `Smoke.swift`, but the contents are XCTest cases.

## CI Limitation

The local `.github/workflows/ci.yml` template was not run and the hosted runner label was not verified because this session was local-only and used no network commands.

## Core Repo Boundary

The root `hostwright_naming_convention/` archive and original root source files remain present locally as preserved input material, but they are ignored for the core repository because normalized preserved copies live under `docs/source-material/originals/`, `docs/naming/`, and `assets/brand/originals/`.

The local `site/` folder is not part of the core repository. The public website/docs site belongs in the separate `hostwright.dev` repository.
