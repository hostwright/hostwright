# Build Status

## Local Environment

- macOS 26.5
- Apple silicon (`arm64`)
- Swift 6.3.2 through full Xcode developer tools

## Verified On 2026-07-03

- `swift build` succeeds after the Phase 9 operability changes.
- `swift test list` lists 82 real XCTest cases across Hostwright test targets.
- `swift test` executes 82 real XCTest assertions across CLI, core, health, manifest, networking, observability, reconciler, runtime, and state targets with 0 failures.
- `scripts/grep-orchard.sh .` succeeds and reports historical references only in `docs/source-material/` and `docs/naming/`.
- `scripts/test.sh` succeeds and runs `swift build` plus `swift test`.
- Apple container 1.0.0 is installed locally at `/usr/local/bin/container`.
- `container system status` reports the container system service as running.
- `container list --all --format json` returned the verified empty runtime shape `[]`.
- A disposable local image `hostwright-proof-web:phase8b` was built from the Apple tutorial-style `python:alpine` flow.
- `hostwright apply` created exactly one Apple container named `hostwright-proof-web` through `RuntimeAdapter`.
- A stale repeat apply using the old plan hash was rejected before any second mutation.
- Exact proof cleanup removed `hostwright-proof-web` and `hostwright-proof-web:phase8b` without `--all` or `--force`.
- Phase 9 live proof used existing local image `docker.io/library/python:alpine` without pulling images.
- `hostwright apply` created `hostwright-phase9proof-web`.
- A second confirmed `hostwright apply` started `hostwright-phase9proof-web` through `startManagedService`; the container exited/stopped after `python3 --version`.
- `hostwright logs web ... --tail 20` returned `Python 3.14.6`.
- `hostwright cleanup --dry-run` produced token `cleanup-8ecbbdd9ef3cdd74`.
- `hostwright cleanup --confirm-cleanup cleanup-8ecbbdd9ef3cdd74` deleted exactly `hostwright-phase9proof-web`.
- `container list --all` after cleanup showed only Apple builder runtime state.

## Current Implementation Truth

- Phase 5 adds read-only Apple container observation infrastructure behind `RuntimeAdapter`.
- Phase 6 adds SQLite-backed local state for explicit database paths.
- Phase 7 adds deterministic non-mutating desired-vs-observed planning, typed drift records, typed plan issues, typed planned actions, and a deterministic plan hash.
- Phase 8A adds parser and fixture support for the verified real empty Apple container JSON list output.
- Phase 8B adds a create-only apply gate that requires explicit state DB path, explicit plan hash confirmation, operation intent persistence before mutation, and RuntimeAdapter execution.
- Phase 9 adds live `status --state-db`, bounded `logs`, event rendering, one restart-policy-allowed managed start action, and ownership-based cleanup for exact stopped/created/exited containers.
- No Apple container command was called by Phase 6 or Phase 7.
- `FoundationRuntimeProcessRunner` exists for policy-approved read-only command specs and supported mutation specs; automated tests still use fake process execution.
- `AppleContainerReadOnlyAdapter` reports missing `container` as runtime unavailable and rejects mutation through the adapter contract.
- `AppleContainerObservationParser` accepts the fixture-defined `hostwright.apple-container.observation.v1` schema, the verified real empty JSON array shape `[]`, Apple builder container list output, and the verified created/stopped proof container output.
- `AppleContainerImageListParser` accepts the verified real object-based image list shape with `configuration.name`.
- `SQLiteStateStore` uses system `SQLite3`, schema migrations, transactions, and repository APIs for desired services, observed snapshots, events, operations, and ownership records.
- Phase 6 state tests use explicit temporary database paths only.
- Phase 7 planner tests use in-memory desired and observed runtime models only.
- No default user database path, hidden global database write, daemon loop, multi-action apply, stop/restart/remove, image deletion, volume deletion, broad cleanup, or CLI Apple container shell-out bypass was implemented.
- Live mutation proofs were run only for exact disposable Hostwright-owned proof containers and then cleaned up.

## SwiftPM Fixture Resources

The runtime text fixtures under `Tests/HostwrightRuntimeTests/Fixtures/` are declared as `HostwrightRuntimeTests` resources in `Package.swift`:

- `apple-container-list-empty.txt`
- `apple-container-list-empty-real-json.txt`
- `apple-container-list-builder-real-json.txt`
- `apple-container-list-proof-created-real-json.txt`
- `apple-container-list-running.txt`
- `apple-container-list-redaction.txt`
- `apple-container-image-list-real-json.txt`

SwiftPM copies them during `swift test`, and the unhandled-resource warning is gone.

## XCTest Status

XCTest is available through a real SwiftPM test target in the current full Xcode toolchain.

Important diagnostic correction:

- `swift -e 'import XCTest'` can still fail and is not the correct gate.
- A minimal SwiftPM XCTest probe passed after Xcode was fixed.
- `swift test list` is the local proof that Hostwright now exposes real XCTest cases.
- `swift test` executes 82 XCTest cases after the Phase 9 operability update.

The old top-level smoke/precondition posture has been replaced with XCTest assertions. Some test file names still include `Smoke.swift`, but the contents are XCTest cases.

## CI Limitation

The local `.github/workflows/ci.yml` template was not run and the hosted runner label was not verified because this session was local-only and used no network commands.

## Core Repo Boundary

The root `hostwright_naming_convention/` archive and original root source files remain present locally as preserved input material, but they are ignored for the core repository because normalized preserved copies live under `docs/source-material/originals/`, `docs/naming/`, and `assets/brand/originals/`.

The local `site/` folder is not part of the core repository. The public website/docs site belongs in the separate `hostwright.dev` repository.
