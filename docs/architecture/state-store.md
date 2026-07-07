# State Store

Hostwright's intended local state store is SQLite.

## Purpose

The state store persists desired state, observed snapshots, events, operation records, ownership records, health results, restart policy state, and managed restart recovery records. Broader drift-specific records remain planned for later phases.

## Current State

Hostwright has a SQLite-backed state ledger inside `HostwrightState`. Apply uses that ledger to persist operation intent before runtime mutation, and cleanup uses ownership records plus live observation before deleting an exact eligible managed container.

Implemented:

- explicit-path `SQLiteStateStore`
- schema migrations
- desired manifest snapshot persistence
- observed runtime snapshot persistence
- event ledger
- operation ledger records for mutation safety
- operation statuses for recorded, succeeded, and failed apply/cleanup attempts
- ownership records for apply and cleanup decisions
- health check result records
- restart policy state records
- restart recovery records
- temp-database smoke checks
- migration checksums and future-version refusal
- actionable corrupt/locked database failures
- read paths validate schema without applying migrations
- foreground daemon loop event and operation records

Not implemented:

- multi-action `hostwright apply`
- runtime mutation beyond create-missing-service, restart-policy-allowed managed start, restart-policy-allowed managed restart, and exact cleanup-eligible managed container delete
- broad cleanup, image cleanup, volume cleanup, or unmanaged cleanup
- drift planner
- production durability claims
- default user database path
- automatic state repair
- online backup/export commands
- launch agent or background daemon service

## Requirements

- SQLite implementation must be isolated inside `HostwrightState`.
- Migrations must be explicit.
- Writes must be transactional.
- Operation records must survive process restart.
- Secrets must not be stored in plaintext state.

## Path Policy

Hostwright requires explicit database paths. It does not silently write to the repository, `~/Library/Application Support`, XDG paths, or any global location.

Tests use unique temporary database paths. Future CLI/dev commands may add an explicit state-path flag, but no default user path exists yet.

## Migration And Compatibility Policy

`SQLiteStateStore.migrate()` is the only explicit migration path. Repository reads and writes validate the already-applied schema before accessing tables; they do not create a missing database, create `schema_migrations`, or apply migrations as a side effect.

Schema version 3 is the latest supported state schema. A database migrated by a newer Hostwright release fails closed with an incompatible-schema error. Hostwright does not downgrade state databases and does not attempt compatibility conversion.

Each migration records a checksum in `schema_migrations`. Current builds accept the historical Phase 6 checksum for schema version 1 and record an algorithmic checksum for fresh migrations. If a known migration version has an unexpected checksum, Hostwright fails before reading or writing application records.

## Schema

Version 1 creates:

- `schema_migrations`
- `projects`
- `desired_services`
- `observed_runtime_snapshots`
- `observed_services`
- `event_ledger`
- `operation_ledger`
- `ownership_records`

Version 2 creates:

- `health_check_results`
- `restart_policy_state`

Version 3 creates:

- `restart_recovery_records`

Normalized columns hold identifiers, project names, service names, timestamps, lifecycle states, operation status, event severity, restart status, and hashes.

JSON blobs hold ports, mounts, environment snapshots, runtime capabilities, runtime identifiers, event payloads, operation payloads, ownership metadata, health command/output metadata, and restart recovery completed-step metadata. Payload fields and manual recovery hints are redacted before persistence.

## Backup, Restore, And Export

State backup is a cold file operation today:

1. Stop any Hostwright CLI command or future daemon that is using the database.
2. Copy the explicit SQLite database path and its SQLite sidecar files if present, such as `state.sqlite-wal` and `state.sqlite-shm`.
3. Preserve file permissions and the full database contents. Ownership records, event records, operation records, and observed snapshots must stay together.

Restore is also a cold file operation:

1. Stop Hostwright processes using the target path.
2. Move the existing database aside instead of overwriting it.
3. Copy the backup database and sidecars into place.
4. Run a safe read command such as `hostwright events --state-db <path>` to verify the schema can be opened.

Debug export is manual in this phase. Copy the database to a private support location only after reviewing it for sensitive local paths, hostnames, project names, and redacted-but-contextual metadata. Hostwright does not upload telemetry or state.

Corruption recovery is manual. If Hostwright reports a corrupt or non-SQLite database, keep the file for investigation, restore from a known-good cold backup, or choose a new explicit database path. Hostwright does not invent ownership records, repair rows, or erase state automatically.

## Concurrency And Locking

Hostwright uses SQLite `FULLMUTEX`, a bounded busy timeout, and `BEGIN IMMEDIATE` for transactional writes. The contract remains single-writer: one CLI command or future daemon may write a state database at a time.

Read commands validate schema through read-only connections. Write commands run explicit migration before persistence, then use transactions for grouped writes. If another process holds an exclusive or write lock beyond the bounded timeout, Hostwright reports a locked state database instead of waiting indefinitely.

## Transaction Boundaries

Transactions wrap:

- migrations
- desired project/service snapshot writes
- observed runtime snapshot plus observed service writes
- grouped event appends
- operation record creation
- operation success/failure updates
- ownership record upserts

No transaction performs runtime mutation. Apply and cleanup write intent first, leave the transaction, call `RuntimeAdapter`, then record success or failure.

## Module Boundary

SQL is not part of the CLI, reconciler, runtime, health, networking, or observability modules. Runtime observation remains behind `RuntimeAdapter`; state persistence records adapter-shaped observed data but does not call the adapter itself.
