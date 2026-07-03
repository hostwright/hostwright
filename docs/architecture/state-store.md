# State Store

Hostwright's intended local state store is SQLite.

## Purpose

The state store persists desired state, observed snapshots, events, operation records, and ownership records. Restart history and drift-specific records remain planned for later phases.

## Current State

Hostwright has a SQLite-backed state ledger inside `HostwrightState`. Create-only apply uses that ledger to persist apply intent before runtime mutation.

Implemented:

- explicit-path `SQLiteStateStore`
- schema migrations
- desired manifest snapshot persistence
- observed runtime snapshot persistence
- event ledger
- operation ledger records for mutation safety
- operation statuses for recorded, succeeded, and failed apply attempts
- ownership records for future cleanup/apply decisions
- temp-database smoke checks

Not implemented:

- multi-action `hostwright apply`
- runtime mutation beyond create-missing-service
- cleanup
- daemon loop
- drift planner
- production durability claims
- default user database path

## Requirements

- SQLite implementation must be isolated inside `HostwrightState`.
- Migrations must be explicit.
- Writes must be transactional.
- Operation records must survive process restart.
- Secrets must not be stored in plaintext state.

## Path Policy

Hostwright requires explicit database paths. It does not silently write to the repository, `~/Library/Application Support`, XDG paths, or any global location.

Tests use unique temporary database paths. Future CLI/dev commands may add an explicit state-path flag, but no default user path exists yet.

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

Normalized columns hold identifiers, project names, service names, timestamps, lifecycle states, operation status, event severity, and hashes.

JSON blobs hold ports, mounts, environment snapshots, runtime capabilities, runtime identifiers, event payloads, operation payloads, and ownership metadata. Payload fields are redacted before persistence.

## Transaction Boundaries

Transactions wrap:

- migrations
- desired project/service snapshot writes
- observed runtime snapshot plus observed service writes
- grouped event appends
- operation record creation
- operation success/failure updates
- ownership record upserts

No transaction performs runtime mutation. Apply writes intent first, leaves the transaction, calls `RuntimeAdapter`, then records success or failure.

## Module Boundary

SQL is not part of the CLI, reconciler, runtime, health, networking, or observability modules. Runtime observation remains behind `RuntimeAdapter`; state persistence records adapter-shaped observed data but does not call the adapter itself.
