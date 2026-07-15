# Devlog 0045: SQLite Hardening And State Ownership

Date: 2026-07-14

Issue: #115

## Outcome

Hostwright's schema-v7 SQLite store now has one executable single-Mac connection policy instead of relying on SQLite defaults. Authoritative state uses private validated files, Hostwright application ownership, WAL/FULL durability with macOS full-fsync barriers, bounded resource and lock behavior, serialized Hostwright writers, strict managed transaction ownership, and typed failure classification. Portable backup and recovery artifacts use a separately verified sidecar-free DELETE/EXTRA profile.

## Boundary Decisions

- `SQLiteStateStore` owns authoritative state connections and selects the authoritative profile explicitly.
- The final database path and every existing SQLite sidecar are validated before open, then the database device/inode is revalidated immediately after open.
- Hostwright claims legacy `application_id == 0` only inside an explicit validated migration. A nonzero foreign application ID is rejected before persistent configuration.
- Readers share the existing access fence. Writers also acquire an exclusive writer fence, while filesystem-replacement maintenance keeps exclusive access authority.
- SQLite's authorizer rejects transaction/savepoint opcodes inside a managed transaction, including transaction control hidden after another statement.
- Cancellation and pressure errors cannot acknowledge a partial transaction. Rollback runs with cancellation disabled and autocommit state is verified before the failure returns.
- Online backup remains SQLite-driven. Exact filesystem copies are limited to already immutable, digest/size-bound private catalog artifacts used by restore and rollback.

## Failures Found During Implementation

The first adversarial tests exposed two production defects. A multi-statement `INSERT; COMMIT` could end the outer managed transaction because first-token validation did not inspect later statements. Opening a foreign SQLite database could change persistent journal state before application ownership was checked. The connection authorizer and pre-configuration application-ID check now close both boundaries.

Recovery regression tests also exposed a distinction between an unsafe arbitrary wrong-mode database and the exact inode recorded by an interrupted legacy rename. Generic opens continue to reject wrong mode without mutation. Journal-bound recovery validates the recorded identity, applies mode `0600` through the open descriptor, synchronizes it, revalidates the path and ledger, and only then removes the journal.

## Real Verification

The focused suite uses real SQLite databases, WAL and shared-memory sidecars, `flock`, filesystem links, concurrent path swaps, an actual `SQLITE_FULL` limit, and `/usr/bin/sqlite3` terminated with `SIGKILL`. It verifies committed-state survival, uncommitted rollback, connection reuse after pressure, concurrent readers, serialized writers, bounded contention, foreign-database non-mutation, unsafe-sidecar refusal, and exact sentinel preservation across 1,000 symlink swaps.

All eight hardening tests pass under both AddressSanitizer and ThreadSanitizer with zero sanitizer reports. The complete state module passes 91 tests with zero failures. Aggregate Phase 02 verification and clean-commit evidence are recorded at the phase PR and issue evidence gate rather than duplicated as an unreviewed claim here.

## Remaining Boundary

Hostwright does not sandbox processes running as the invoking macOS account. A same-user program can open the SQLite file directly and bypass the Hostwright writer fence; direct external writes are unsupported. Multi-Mac authority, distributed consensus, release-wide lifecycle counts, physical disk-fault qualification, and long soaks are separate roadmap gates. Hostwright does not salvage arbitrary corrupted authoritative rows.
