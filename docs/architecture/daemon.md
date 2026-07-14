# Daemon

`hostwrightd` is a foreground development loop in this phase. It is not an installed launch agent, background service, privileged helper, or unattended mutation engine.

## Current Behavior

The daemon runs only when explicitly started:

```bash
hostwrightd --foreground --config <hostwright.yaml>
```

Required inputs:

- `--foreground`
- `--config <path>`

Optional controls:

- `--interval <seconds>` for base cadence
- `--jitter <seconds>` for deterministic jitter cap
- `--max-backoff <seconds>` for repeated-error backoff cap
- `--max-iterations <count>` for bounded development runs
- `--state-db <path>` for an explicit state override
- `--lock-file <path>` for an explicit daemon lock file

If `--state-db` is omitted, the daemon uses `~/Library/Application Support/Hostwright/state/state.sqlite`. If `--lock-file` is omitted, default state uses `~/Library/Application Support/Hostwright/run/hostwrightd.lock`; explicit or environment-selected state uses a stable hashed lock name under that `run` directory. The config/manifest path remains explicit.

## Loop Contract

Each iteration:

1. Reads and validates the explicit manifest/config path.
2. Maps the manifest into desired runtime state.
3. Observes runtime state through `RuntimeAdapter`.
4. Runs bounded in-process loopback health checks for configured running services.
5. Persists health results and restart policy state.
6. Computes a deterministic reconciliation plan with restart-state blocking.
7. Persists desired state, observed state, a daemon operation record, and daemon events to the selected state database.
8. Sleeps according to cadence, jitter, and repeated-error backoff.

Successful iterations persist desired and observed snapshots. Failed iterations persist a failed daemon operation and `daemon.reconcile.failed` event with a redacted diagnostic code; they do not claim a desired or observed snapshot was recorded.

The daemon records `daemon.started`, `daemon.reconcile.succeeded`, `daemon.reconcile.failed`, `daemon.backoff`, `daemon.sleep_wake_resumed`, `daemon.stopped`, `health.check.*`, and `restart.policy.state` events.

Those events and daemon operation records are local forensic inputs for `hostwright events`, `hostwright recovery`, and `hostwright diagnostics`. The daemon does not export or upload them.

## Mutation Policy

The foreground daemon uses the read-only local runtime adapter and does not call `RuntimeAdapter.execute`. It may observe, run bounded in-process loopback health checks, persist restart policy state, and plan actions, but it does not create, start, stop, restart, delete, repair, clean up, or otherwise mutate runtime resources.

Confirmed mutation remains limited to existing explicit CLI gates:

- `hostwright apply --confirm-plan <hash>`
- `hostwright cleanup --confirm-cleanup <token>`

## Locking And Shutdown

`hostwrightd` prepares the secure runtime directory, then uses a non-blocking single-instance file lock before it opens or migrates state. The parent chain must pass the secure path policy; the lock must be a current-user-owned, regular, non-symlink, single-link file with exact mode `0600`. If another instance holds the validated descriptor lock, the new process exits before running the loop.

The foreground process handles SIGINT and SIGTERM by requesting shutdown. The loop checks the shutdown token between iterations and during sleep.

## Sleep/Wake Model

The loop treats sleep/wake as a scheduler event. A wake-aware clock can report that sleep resumed after system wake; the daemon records `daemon.sleep_wake_resumed` and continues with the next iteration. This phase does not install macOS power notifications or launchd keepalive behavior.

## Current Sequenced Limitations

- launch agent installation
- installer or uninstaller
- privileged helper
- unattended runtime mutation
- aggressive crash-loop restart policy enforcement
- broad lifecycle management
- image, volume, or unmanaged cleanup
