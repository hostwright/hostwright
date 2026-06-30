# State Store

Hostwright's intended local state store is SQLite.

## Purpose

The state store will persist desired state, observed snapshots, events, operation records, restart history, and drift information.

## Phase 1 State

Phase 1 defines state-store interfaces only. It does not create a SQLite schema, migrations, or a database file.

## Requirements

- SQLite implementation must be isolated inside `HostwrightState`.
- Migrations must be explicit.
- Writes must be transactional.
- Operation records must survive process restart.
- Secrets must not be stored in plaintext state.

