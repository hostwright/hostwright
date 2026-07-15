# Devlog 0047: Installed Distribution Lifecycle

Date: 2026-07-14

Issue: #118

## Outcome

`hostwright-dist` now has an executable installed lifecycle for a verifier-produced artifact at an explicit local prefix. It supports install, strict upgrade, exact-generation repair, structured status, explicit legacy adoption, interrupted-operation recovery, verified one-generation rollback, and ownership-scoped preserve/remove uninstall.

This closes the earlier gap where the developer evidence runner could exercise temporary replacement but users and automation had no durable installed-generation contract. The trusted release and developer distribution verifiers now feed the same lifecycle boundary; an arbitrary extracted directory cannot construct an installable artifact.

## Public Workflow

```bash
hostwright-dist install <artifact-source> --prefix <path> [--state-db <path>] --output json
hostwright-dist upgrade <artifact-source> --prefix <path> [--state-db <path>] --output json
hostwright-dist repair <artifact-source> --prefix <path> [--state-db <path>] --output json
hostwright-dist status --prefix <path> --output json
hostwright-dist adopt-legacy --prefix <path> [--state-db <path>] --output json
hostwright-dist recover --prefix <path> --output json
hostwright-dist rollback --prefix <path> --output json
hostwright-dist uninstall-plan --prefix <path> --data-policy remove --output json
hostwright-dist uninstall --prefix <path> --data-policy preserve --output json
hostwright-dist uninstall --prefix <path> --data-policy remove --confirmation <plan-token> --output json
```

The artifact source is exactly one verified trusted release plus team identifier or one verified developer distribution. Installed-lifecycle success and classified failure output are versioned JSON contracts. Mutation success includes temporary-extraction cleanup status and exact pending paths. A pending post-commit cleanup reports `HW-DIST-W001` on stderr but retains exit status `0` because the installed mutation already committed.

## Version And Ownership Decisions

- Upgrade requires a candidate semantic version strictly greater than the installed version.
- Repair requires the exact installed semantic version and source commit.
- The requested install, upgrade, or repair operation must match the operation derived while holding the prefix lifecycle fence; a mismatch is refused without mutation.
- A lower candidate is refused; the same version from another commit is a version conflict.
- Rollback accepts no artifact and restores only the verified generation retained by the current successful upgrade.
- Every installation has a Hostwright UUID and monotonically increasing generation.
- The schema-2 ownership manifest includes `hostwright-dist` alongside the other three executables, documentation, and the maintained example.
- A schema-1 installation is never silently claimed. `adopt-legacy` verifies its exact older payload before lifecycle status is published; exact-generation repair then migrates ownership to schema 2.
- Upgrade and uninstall require current payload digests to match. Repair may restore a missing or content-corrupted regular owned file, but it refuses symlinks, hard links, special files, set-ID bits, unsafe ownership, and ambiguous metadata.

## Durable Recovery

The lifecycle writes private status, an exclusive fence, a checkpoint journal, and an operation transaction beneath the explicit prefix. The transaction can contain staged payload, an exact prior-payload inventory, a verified state snapshot, and the one-generation rollback record.

The journal covers intent, staging, prior payload backup, state backup, payload publication, state migration, final verification, and status publication. Ordinary failures attempt exact compensation before returning. If durable intent or a canonical transaction stage cannot be published, compensation removes that operation transaction instead of leaving an orphan. A durable `compensation-published` marker lets recovery verify and finish cleanup if interruption occurs after the prior generation was restored and its transaction was removed. Other process interruptions preserve the journal, make status report `recovery-required`, and block another mutation until `hostwright-dist recover` restores the prior generation, removes an interrupted initial install, finalizes a committed generation, or finalizes a committed uninstall with action `completed-uninstall`.

When a compatible bound state database exists, upgrade and repair take a verified snapshot before schema migration. Verified rollback restores the pre-upgrade state snapshot and refuses mutation if current state-database presence no longer matches the rollback record. Remove-data uninstall also snapshots first so interruption can restore both payload and state.

## Uninstall Authority

Preserve-data uninstall accepts no confirmation token and leaves the bound state database untouched. Its plan checks only the bound state path and existence; revision fields remain unset, and the SQLite database and existing sidecar bytes, identities, and metadata remain unchanged. Remove-data planning and uninstall require a bound state path and verified current revision; only the remove plan exposes SHA-256, byte count, and schema version and binds that revision together with prefix, installation UUID, generation, status timestamp, and data policy. Any generation or bound-state revision change invalidates an earlier remove token.

Removal is limited to manifest-owned payload, lifecycle metadata, installer-created directories that are empty, and—only for confirmed remove-data—the verified bound SQLite database plus existing SQLite sidecars. Backup catalogs, configuration, caches, logs, unrelated prefix files, and Apple container resources remain outside this authority. The result's `removedPaths` records the exact payload files, ownership manifest, and only directories actually removed; private lifecycle finalization internals are not part of that field. `removedStatePaths` records the exact absolute SQLite files removed.

## Service Boundary

Issue #118 does not create, register, or autostart a LaunchAgent. It narrowly recognizes an existing current-user Homebrew launchd property list only when its owner, type, mode, label, exact four program arguments, loaded path, loaded program, state, and process bind to this prefix. A running accepted service is stopped before executable replacement and restarted only when it was previously running; rollback, compensation, and recovery restore that state. Missing, changed, or unmanaged records fail closed, and committed uninstall leaves the external record stopped without deleting it. LaunchAgent creation, keepalive design, reboot, and unattended reconciliation remain owned by the later daemon phase.

## Verification Scope

Focused tests use real assembled artifacts, installed executable subprocesses, filesystem ownership/modes/links, SQLite schema-6 and schema-7 databases, exact state hashes, deterministic cancellation at every reachable install/upgrade/repair/uninstall checkpoint, locked command/operation mismatch, deterministic cleanup after intent and canonical-stage publication failures, interrupted status publication, compensation completion after transaction removal, every upgrade checkpoint, remove-data uninstall checkpoints, a real launchd service across replacement/rollback/recovery/uninstall, state-revision stale confirmation, byte-, identity-, and metadata-neutral preserve planning for a bound SQLite file set, exact pre-migration snapshot restore, non-fatal pending post-commit extraction cleanup, rollback state-presence mismatch, legacy adoption, repair of missing content, verified rollback, downgrade refusal, unmanaged-content preservation, and exact prefix cleanup.

The installed lifecycle does not satisfy the package-channel gate by itself. Issues #111, #112, and #119 remain open for real Developer ID identities, notarization, public-byte verification, vendor-tap publication/install, Apple Installer/service integration, Gatekeeper/reboot coverage, and clean-Mac qualification. Aggregate exact-commit and hosted-CI evidence remains recorded at the single Phase 02 PR gate.

The complete operator contract and troubleshooting flow are in [Installed Distribution Lifecycle](../reference/installed-lifecycle.md).
