# Local state recovery

This runbook covers the single-Mac development release. Use the CLI and daemon
from the same signed installation, under the macOS account that owns the state
and its audit Keychain items. Final release qualification is tracked in
[the release process](../release/RELEASE_PROCESS.md).

## Preserve evidence and choose the database

Record `hostwright --version`, `sw_vers`, and the failed command's diagnostic.
Use the same `--state-db` path throughout recovery. Omit that option only when
the daemon uses the default database. For a private foreground setup, retain
the same local path environment settings for the CLI and daemon.

While the daemon is available, inspect state and create a verified backup:

```bash
hostwright state integrity --json
hostwright state backup --json
hostwright state backups --json
```

Keep the returned backup ID. Only catalog entries marked `restorable: true`
are restore candidates. A state backup contains the local SQLite database;
it does not back up workload files, named volumes, Keychain items, or the
installed application. Follow [storage backup and restore](storage.md) for
workload data and [installed lifecycle](installed-lifecycle.md) for packages.

Do not copy a live SQLite file as a backup. Do not delete maintenance journals,
sidecars, or audit keys to clear an error. If the daemon cannot start because
maintenance was interrupted, proceed directly to the recovery step below.

## Stop, recover, then restore

For the managed current-user service:

```bash
hostwright daemon stop
hostwright daemon status
```

For a foreground daemon, stop that exact process and wait for it to exit.
Keep the daemon stopped through recovery, preview, and confirmation. An active
daemon causes offline maintenance to refuse with a `stop hostwrightd` message.
This also applies to a daemon started with a custom instance-lock path.

First resolve any interrupted state-maintenance operation:

```bash
hostwright state recover --json
```

Recovery follows the recorded checkpoint and reports whether it completed or
rolled back the operation. Repeating a completed recovery is safe. If it enters
a safe hold, preserve the reported evidence and seek maintainer assistance;
do not remove the journal or substitute a different database.

To restore a verified backup, substitute the retained backup ID, inspect the
dry-run output, then copy its exact confirmation token into the second command:

```bash
hostwright state restore --backup <backupID> --dry-run --json
hostwright state restore --backup <backupID> --confirm-restore <confirmationToken> --json
```

A changed database invalidates the token. Obtain a fresh preview and review it
again. A successful restore reports healthy state and a pre-restore backup ID.
The signed daemon executable performs this offline work so it retains access
to the same audit Keychain identity; no Keychain permission change is needed.

For repairable projection damage, use `state repair --dry-run --json` followed
by `state repair --confirm-repair <confirmationToken> --json` instead. Repair
does not reconstruct damaged authoritative state. See the
[state-store contract](../architecture/state-store.md#integrity-backup-restore-repair-and-diagnostics-export)
for the supported repair boundary.

## Restart and verify

Restart the previously installed managed service, or relaunch the same
foreground daemon with its original configuration and local paths:

```bash
hostwright daemon start
hostwright state integrity --json
```

Verify `health: healthy`, then inspect the affected project's status before
requesting new lifecycle changes. Database restoration does not prove that
running workloads or their data match the restored records.

For a support request, use the [support-bundle preview and confirmation
workflow](support-bundles.md). Bundles remain local until you choose to share
them. Review the recipient and contents before sharing; do not attach raw
databases, Keychain exports, credentials, or maintenance directories to a
public issue. Follow the [security reporting policy](../../SECURITY.md) for
sensitive reports.
