# Phase 14: State Migrations And Upgrade Safety

## Summary

Phase 14 hardens the explicit SQLite state contract before daemon work begins.

## What Changed

- Added deterministic migration checksums while accepting the historical Phase 6 v1 checksum.
- Added schema compatibility checks for future versions, unknown migrations, checksum mismatch, unrelated existing databases, unmigrated databases, locked databases, and corrupt/non-SQLite files.
- Changed repository reads and writes to validate an already-migrated schema instead of applying migrations implicitly.
- Kept `SQLiteStateStore.migrate()` as the only migration path.
- Documented backup, restore, debug export, downgrade/future-version, corruption recovery, and single-writer locking policy.

## Rejected Paths

- No default state database path.
- No destructive reset command.
- No automatic state repair.
- No online backup, restore, or export command.
- No daemon behavior.
- No runtime mutation changes.

## Verification

Phase 14 adds XCTest coverage for repeated migrations with existing rows, transaction rollback, read-side-effect prevention, future schema refusal, checksum mismatch, unrelated database refusal, corrupt database classification, and lock contention. Full local verification is required before PR.
