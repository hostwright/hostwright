# Phase 6: SQLite State And Event Ledger

## Goal

Add durable local state for Hostwright without implementing runtime mutation.

Phase 6 introduces SQLite-backed persistence for desired state, observed runtime snapshots, events, operation records, and ownership records. It does not add `apply`, cleanup, drift planning, daemon scheduling, or runtime mutation.

## What Changed

- Added system `SQLite3` usage through a small internal wrapper in `HostwrightState`.
- Added explicit-path `SQLiteStateStore`.
- Added schema migration version 1.
- Added repositories for desired state, observed state, event ledger, operation ledger, and ownership records.
- Added redaction before persistence for sensitive env and payload fields.
- Added temp-database smoke checks.
- Updated requirements, acceptance gates, limitations, build status, maintainer notes, and the implementation plan.

## Files Changed

- `Package.swift`
- `Sources/HostwrightState/StateStore.swift`
- `Sources/HostwrightState/StateStoreConfiguration.swift`
- `Sources/HostwrightState/StateStoreError.swift`
- `Sources/HostwrightState/SQLiteConnection.swift`
- `Sources/HostwrightState/SQLiteStatement.swift`
- `Sources/HostwrightState/SQLiteStateStore.swift`
- `Sources/HostwrightState/MigrationRunner.swift`
- `Sources/HostwrightState/StateRecords.swift`
- `Sources/HostwrightState/StateRepositories.swift`
- `Sources/HostwrightState/StateJSON.swift`
- `Tests/HostwrightStateTests/HostwrightStateSmoke.swift`
- `docs/architecture/state-store.md`
- `docs/requirements/REQUIREMENTS.md`
- `docs/requirements/ACCEPTANCE_MATRIX.md`
- `docs/reference/limitations.md`
- `docs/BUILD_STATUS.md`
- `docs/learning/MAINTAINER_SESSION_NOTES.md`
- `docs/IMPLEMENTATION_PLAN.md`

## Concepts Learned

- SQLite gives Hostwright local durability without a background service.
- Migrations make schema changes explicit and replayable.
- Transactions keep multi-row state changes atomic.
- Desired state, observed state, events, operations, and ownership are separate ledgers.
- Operation records are future safety records, not execution.
- Ownership records are future cleanup inputs, not cleanup.
- Explicit database paths prevent hidden user/global writes.
- Redaction must happen before persistence.

## Commands To Run

```bash
swift build
swift test
scripts/grep-orchard.sh .
scripts/test.sh
git status --short
git diff --stat
git diff --name-only
```

## Risks

- The SQLite wrapper is intentionally small and needs careful review.
- Smoke tests are weaker than XCTest or Swift Testing.
- Redaction is useful but not a complete secret-management system.
- JSON blobs are pragmatic for Phase 6 but may need normalization as query needs become clearer.
- Production durability, backup, corruption recovery, and concurrency guarantees are not claimed.

## Unknowns

- Whether CI will expose the same `SQLite3` module behavior as this local macOS toolchain.
- Whether future state queries need more normalized columns.
- Which explicit CLI/dev state path UX should be added later.

## What I Need To Understand

- Why Phase 6 is persistence-only.
- Why explicit paths are required.
- What each schema table stores.
- Why redaction happens before writes.
- Why state must not call runtime.
- Why drift planning belongs to Phase 7.
- Why mutation belongs to Phase 8.

## Next Action

Review the Phase 6 diff. If approved, commit it as:

```text
feat(state): add SQLite state and event ledger
```
