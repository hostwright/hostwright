# Devlog 0043 — Verified State Maintenance And Recovery

## Outcome

Issue #114 replaces Hostwright's stopped-process copy guidance with an executable, fail-closed state-maintenance system. A user can inspect the exact database, take a consistent online backup, verify every catalog entry, preview and confirm an atomic restore, repair only data that the runtime can reconstruct, and recover an interrupted maintenance saga.

## Public Workflow

```bash
hostwright state integrity --json
hostwright state backup --json
hostwright state backups --json
hostwright state restore --backup <id> --dry-run --json
hostwright state restore --backup <id> --confirm-restore <token> --json
hostwright state repair --dry-run --json
hostwright state repair --confirm-repair <token> --json
hostwright state recover --json
```

Integrity exits successfully only for `healthy`. A `degraded` or `unrecoverable` result still writes the complete structured report to stdout, writes `HW-STATE-001` to stderr, and exits 66. Stale restore/repair confirmation returns `HW-CLI-003`/70. An unsafe attempt to repair authoritative damage returns `HW-SECURITY-001`/71.

## Authority Split

The repair boundary is deliberately narrow:

| Data class | Examples | Automated action |
| --- | --- | --- |
| Authoritative | desired projects/services, ownership, operation/event/restart ledgers, migration history | Never delete or synthesize; verified restore required. |
| Reconstructible | observed runtime snapshots/services, health results | May be cleared after exact dry-run, confirmation, rollback snapshot, transaction, and final verification. |
| Filesystem evidence | corrupt original, failed replacement, incomplete unknown partial, invalid journal | Preserve for inspection; remove only exact Hostwright-owned artifacts whose identity and checkpoint prove cleanup safe. |

## Durable Restore Checkpoints

The maintenance journal is outside SQLite because restore temporarily renames the SQLite file itself. It records only identity-derived paths and strict bounded fields.

1. `staging`: restore intent and exact paths exist before the temporary SQLite copy is created.
2. `prepared`: verified stage exists; current database has not moved.
3. `source-displaced`: the exact current file moved aside; publication has not occurred.
4. `replacement-published`: verified replacement occupies the selected path; projections are not yet reset.
5. `mutation-committed`: projection reset and audit event committed; filesystem cleanup remains.

`state recover` removes incomplete/unpublished staging, restores a displaced source before publication, verifies/finalizes or rolls back a published replacement, and finalizes a committed projection mutation. It also recognizes the real torn windows after staging, source displacement, publication, and projection commit but before the next journal update. An ordinary error after publication preserves the failed replacement, restores the displaced original or verified pre-restore backup, and removes only the exact journal-bound stage. Ordinary state access sees the journal while holding the same coordination fence and refuses to create or open another authority.

## Backup Publication

The source remains a real SQLite connection. SQLite's online backup API creates a transactionally consistent destination even when a WAL writer is active; uncommitted rows are absent. The destination is normalized to sidecar-free `DELETE` journal mode, fully inspected, hashed, described by a strict manifest, synchronized, and atomically renamed from `.partial-*` to its opaque `backup-*` catalog ID.

Catalog verification reruns on every list or restore. A directory is restorable only when it contains exactly `manifest.json` and `state.sqlite`, both pass file policy, the strict manifest matches the path, digest/size/schema match, and the database is fully healthy. A catalog-root policy/read failure is a command error, not a synthetic catalog entry. Restore then binds the same expected digest and size to the completed staged copy, closing a selected-backup replacement race between confirmation and copy. Pre-repair snapshots may be verified but degraded only in reconstructible projections; they are marked rollback-only and are executable only by the matching repair journal.

If an interrupted committed repair database becomes unrecoverable, recovery preserves it as `.hostwright-repair-failed-<operation>.sqlite`, copies and verifies the exact pre-repair snapshot, clears only the snapshot's recorded reconstructible projection tables, writes a distinct idempotent rollback audit event, verifies healthy state, and only then removes the journal.

## Security And Failure Controls

- `0700` owned directories and `0600` singly linked files; no user symlinks or access-granting ACLs. Existing state fences and any state path that appears after a missing-state restore plan are validated before opening or mutation.
- Bounded lock acquisition and bounded manifest/journal reads.
- Shared state-access lock for ordinary connections; exclusive lock for maintenance.
- Atomic same-filesystem publication; parent-directory synchronization around durable renames.
- Restore/repair tokens bind current identity and exact intended effects.
- Restore/repair refuse SQLite sidecars; online backup alone supports live WAL sources.
- Strict JSON rejects duplicate, unknown, missing, oversized, or path-injected metadata.
- Cancellation, SQLite-full failures, and interrupted restore staging remove only exact journal-bound files and SQLite sidecars; unknown content is preserved.
- No RuntimeAdapter call, Apple container mutation, telemetry, private API, arbitrary page salvage, or authoritative-row repair.

## Evidence

The new focused suites use real SQLite files, connections, locks, WAL transactions, filesystem renames, modes, hard links, corruption/truncation bytes, size limits, and built CLI processes. They cover normal, boundary, failure, rollback, cancellation, selected-backup races, every durable/torn recovery point, ordinary publication failure, repair rollback after unrecoverable committed state, missing targets, unmanaged state appearing after a missing-target plan, required indexes, UUIDs, full v7 enum/JSON contracts, security, schema compatibility, and exact cleanup behavior. The umbrella regression and repository verification gates remain the release authority.
