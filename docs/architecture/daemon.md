# Daemon

`hostwrightd` is a foreground development loop in this phase. It is not an installed launch agent, background service, privileged helper, or unattended mutation engine.

## Current Behavior

The daemon runs only when explicitly started:

```bash
hostwrightd --foreground --config <hostwright.yaml> --state-db <path>
```

Required inputs:

- `--foreground`
- `--config <path>`
- `--state-db <path>`

Optional controls:

- `--interval <seconds>` for base cadence
- `--jitter <seconds>` for deterministic jitter cap
- `--max-backoff <seconds>` for repeated-error backoff cap
- `--max-iterations <count>` for bounded development runs
- `--lock-file <path>` for an explicit daemon lock file

If `--lock-file` is omitted, the lock file is derived from the explicit state database path as `<state-db>.hostwrightd.lock`. Hostwright still does not choose a default config path, state database path, or user-global daemon location.

## Loop Contract

Each iteration:

1. Reads and validates the explicit manifest/config path.
2. Maps the manifest into desired runtime state.
3. Observes runtime state through `RuntimeAdapter`.
4. Computes a deterministic reconciliation plan.
5. Persists desired state, observed state, a daemon operation record, and daemon events to the explicit state database.
6. Sleeps according to cadence, jitter, and repeated-error backoff.

Successful iterations persist desired and observed snapshots. Failed iterations persist a failed daemon operation and `daemon.reconcile.failed` event with a redacted diagnostic code; they do not claim a desired or observed snapshot was recorded.

The daemon records `daemon.started`, `daemon.reconcile.succeeded`, `daemon.reconcile.failed`, `daemon.backoff`, `daemon.sleep_wake_resumed`, and `daemon.stopped` events.

## Mutation Policy

Phase 15 uses the read-only local runtime adapter and does not call `RuntimeAdapter.execute`. The daemon may observe and plan actions, but it does not create, start, stop, restart, delete, repair, clean up, or otherwise mutate runtime resources.

Confirmed mutation remains limited to existing explicit CLI gates:

- `hostwright apply --state-db <path> --confirm-plan <hash>`
- `hostwright cleanup --state-db <path> --confirm-cleanup <token>`

## Locking And Shutdown

`hostwrightd` uses a non-blocking single-instance file lock before it opens or migrates state. If another instance holds the lock, the new process exits before running the loop.

The foreground process handles SIGINT and SIGTERM by requesting shutdown. The loop checks the shutdown token between iterations and during sleep.

## Sleep/Wake Model

The loop treats sleep/wake as a scheduler event. A wake-aware clock can report that sleep resumed after system wake; the daemon records `daemon.sleep_wake_resumed` and continues with the next iteration. This phase does not install macOS power notifications or launchd keepalive behavior.

## Non-Goals

- launch agent installation
- installer or uninstaller
- privileged helper
- default state database path
- unattended runtime mutation
- crash-loop restart policy enforcement
- broad lifecycle management
- image, volume, or unmanaged cleanup
