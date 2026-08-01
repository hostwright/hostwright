# Daemon

`hostwrightd` supports the foreground development loop and a managed per-user LaunchAgent mode. The LaunchAgent lifecycle is controlled only through `hostwright daemon`; `hostwright-dist` remains the executable-distribution authority. Neither mode is a privileged helper. Both daemon modes use the same level-triggered lifecycle saga as the explicit CLI and may reconcile supported drift without an event edge.

## Current Behavior

The foreground loop remains available:

```bash
hostwrightd --foreground --config <hostwright.yaml>
```

The managed process is launched only from the exact owned plist as:

```bash
hostwrightd --service --config <absolute-hostwright.yaml>
```

Exactly one of `--foreground` or `--service` is required. Managed service mode requires an absolute normalized config path and does not accept `--max-iterations`.

Lifecycle control uses:

```bash
hostwright daemon status
hostwright daemon install --daemon-executable <absolute-hostwrightd> --config <absolute-hostwright.yaml>
hostwright daemon validate|bootstrap|start|stop|kickstart|rollback|disable|repair|uninstall
hostwright daemon upgrade --daemon-executable <absolute-hostwrightd> --config <absolute-hostwright.yaml>
```

All lifecycle commands support text or versioned JSON output. `install` and `upgrade` require canonical existing paths to a securely validated executable named `hostwrightd` and a current-user- or root-owned, regular, single-link, non-writable-by-group/others config file. Both launch inputs are securely revalidated immediately before bootstrap.

## LaunchAgent Contract

The controller owns exactly `~/Library/LaunchAgents/dev.hostwright.daemon.plist` in `gui/<uid>`. The plist is current-user-owned, single-link, mode `0600`, written atomically, and contains only the exact label, absolute program arguments, run/keepalive policy, ten-second launchd throttle, background process type, `0077` umask, and private stdout/stderr paths. It contains no `EnvironmentVariables` key or secret values. On managed entry, `hostwrightd` revalidates its own executable and, when launchd supplied any other environment, replaces its process image once with an exact initial environment containing only the validated current-user `HOME`, fixed C locale, and trusted system `PATH`. Runtime construction occurs only after that exact environment is active.

Lifecycle authority is recorded beneath `~/Library/Application Support/Hostwright/daemon` in mode-`0600` schema-v1 status, rollback, and pending-journal records. Unknown fields, kinds, or future schema versions fail closed; there is no pre-Phase-08 managed-record format to adopt or migrate. Private logs are `~/Library/Logs/Hostwright/hostwrightd.log` and `hostwrightd.error.log`. Parent directories must be current-user-owned, non-symlink directories without group/other writes or access-granting ACLs.

Every mutation first takes a non-blocking advisory lock on the exact validated current-user home directory, then records durable intent before the first launchctl or plist effect. The lock leaves no cleanup artifact, while exclusive journal publication remains the durable race fence. Checkpoints cover intent, prior-generation rollback publication, service stop, plist publication, persistent enable/disable state, service start, exact verification, and status publication. `repair` completes a valid pending operation forward only when its operation, generation, bytes, and rollback record remain exact; changed or ambiguous records enter a precise refusal instead of being overwritten.

The controller never adopts, edits, enables, disables, unloads, or deletes `homebrew.mxcl.hostwright`. A loaded Homebrew record, an unowned persistent disabled override for the managed label, or any unmanaged `hostwrightd` process—including a process whose executable was deleted—blocks mutation. The separate distribution lifecycle may still narrowly stop and restore an exact accepted Homebrew record during payload replacement; that does not grant LaunchAgent ownership.

`disable` uses launchd's persistent disabled state and boots out the exact managed service. `repair` restores the recorded exact generation while preserving its loaded and disabled intent; `start` is the explicit operation that clears the owned disabled override and loads that generation. `uninstall` boots out the exact managed service, clears its persistent disabled override, hash-verifies the managed plist, validates every lifecycle file's exact path/type/owner/link/mode policy, and then removes those files. It preserves the manifest, SQLite state, distribution payload, Homebrew plist, and unrelated files.

`stop` is scoped to the current login session; the owned `RunAtLoad`/`KeepAlive` plist may load again at the next login. Use `disable` when the service must remain disabled across login or reboot. For an in-place `hostwright-dist` payload upgrade or rollback, stop the exact managed service first, complete the distribution operation, run `hostwright daemon repair` to revalidate the recorded path, then run `hostwright daemon start` to load it explicitly. Path-changing daemon generations use `hostwright daemon upgrade` and its one-generation `rollback` directly.

Required foreground inputs:

- `--foreground`
- `--config <path>`

Optional controls:

- `--interval <seconds>` for base cadence
- `--jitter <seconds>` for deterministic jitter cap
- `--max-backoff <seconds>` for repeated-error backoff cap
- `--parallelism <count>` for lifecycle DAG parallelism from 1 through 32
- `--max-iterations <count>` for bounded development runs
- `--state-db <path>` for an explicit state override
- `--lock-file <path>` for an explicit daemon lock file

If `--state-db` is omitted, the daemon uses `~/Library/Application Support/Hostwright/state/state.sqlite`. If `--lock-file` is omitted, default state uses `~/Library/Application Support/Hostwright/run/hostwrightd.lock`; explicit or environment-selected state uses a stable hashed lock name under that `run` directory. The config/manifest path remains explicit. The healthy cadence plus jitter is bounded to five seconds; defaults are five seconds and zero jitter. Failure backoff may grow only to the configured cap.

## Loop Contract

Each iteration:

1. Reads and validates the explicit manifest/config path.
2. Maps the manifest into desired runtime state.
3. Observes runtime state through `RuntimeAdapter`.
4. Runs bounded in-process loopback health checks for configured running services.
5. Computes health and restart-policy inputs without replacing the authoritative desired revision.
6. Computes a deterministic reconciliation plan with restart-state blocking and refuses blockers.
7. Calls the shared lifecycle driver with the exact manifest SHA-256, state path, project identity, and bounded parallelism.
8. The lifecycle driver freshly observes, compiles `up`, binds local image evidence, confirms the exact plan, revalidates, and executes through `LifecycleSagaExecutor`.
9. The saga acquires one project-scoped active operation group, persists intent and compensation, fences effects, re-observes ambiguous results, and verifies, compensates, interrupts, or enters a safe hold.
10. Only after the saga result, persists daemon health, restart, observed-state, operation, and event evidence, then sleeps according to cadence or bounded failure backoff.

The shared saga is the only daemon path that publishes the authoritative desired revision before effects. The outer loop never overwrites the last healthy revision merely because it read a new manifest. An empty lifecycle DAG records convergence. Verified execution records mutation. Compensation, interruption, safe hold, or a thrown error is a failed loop iteration and cannot be reported as convergence.

The daemon records `daemon.started`, `daemon.reconcile.converged`, `daemon.reconcile.mutated`, `daemon.reconcile.compensated`, `daemon.reconcile.interrupted`, `daemon.reconcile.safe-hold`, `daemon.reconcile.failed`, `daemon.backoff`, `daemon.sleep_wake_resumed`, `daemon.stopped`, `health.check.*`, and `restart.policy.state` events. Event payloads and matching `daemon.reconcile` operation records expose the versioned reason code, reconciliation and lifecycle plan hashes, node counts, checkpoint, and whether the plan contained mutation nodes.

Those events and daemon operation records are local forensic inputs for `hostwright events`, `hostwright recovery`, and `hostwright diagnostics`. The daemon does not export or upload them.

## Mutation Policy

Both daemon modes may execute only the supported `up` lifecycle DAG through the exact production CLI lifecycle driver. There is no daemon-specific provider executor and no direct Apple command path. The daemon reuses provider capability binding, exact plan confirmation, project/resource UUID ownership, provider/project generations, fencing, the three-attempt node retry limit, compensation, and safe holds.

Gate 2 does not add maintenance windows, restart budgets, rollout-policy expansion, garbage collection, broad deletion, Phase 09 transport, or multi-host authority. Unsupported drift and unmanaged collisions fail before mutation. Explicit CLI lifecycle and cleanup confirmation contracts remain unchanged.

## Locking And Shutdown

`hostwrightd` prepares the secure runtime directory, then uses a non-blocking single-instance file lock before it opens or migrates state. The parent chain must pass the secure path policy; the lock must be a current-user-owned, regular, non-symlink, single-link file with exact mode `0600`. If another instance holds the validated descriptor lock, the new process exits before running the loop. Each actual lifecycle mutation additionally requires the saga's single active project operation-group lease and exact fencing token, so a competing CLI or process cannot acquire the same project generation.

The foreground and managed processes handle SIGINT and SIGTERM by requesting shutdown. The loop checks the shutdown token between iterations and during sleep. Lifecycle mutations use an exclusive atomic pending-journal publication, so a competing controller observes recovery-required state instead of replacing another operation's intent.

## Sleep/Wake Model

The loop treats sleep/wake as a scheduler event. A wake-aware clock can report that sleep resumed after system wake; the daemon records `daemon.sleep_wake_resumed` and continues with the next iteration. The LaunchAgent uses launchd keepalive and login loading; dedicated attended qualification must prove reboot and logout/login behavior before Gate 1 passes.

### Attended reboot and login qualification

`scripts/phase08-daemon-qualification.sh` persists a private hash-bound v1 state so the exact installation can be verified across process loss. The qualification root must survive reboot: pre-create one empty canonical mode-`0700` direct child of `~/Library/Application Support/Hostwright/qualification` named `phase08-gate1-<canonical-uuid>`. Volatile roots such as `/tmp` and `/private/tmp` are rejected. Export its absolute path plus canonical built `hostwright`, `hostwrightd`, and config paths, then run the stages in order:

```bash
export HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT="$HOME/Library/Application Support/Hostwright/qualification/phase08-gate1-<canonical-uuid>"
export HOSTWRIGHT_PHASE08_HOSTWRIGHT=<absolute-built-hostwright>
export HOSTWRIGHT_PHASE08_DAEMON=<absolute-built-hostwrightd>
export HOSTWRIGHT_PHASE08_CONFIG=<absolute-hostwright.yaml>

scripts/phase08-daemon-qualification.sh prepare
# Reboot during the attended window, log back in, and reopen the same checkout.
# Re-export the same four values above in the new login session.
scripts/phase08-daemon-qualification.sh resume-reboot
# Log out and back in without rebooting, then reopen the same checkout.
# Re-export the same four values above in the new login session.
scripts/phase08-daemon-qualification.sh resume-login
```

Every action other than `contract` requires those four environment values. Re-export the identical values after each reboot or logout/login; the harness rejects changed paths or bytes against its durable hashes. The reboot stage requires a changed kernel boot epoch, GUI session handle, and daemon PID. The logout/login stage requires an unchanged boot epoch but a changed GUI session handle and daemon PID. Both bind the same installation UUID, generation, executable/config paths, and file hashes. The final stage uninstalls and verifies exact service/process absence; it retains the private evidence log. `cleanup` is available only for the recorded installation and refuses a different identity.

## Recovery And Troubleshooting

- `recovery-required`: run `hostwright daemon status --json`, preserve the named journal, and run `hostwright daemon repair`. Do not delete or edit the plist or journal by hand.
- `HW-DAEMON-104`: a loaded external service or unmanaged `hostwrightd` was detected. Stop it through its actual owner or use an isolated attended user session; Hostwright will not terminate or adopt it.
- `HW-DAEMON-103` or `HW-DAEMON-106`: ownership bytes, launchd state, or a checkpoint is ambiguous. Preserve the JSON result and private lifecycle records. Do not use `launchctl` or file replacement to force progress.
- `disabled`: `repair` revalidates while preserving disabled intent; use `hostwright daemon start` to clear only Hostwright's exact persistent disabled state and load the recorded generation.
- `rollback` unavailable: only the one exact prior generation captured by a successful upgrade is eligible; arbitrary executable/config downgrade is refused.

Status and validation are read-only. A failed preflight performs no plist or launchctl mutation. Cleanup must be done through `uninstall`, which refuses changed, linked, wrongly owned, or permission-invalid files.

## Current Sequenced Limitations

- privileged helper
- aggressive crash-loop restart policy enforcement
- restart-budget enforcement beyond launchd's bounded throttle
- image, volume, or unmanaged cleanup
