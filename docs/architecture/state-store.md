# State Store

Hostwright's intended local state store is SQLite.

## Purpose

The state store persists desired state, observed snapshots, events, operation records, ownership records, health results, restart policy state, managed restart recovery records, operation recovery groups, and redacted diagnostics export data. Broader drift-specific records remain planned for later phases.

## Current State

Hostwright has a SQLite-backed state ledger inside `HostwrightState`. Apply uses that ledger to persist operation intent before runtime mutation, and cleanup uses ownership records plus live observation before deleting an exact eligible managed container.

Implemented:

- secure Application Support default plus explicit/environment-selected `SQLiteStateStore`
- private macOS configuration, state, runtime, metadata, backup, cache, and log layout
- deterministic path precedence and machine-readable `hostwright paths` status
- `0700` owned-directory and `0600` sensitive-file enforcement
- journaled, identity-bound `~/.hostwright/state.sqlite` migration with crash resume and active-writer refusal
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
- operation recovery groups and step records
- local redacted diagnostics export from existing state rows
- real temporary-database integration checks across multiple connections
- migration checksums, contiguous-history validation, and future-version refusal
- actionable corrupt/locked database failures
- read paths validate schema without applying migrations
- cold backup/restore round-trip coverage for committed rows
- atomic operation-group acquisition coverage across concurrent stores
- foreground daemon loop event and operation records

Not implemented:

- multi-action `hostwright apply`
- runtime mutation beyond create-missing-service, restart-policy-allowed managed start, restart-policy-allowed managed restart, and exact cleanup-eligible managed container delete
- broad cleanup, image cleanup, volume cleanup, or unmanaged cleanup
- drift planner
- production durability claims
- automatic state repair
- online backup/restore/repair commands
- launch agent or background daemon service

## Requirements

- SQLite implementation must be isolated inside `HostwrightState`.
- Migrations must be explicit.
- Writes must be transactional.
- Operation records must survive process restart.
- Secrets must not be stored in plaintext state.

## Path Policy

The default database is `~/Library/Application Support/Hostwright/state/state.sqlite`. Command-line `--state-db` wins over `HOSTWRIGHT_STATE_DB`, which wins over the default. No default writes occur in the repository, current working directory, XDG locations, or global system directories.

State-writing commands create the Hostwright-owned layout with mode `0700` and sensitive files with mode `0600`, independent of the caller's `umask`. Before use, the complete path chain must be safely owned and non-writable by group/other users; user-controlled symlinks, access-granting extended ACL entries, hard-linked sensitive files, wrong-owner files, special bits, and ambiguous paths fail closed. Tests resolve the same contract beneath unique temporary home directories.

The default path performs a journaled migration of a compatible `~/.hostwright/state.sqlite`. The migration records device/inode identity, synchronizes intent and directories, acquires an exclusive SQLite transaction, atomically renames, resumes after interruption, and preserves every unknown legacy file. Explicit and environment-selected databases never trigger an implicit legacy move.

The normative path table, environment hooks, command creation semantics, status values, and recovery procedure are in [Local Paths, Permissions, and Legacy Migration](../reference/local-paths.md).

## Migration And Compatibility Policy

`SQLiteStateStore.migrate()` is the only explicit migration path. Repository reads and writes validate the already-applied schema before accessing tables; they do not create a missing database, create `schema_migrations`, or apply migrations as a side effect.

Schema version 7 is the latest supported state schema. A database migrated by a newer Hostwright release fails closed with an incompatible-schema error. Hostwright does not downgrade state databases or silently convert provider ownership.

Each migration records a checksum in `schema_migrations`. Current builds accept the historical Phase 6 checksum for schema version 1 and record an algorithmic checksum for fresh migrations. If a known migration version has an unexpected checksum, Hostwright fails before reading or writing application records.

Applied migration history must be a contiguous prefix beginning at version 1. A database that records a later migration while omitting an earlier version fails before schema-version reads, repository access, or migration. Hostwright does not infer, replay, or silently repair out-of-order migration history. A valid older contiguous prefix remains eligible for explicit forward migration.

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

Version 4 creates:

- `operation_groups`
- `operation_group_steps`

Version 5 backfills legacy ownership rows that used the pre-adapter-guard runtime adapter sentinel.

Version 6 adds exact observed resource identifiers, observed network JSON, and ownership identity versions. Existing observed rows are backfilled with their legacy identifier and existing ownership rows remain identity version 1; new labeled resources are written as identity version 2.

Version 7 locks the v0.0.2 identity and recovery foundation:

- projects gain `resource_uuid`, `manifest_version`, `mutation_provider`, and `provider_generation`;
- ownership records gain `resource_uuid` and `resource_generation`;
- operation groups gain `fencing_token`, `intent_json_redacted`, `compensation_json_redacted`, and `verification_json_redacted`;
- unique indexes enforce resource identity;
- legacy projects, ownership rows, and operation groups receive deterministic UUID/fencing backfills so migration is idempotent; one unambiguous owned instance can retain its desired-service UUID, while duplicate legacy instances receive distinct UUIDs derived from their ownership record IDs;
- the migration checksum includes the non-SQL backfill implementation revision, so binaries with different transformation logic cannot claim the same schema-v7 migration;
- a project generation cannot silently change mutation provider.

Phase 04 completes the durable operation DAG/saga executor and Phase 08 completes unattended checkpoint recovery. Schema v7 records the required identity and intent surface now so later mutation paths cannot invent incompatible ledgers.

Normalized columns hold identifiers, project names, service names, timestamps, lifecycle states, operation status, event severity, restart status, recovery status, checkpoints, lock lease fields, rollback availability flags, and hashes.

JSON blobs hold ports, networks, mounts, environment snapshots, runtime capabilities, runtime identifiers, event payloads, operation payloads, ownership metadata, health command/output metadata, restart recovery completed-step metadata, and operation recovery metadata. Saga metadata, intent, compensation, and verification payloads are decoded, redacted by key/value, and re-encoded before persistence so redaction cannot corrupt their JSON structure. Invalid saga JSON fails before acquisition or terminal transition. Payload fields, runtime identifiers, failure messages, and manual recovery hints are redacted before persistence.

Desired environment snapshots never store resolved secret values. `secretEnv` entries persist only redacted markers in `env_json_redacted`; raw `keychain://<service>/<account>` labels and resolved values are not stored in desired-state rows.

## Backup, Restore, And Diagnostics Export

State backup is a cold file operation today:

1. Stop any Hostwright CLI command or future daemon that is using the database.
2. Resolve the selected path with `hostwright paths`, then copy that SQLite database and its sidecar files if present, such as `state.sqlite-wal` and `state.sqlite-shm`.
3. Preserve file permissions and the full database contents. Ownership records, event records, operation records, and observed snapshots must stay together.

The state integration suite proves this cold-copy procedure against a real migrated SQLite file: a backup opens with the recorded schema and committed rows, and restoring that backup to a separate explicit path does not include rows committed only after the backup. This is evidence for the documented stopped-process procedure, not an online backup command or a durability guarantee for copies taken while writers are active.

Restore is also a cold file operation:

1. Stop Hostwright processes using the target path.
2. Move the existing database aside instead of overwriting it.
3. Copy the backup database and sidecars into place.
4. Run a safe read command such as `hostwright events` for the default or `hostwright events --state-db <path>` for an override to verify the schema can be opened.

Diagnostics export is a local read-only command:

```bash
hostwright diagnostics [--state-db <path>] --bundle <path> [--project <name>] [--manifest <path>]
```

The command validates the already-applied schema, reads existing rows, applies Hostwright redaction before JSON rendering, and refuses to overwrite an existing bundle file. It does not observe runtime state, mutate runtime state, create or migrate a missing database, repair state, or upload telemetry.

The exported bundle can still contain sensitive local context such as project names, service names, paths, hostnames, resource identifiers, and redacted-but-contextual metadata. Review it before sharing.

Corruption recovery is manual. If Hostwright reports a corrupt or non-SQLite database, keep the file for investigation, restore from a known-good cold backup, or choose a new explicit database path. Hostwright does not invent ownership records, repair rows, erase state automatically, or treat a path migration as database repair.

## Concurrency And Locking

Hostwright uses SQLite `FULLMUTEX`, a bounded busy timeout, and `BEGIN IMMEDIATE` for transactional writes. The contract remains single-writer: one CLI command or future daemon may write a state database at a time. Real multi-connection tests verify uncommitted-write isolation, committed cross-connection visibility, bounded lock failure, and one-winner operation-group acquisition across concurrent stores.

Read commands validate schema through read-only connections. Write commands run explicit migration before persistence, then use transactions for grouped writes. If another process holds an exclusive or write lock beyond the bounded timeout, Hostwright reports a locked state database instead of waiting indefinitely.

## Transaction Boundaries

Transactions wrap:

- migrations
- desired project/service snapshot writes
- observed runtime snapshot plus observed service writes
- grouped event appends
- operation record creation
- operation success/failure updates
- operation group acquisition and completion
- operation group step appends
- ownership record upserts

No transaction performs runtime mutation. Apply and cleanup write intent first, leave the transaction, call `RuntimeAdapter`, then record success or failure.

## Module Boundary

SQL is not part of the CLI, reconciler, runtime, health, networking, or observability modules. Runtime observation remains behind `RuntimeAdapter`; state persistence records adapter-shaped observed data but does not call the adapter itself.
