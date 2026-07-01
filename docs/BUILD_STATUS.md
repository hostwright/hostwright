# Build Status

## Local Environment

- macOS 26.5
- Apple silicon (`arm64`)
- Swift 6.3.2 through Command Line Tools

## Verified On 2026-07-01

- `swift build` succeeds after the Phase 6 SQLite state ledger changes.
- `swift test` succeeds as compile/link smoke verification, including Phase 5 runtime checks and Phase 6 temp-database state smoke checks.
- `scripts/grep-orchard.sh .` succeeds and reports historical references only in `docs/source-material/` and `docs/naming/`.
- `scripts/test.sh` succeeds and runs `swift build` plus `swift test`.

## Current Implementation Truth

- Phase 5 adds read-only Apple container observation infrastructure behind `RuntimeAdapter`.
- Phase 6 adds SQLite-backed local state for explicit database paths.
- No Apple container command was called by Phase 6.
- `FoundationRuntimeProcessRunner` exists for policy-approved read-only command specs, but local verification in this session used fake process execution only.
- `AppleContainerReadOnlyAdapter` reports missing `container` as runtime unavailable and rejects mutation through the adapter contract.
- `AppleContainerObservationParser` accepts only the fixture-defined `hostwright.apple-container.observation.v1` schema and fails closed on unsupported output.
- `SQLiteStateStore` uses system `SQLite3`, schema migrations, transactions, and repository APIs for desired services, observed snapshots, events, operations, and ownership records.
- Phase 6 state tests use explicit temporary database paths only.
- No default user database path, hidden global database write, `apply`, cleanup, daemon loop, runtime mutation, CLI-exposed observed runtime status, drift planner, or guaranteed live Apple container observation was implemented.

## SwiftPM Fixture Resources

The three Phase 5 text fixtures under `Tests/HostwrightRuntimeTests/Fixtures/` are declared as `HostwrightRuntimeTests` resources in `Package.swift`:

- `apple-container-list-empty.txt`
- `apple-container-list-running.txt`
- `apple-container-list-redaction.txt`

SwiftPM copies them during `swift test`, and the unhandled-resource warning is gone.

## Test Framework Limitation

This local Command Line Tools environment does not expose `XCTest` or Swift Testing as importable modules to SwiftPM test targets:

- `import XCTest` failed with `no such module 'XCTest'`.
- `import Testing` failed with `no such module 'Testing'`.

The test targets are therefore compile/link smoke targets. They prove the module boundaries and public APIs type-check under `swift test`, but they are not a substitute for executable unit tests. When a full test framework is available, replace these smoke files with real test cases.

The Phase 6 state smoke target does execute top-level precondition checks against a temporary SQLite database, but it is still not a substitute for structured XCTest or Swift Testing cases.

## CI Limitation

The local `.github/workflows/ci.yml` template was not run and the hosted runner label was not verified because this session was local-only and used no network commands.

## Core Repo Boundary

The root `hostwright_naming_convention/` archive and original root source files remain present locally as preserved input material, but they are ignored for the core repository because normalized preserved copies live under `docs/source-material/originals/`, `docs/naming/`, and `assets/brand/originals/`.

The local `site/` folder is not part of the core repository. The public website/docs site belongs in the separate `hostwright.dev` repository.
