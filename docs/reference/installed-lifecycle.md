# Installed Distribution Lifecycle

Status: implemented and qualified in `0.0.2-dev` for an explicit local install prefix and a verifier-produced trusted, developer, or staged Apple Installer artifact. The vendor tap, signed `.pkg`, and public qualification artifacts passed signing, publication, and clean-Mac evidence. They remain unsupported prerelease channels, not `v0.0.2` GA.

## Boundary

`hostwright-dist` owns the installed Hostwright payload lifecycle. It does not manage Apple container workloads.

The operator supplies an existing, normalized, absolute `--prefix`. The prefix must be a real non-symlink directory, owned by root or the invoking user, and not writable by group or other users. `/`, `/System`, `/Library`, `/usr`, `/bin`, and `/sbin` are refused. Hostwright does not choose or create an implicit system prefix.

The schema-2 ownership manifest records exactly these payload files and their digest, size, and mode:

- `bin/hostwright`
- `bin/hostwright-control`
- `bin/hostwright-dist`
- `bin/hostwrightd`
- `share/hostwright/examples/hostwright.yaml`
- `share/doc/hostwright/LICENSE`
- `share/doc/hostwright/README.md`

Installed lifecycle metadata is private to the prefix:

| Path relative to `--prefix` | Purpose |
| --- | --- |
| `.hostwright-install-manifest.json` | Exact payload ownership manifest. |
| `.hostwright-lifecycle/status.json` | Installation UUID, generation, version/source identity, optional package origin and receipt-cleanup state, optional state binding, service state, and rollback authorization. |
| `.hostwright-lifecycle/journal.json` | Pending operation, checkpoint, prior generation, and recovery binding. Present only while recovery may be required. |
| `.hostwright-lifecycle/lifecycle.lock` | Private bounded exclusive lifecycle fence. |
| `.hostwright-lifecycle/transactions/<operation-uuid>/` | Staged payload, exact prior-payload backup, optional verified state snapshot, and the one-generation rollback record. |

Unknown prefix content is not adopted, replaced, or deleted. Installer-created directories are removed only when empty.

## Artifact Sources

`install`, `upgrade`, and `repair` accept exactly one source:

```text
--trusted-release-dir <path> --team-id <10-char>
--developer-distribution-dir <path>
```

The trusted source passes the complete trusted-release verifier before installation. The developer source passes the unsigned artifact verifier and is suitable for development evidence only. Both paths install only verifier-created artifacts; neither accepts an arbitrary extracted directory as trusted input.

Installed lifecycle commands currently require `--output json`.

An Apple Installer package uses a narrower bridge into the same lifecycle. Its payload is installed only into the private root-owned `/Library/Application Support/Hostwright/InstallerPayload` staging directory. The package `postinstall` runs `hostwright-dist package-apply`, which requires elevated authority and exact `/usr/local`, verifies the `dev.hostwright.cli` receipt and version, the complete staged manifest and file digests, root ownership and modes, and Developer ID Application signatures from the exact Team ID embedded by the trusted release build before mutation. It then selects only `install`, a strictly newer `upgrade`, or an exact-version-and-commit `repair`; downgrade and same-version/different-commit candidates are refused.

## Commands

```bash
hostwright-dist install <artifact-source> --prefix <path> [--state-db <absolute-path>] --output json
hostwright-dist upgrade <artifact-source> --prefix <path> [--state-db <absolute-path>] --output json
hostwright-dist repair <artifact-source> --prefix <path> [--state-db <absolute-path>] --output json
hostwright-dist status --prefix <path> --output json
hostwright-dist adopt-legacy --prefix <path> [--state-db <absolute-path>] --output json
hostwright-dist recover --prefix <path> --output json
hostwright-dist rollback --prefix <path> --output json
hostwright-dist uninstall-plan --prefix <path> --data-policy <preserve|remove> --output json
hostwright-dist uninstall --prefix <path> --data-policy preserve --output json
hostwright-dist uninstall --prefix <path> --data-policy remove --confirmation <plan-token> --output json
hostwright-dist package-apply --staged-root '/Library/Application Support/Hostwright/InstallerPayload' --prefix /usr/local --package-id dev.hostwright.cli --package-version <version> --team-id <10-char> --output json
hostwright-dist package-uninstall --prefix /usr/local --data-policy preserve --output json
```

`package-apply` is the package `postinstall` entrypoint, not a general artifact installer. A package-owned generation must continue through the package lifecycle rather than a generic archive upgrade or uninstall. `package-uninstall` supports only `--data-policy preserve`: it re-verifies lifecycle ownership, the exact receipt, and the staged payload before removing the package-owned generation. After the uninstall commits, it forgets only `dev.hostwright.cli` and removes only the verified staging payload. If that final receipt/staging cleanup is interrupted, durable package-origin state records it and `hostwright-dist recover --prefix /usr/local --output json` retries the exact cleanup. Package remove-data planning and uninstall fail before state or package mutation because the system-wide package cannot safely infer or search for a per-user state database.

`--state-db` is optional and has no implicit default in `hostwright-dist`. Once recorded, the normalized absolute path is bound to the installation and cannot be changed during upgrade or repair. A present database must be a compatible Hostwright database. Install verifies compatibility without migrating it. Upgrade and repair create a verified transaction-bound snapshot before migrating it to the latest supported schema. Verified rollback restores the exact pre-upgrade snapshot when one exists. Rollback is refused before mutation if current state-database presence no longer matches the verified rollback record.

## Version Rules

Hostwright parses exact semantic versions before mutation. After taking the prefix lifecycle fence, it derives the required operation from the locked installed generation and refuses an `install`, `upgrade`, or `repair` command that does not match.

| Requested command | Required relationship |
| --- | --- |
| `install` | No managed installation may exist at the prefix. |
| `upgrade` | Candidate version must be strictly greater than the installed version. |
| `repair` | Candidate version and source commit must exactly equal the installed generation. |
| `rollback` | A successful upgrade must have retained one verified immediately prior generation. No artifact argument is accepted. |

A lower candidate is refused as a downgrade. Reusing the installed version with a different source commit is also refused. `rollback` is not an arbitrary downgrade escape: its payload, manifest, state snapshot, source generation, and authorization record must all match the current installed generation.

## Durable Flow

An install, upgrade, repair, rollback, or uninstall takes the prefix lifecycle fence and records durable intent before publishing payload or changing bound state. The transition progresses through these checkpoints:

```text
intent-recorded
  -> payload-staged
  -> prior-payload-backed-up
  -> state-backed-up
  -> service-stopped
  -> payload-publishing
  -> payload-published
  -> state-migrating
  -> state-migrated
  -> verifying
  -> service-restored
  -> status-published
```

Some checkpoints are inapplicable to an initial install, an operation without a present state database, or an installation without an exact managed service record. The journal still records a deterministic operation shape. If durable intent or a canonical transaction stage cannot be published, ordinary failure compensation removes that operation transaction instead of leaving an orphan.

Before an install, upgrade, repair, or rollback payload transition succeeds, Hostwright re-verifies every installed owned file and runs the installed executable contracts. An upgrade publishes the new generation only after verification and retains one verified prior generation for `rollback`. Repair publishes a new generation but does not create a rollback authorization. Uninstall instead verifies the current owned payload before any deletion.

An ordinary failure attempts exact compensation before returning. A process interruption leaves the journal. `status` then reports `recovery-required`, including the pending operation and checkpoint. Run:

```bash
hostwright-dist recover --prefix <path> --output json
```

Recovery either finalizes an already committed `status-published` generation, finalizes a committed uninstall with action `completed-uninstall`, completes a recorded package-receipt/staging cleanup, restores the exact prior generation, removes an interrupted initial install, or reports `no-action`. A durable `compensation-published` marker lets recovery verify and finish cleanup when interruption occurs after the prior generation was restored and its transaction was removed. Do not delete or edit lifecycle metadata or transaction files to clear a failure.

## Repair And Legacy Adoption

`repair` can restore a missing or content-corrupted owned regular file from the exact same verified version and source commit. It refuses symlinks, hard-linked files, special files, set-ID files, unsafe ownership, an unsafe prefix, or unrecognized lifecycle metadata. If repair is interrupted, recovery restores the exact pre-repair condition before another operation is accepted.

An older exact schema-1 install contains the three earlier executables and no `hostwright-dist` payload. It is never silently claimed. `adopt-legacy` verifies the complete schema-1 manifest, every owned file, executable behavior, optional state binding, and daemon boundary before publishing generation 1 lifecycle status. A later repair with the same verified artifact moves ownership to schema 2 and installs `hostwright-dist`. Tampered or non-schema-1 installs are refused without publishing ownership metadata.

## Service Boundary

Phase 02 does not create, register, or autostart a LaunchAgent. When the exact current-user Homebrew service property list already exists, Hostwright accepts it only if it is a safe regular file with the exact `homebrew.mxcl.hostwright` label and its four program arguments bind to this prefix's `hostwrightd`, `--foreground`, and one normalized configuration path. A loaded service must also report that exact property-list path, program, running state, and process executable.

For an accepted existing record, lifecycle mutation captures `running` or `stopped`, unloads a running service before executable replacement, and reloads it only when it was previously running. Repair, upgrade, verified rollback, compensation, and recovery restore that prior state; committed uninstall leaves the external service record stopped and does not delete it. A missing, changed, ambiguous, or unmanaged record fails closed, and an unmanaged exact `hostwrightd` process is never killed or adopted. LaunchAgent creation, registration, keepalive design, reboot behavior, and unattended reconciliation remain owned by their later roadmap phase.

## Uninstall Data Choices

Generic archive uninstall first verifies the current manifest and every owned payload file. Modified or ambiguous ownership blocks removal.

| Policy | Confirmation | Effect |
| --- | --- | --- |
| `preserve` | No confirmation token is accepted. | Removes the verified installed payload, ownership manifest, and lifecycle metadata. Leaves the bound state database untouched and reports its path. |
| `remove` | Requires the exact current token from `uninstall-plan --data-policy remove`. | Takes a verified state snapshot, removes the verified installed payload, removes the bound Hostwright SQLite database plus its existing `-wal`, `-shm`, and `-journal` sidecars, then removes lifecycle metadata. |

Both plan policies expose `stateDatabasePath` and `stateDatabaseExists`. A preserve-data plan leaves `stateDatabaseSHA256`, `stateDatabaseBytes`, and `stateSchemaVersion` unset. It checks only the bound path and existence: the SQLite database and existing sidecar bytes, identities, and metadata remain unchanged, and its token must not be passed to preserve-data uninstall.

Remove-data planning additionally exposes the complete verified state revision. Its token binds the prefix, installation UUID, generation, status timestamp, data policy, state path, and that revision. Any repair, upgrade, rollback, generation change, or state existence/content/size/schema change makes an earlier remove token stale. Remove-data planning and uninstall require an installation-bound state database path; an unbound path is refused, and Hostwright never searches for other data.

These two choices apply to a generic installation whose state path was explicitly bound under the same user authority. A package-origin installation supports preserve only. `uninstall-plan --data-policy remove` and `package-uninstall --data-policy remove` return a usage error before payload, receipt, staging, or state mutation; Hostwright does not derive a user state path from the elevated package process.

`--data-policy remove` does not remove backup catalogs, configuration, caches, logs, unrelated Application Support files, Apple container workloads, images, networks, volumes, or arbitrary files next to the database. Review and remove those resources through their owning commands and policies.

In `distributionUninstallResult`, `removedPaths` is the exact sorted set of relative manifest-owned payload files, the ownership manifest, and only the installer-created directories that were actually empty and removed. It deliberately does not enumerate private lifecycle finalization internals. `removedStatePaths` is the exact sorted set of absolute SQLite database/sidecar paths removed by the state boundary. `preservedStateDatabasePath` is populated only for preserve-data uninstall.

## Structured Status And Errors

Successful lifecycle mutation returns schema-1 JSON with `kind: distributionLifecycleMutation`, the operation, the new status, and `cleanup` with status `complete` or `pending` plus exact `pendingPaths`. If verified temporary extraction cleanup remains pending after the mutation commits, stderr reports `HW-DIST-W001` while the command keeps exit status `0`; the committed mutation is not reported as failed. Inspection uses `kind: distributionLifecycleInspection` and readiness `not-installed`, `ready`, or `recovery-required`. Recovery and uninstall use `distributionRecoveryResult` and `distributionUninstallResult` respectively.

When `--output json` is present, a classified failure is written to stderr as:

```json
{"schemaVersion":1,"kind":"distributionToolError","code":"HW-DIST-001","message":"...","exitCode":72}
```

Exit categories are documented in [Error Codes](error-codes.md). Deterministic cancellation tests cover every reachable install, upgrade, repair, and uninstall checkpoint. Cancellation either completes exact compensation before returning or leaves `recovery-required`; after recovery, one verified generation remains and transaction cleanup is exact.

## Troubleshooting

| Result | Required action |
| --- | --- |
| `installed manifest exists without lifecycle ownership metadata` | Verify the prefix and run `adopt-legacy` only for an exact schema-1 installation. |
| `recovery-required` | Preserve the prefix and run `recover` before any other mutation. |
| Candidate is lower than installed | Use a newer signed/verified artifact. Use `rollback` only when status exposes a verified prior generation. |
| Same version, different source commit | Use the exact installed artifact for repair or publish a strictly newer semantic version. |
| Owned file mismatch during upgrade or uninstall | Do not delete metadata. Inspect the path. Use `repair` only with the exact installed artifact and only after eliminating symlink, link, owner, or file-type ambiguity. |
| No verified rollback generation | Rollback is unavailable until one successful strict upgrade retained its prior generation. |
| Installed `hostwrightd` is running | An exact accepted Homebrew launchd record is stopped and restored automatically. Otherwise stop the unmanaged process explicitly; Hostwright will not adopt or terminate it. |
| State verification or migration fails | Preserve the database and lifecycle transaction. Use `hostwright state integrity`, `state backups`, and `state recover` as applicable before retrying. |
| Package receipt cleanup is pending | Preserve `/usr/local` lifecycle metadata and the private staging directory, then run `hostwright-dist recover --prefix /usr/local --output json`. Do not forget other receipts or delete staging manually. |

## Qualification Boundary

The installed lifecycle is executable and tested with real artifacts, files, subprocesses, SQLite databases, every reachable mid-mutation cancellation checkpoint, a real current-user launchd service, service replacement/recovery, rollback, legacy adoption, and exact ownership refusal. Phase 02 qualification passed real Developer ID signing/notarization, public-byte verification, vendor-tap installation, Gatekeeper and reboot coverage, clean-Mac upgrade/repair/rollback/uninstall, state and doctor checks, abrupt-power recovery, and exact cleanup. Phase 15 repeats the distribution gate for GA.
