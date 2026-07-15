# Local Paths, Permissions, and Legacy Migration

Status: implemented for the `0.0.2-dev` single-Mac path, SQLite hardening, state maintenance, and explicit-prefix installed distribution lifecycle. Autonomous service installation and release-wide soak qualification remain later gates.

## Default Layout

Hostwright uses macOS-native per-user locations. A state-writing command creates Hostwright-owned directories with mode `0700` and sensitive files with mode `0600`.

| Purpose | Default path | Current behavior |
| --- | --- | --- |
| Application Support root | `~/Library/Application Support/Hostwright` | Private Hostwright root. |
| Configuration | `~/Library/Application Support/Hostwright/config` | Reserved for Hostwright-managed configuration; no implicit profile discovery. |
| SQLite state | `~/Library/Application Support/Hostwright/state/state.sqlite` | Production default for state-backed commands. |
| Runtime files | `~/Library/Application Support/Hostwright/run` | Contains daemon locks and the reserved local-control socket path. |
| Runtime metadata | `~/Library/Application Support/Hostwright/metadata` | Contains the legacy migration journal, state access/writer fences, and pending state-maintenance journal. |
| Backups | `~/Library/Application Support/Hostwright/backups` | Verified online state-backup catalogs. |
| Cache | `~/Library/Caches/Hostwright` | Private cache root; image/content cache behavior is implemented in later phases. |
| Logs | `~/Library/Logs/Hostwright` | Private log root; structured daemon logging is implemented in Phase 08. |
| Daemon lock | `~/Library/Application Support/Hostwright/run/hostwrightd.lock` | Real `0600` non-symlink lock for the default state database. |
| Control socket | `~/Library/Application Support/Hostwright/run/control-v2.sock` | Canonical reserved path; the current one-shot control process does not create a socket. |

The directories are created only when a state-writing operation needs them. `hostwright paths` and the read side of `hostwright doctor` do not create files or directories.

## Installed Prefix Metadata

`hostwright-dist` lifecycle paths are separate from the Application Support layout. Every installed-lifecycle command requires an explicit existing `--prefix`; no system prefix is selected implicitly.

| Purpose | Path relative to `--prefix` | Behavior |
| --- | --- | --- |
| Payload ownership | `.hostwright-install-manifest.json` | Exact schema-2 file digest, size, mode, and installer-created-directory inventory. |
| Installed status | `.hostwright-lifecycle/status.json` | Private generation, installation UUID, artifact identity, optional state binding, service state, and rollback authorization. |
| Pending recovery | `.hostwright-lifecycle/journal.json` | Private durable operation/checkpoint record; its presence blocks another mutation until `hostwright-dist recover`. |
| Lifecycle fence | `.hostwright-lifecycle/lifecycle.lock` | Invoking-user-owned `0600` regular file with bounded exclusive acquisition. |
| Transactions | `.hostwright-lifecycle/transactions/<operation-uuid>/` | Private `0700` staged payload, exact prior-payload backup inventory, optional state snapshot, and verified rollback record. |

The prefix must be normalized, absolute, non-symlink, root/current-user owned, and not group/other writable. Protected system roots are rejected. Payload parents cannot be symlinks. Lifecycle metadata is removed only by successful uninstall/finalization or exact recovery; unknown entries block cleanup rather than being deleted.

The optional lifecycle `--state-db` must be a normalized absolute path and is bound to the installation after install or legacy adoption. Unlike state-backed `hostwright` commands, `hostwright-dist` does not apply an Application Support state default when the option is omitted. A bound path cannot be changed during upgrade or repair. See [Installed Distribution Lifecycle](installed-lifecycle.md).

## State Override Precedence

State selection is deterministic:

1. command-line `--state-db <absolute-path>`;
2. `HOSTWRIGHT_STATE_DB`;
3. `~/Library/Application Support/Hostwright/state/state.sqlite`.

The selected origin is `explicit`, `environment`, or `application-support-default` in `hostwright paths --json`.

Controlled installations may relocate the layout roots with absolute `HOSTWRIGHT_APPLICATION_SUPPORT_DIR`, `HOSTWRIGHT_CACHE_DIR`, and `HOSTWRIGHT_LOG_DIR` values. Invalid, relative, traversal-containing, empty, or overlong values fail closed. With an explicit or environment-selected state database, the daemon uses a deterministic hashed lock name beneath the selected Application Support `run` directory so independent databases do not share one lock.

An explicit state parent must already exist and pass the same path policy. Hostwright does not silently create arbitrary caller-selected parent directories.

For an explicit or environment-selected database, state-maintenance paths are identity-derived hidden siblings of that database: `.hostwright-<digest>-access-v1.lock`, `.hostwright-<digest>-maintenance-v1.json`, and `.hostwright-<digest>-backups/`. This prevents unrelated explicit databases in one directory from sharing a fence, journal, or catalog.

Each state-access fence also has a private `.writer` companion. Readers share the access fence. Hostwright writers additionally take the exclusive writer fence, while restore, repair, and recovery take the exclusive access fence. Both files are exact `0600` invoking-user-owned regular files and are acquired under one bounded deadline.

## Commands and Creation Behavior

`status`, `apply`, `logs`, `cleanup`, `hostwrightd`, `state backup`, confirmed `state restore`, confirmed `state repair`, and journal-finalizing `state recover` are state-writing workflows. Without `--state-db`, they use the Application Support default and create private owned artifacts as documented. Existing application workflows run compatible schema migration; maintenance commands require an already compatible catalog/database contract.

`events`, workload `recovery`, `diagnostics`, `state integrity`, `state backups`, and restore/repair dry-runs are read or planning workflows. They use the same default when no override is supplied, but do not create or migrate a missing database. State reads and `state integrity` return the documented `HW-STATE-001` behavior for missing, unsafe, incompatible, degraded, or unrecoverable state. `state backups` deliberately remains available when the current database is missing or corrupt so a verified catalog can drive restore; an absent catalog is an empty result. `state recover` is idempotent and reports the current health even when no journal exists.

`validate`, `plan`, `migrate preview`, `capabilities`, and `paths` do not create local state.

`hostwright-control` uses the same CLI default for `status`, `events`, and `recovery` when its launch configuration omits `--state-db`. Request data can never choose or override a path.

## Path Security Policy

Before SQLite or daemon-lock use, Hostwright validates the complete parent chain and the final file:

- paths must be absolute and normalized, with no duplicate/trailing separators, leading/trailing whitespace, control characters, overlong components, or `.`/`..` traversal components;
- parent directories must be real directories owned by root or the invoking user, must not be group- or other-writable, and must not carry access-granting extended ACL entries;
- user-controlled directory symlinks are rejected; root-owned macOS path aliases are accepted only when they resolve to a safe directory;
- Hostwright-owned layout directories must be owned by the invoking user with exact mode `0700`;
- state, journal, and lock files must be regular, non-symlink, single-link files owned by the invoking user;
- sensitive files require exact mode `0600`; special permission bits and access-granting extended ACL entries are rejected;
- state and lock creation use no-follow, close-on-exec, exclusive creation where applicable, file synchronization, and parent-directory synchronization;
- SQLite validates the database and every existing `-journal`, `-wal`, and `-shm` sidecar before and immediately after open, including device/inode identity across the open boundary;
- daemon and state-access locks are bounded and held on validated descriptors, not path-only claims;
- backup directories/files and maintenance journals use the same owner/mode/ACL/link rules, strict bounded manifests, exact identity-derived paths, and synchronized publication.

This policy protects Hostwright from crossing filesystem ownership boundaries or following ambiguous paths. It is not a sandbox against another process already running as the same macOS account.

Hostwright applies `0700`/`0600` explicitly after creation, so a restrictive caller `umask` cannot strand a first run with unusable paths. Existing files are never silently chmod-repaired: an unsafe existing owner, mode, ACL, link count, or file type remains a hard failure.

## Legacy `~/.hostwright` Migration

When—and only when—the Application Support state default is selected, the first state-writing command looks for `~/.hostwright/state.sqlite`.

Migration proceeds only when all checks pass:

1. the destination does not already exist;
2. the legacy parent chain and database are safely owned, have no access-granting extended ACL, and are not writable by group/other users;
3. the source is a regular single-link file, not a symlink;
4. no uncheckpointed `-journal`, `-wal`, or `-shm` sidecar remains at either the legacy or destination path after the exclusive SQLite checkpoint, including checks after intent, after the exclusive lock, and after rename recovery;
5. the database contains a contiguous, checksum-valid Hostwright migration ledger supported by this build;
6. source and destination are on the same filesystem;
7. an exclusive SQLite transaction can be acquired, proving there is no active writer at the migration checkpoint.

Hostwright then writes and synchronizes `metadata/legacy-state-migration.json`, atomically renames the exact recorded inode, synchronizes both directories, applies mode `0600`, verifies the destination identity, removes and synchronizes the journal, and removes `~/.hostwright` only if it is empty.

If the process stops after intent or after the rename, the next state-writing command resumes from the journal. Exactly one of source or destination must exist, its device/inode must match the record, and its Hostwright migration ledger must still validate. Both existing, both missing, identity drift, an invalid journal, a conflicting destination, sidecars that appear before or after intent, an empty/tampered ledger, or an active writer fail without choosing or deleting data.

Unknown files beneath `~/.hostwright` are never moved or deleted. Earlier code had no executable managed defaults for configuration, cache, logs, backups, sockets, or runtime metadata, so those locations begin as new private directories rather than treating arbitrary legacy files as Hostwright-owned.

Automatic legacy migration is intentionally disabled when `--state-db` or `HOSTWRIGHT_STATE_DB` selects another database. Those overrides are treated as an explicit operator choice.

## Inspection and Recovery

Use:

```bash
hostwright paths
hostwright paths --json
hostwright doctor --output json
hostwright state integrity --json
hostwright state backups --json
hostwright state recover --json
```

`paths` reports the complete layout, selected state origin, effective daemon lock, state/legacy/journal paths and existence flags, override precedence, permission contract, and one readiness value:

- `ready`;
- `needs-creation`;
- `migration-required`;
- `blocked-conflict`;
- `blocked-policy`.

For `blocked-policy`, JSON includes a redacted `policyError`. Inspection validates existing components even before the database exists, so an absent explicit parent or an already-created default-layout directory with unsafe ownership/mode is visible before first use. A valid pending journal reports `migration-required`, including the post-rename/pre-chmod checkpoint. `doctor` independently reports path policy as `ready`, `degraded`, or `blocked` and exits `65` when the resolved current or prospective path violates policy.

Do not delete a database or migration/maintenance/lifecycle journal to resolve a conflict. Stop non-Hostwright SQLite writers, preserve the reported files, and use `state integrity`, `state backups`, `state recover`, or `hostwright-dist recover` as directed. Issue #114 implements managed integrity/backup/restore/projection repair/checkpoint recovery; issue #115 implements the SQLite file, transaction, pressure, identity, and writer-fencing boundary; issue #118 implements explicit-prefix install, upgrade, repair, rollback, and uninstall recovery.
