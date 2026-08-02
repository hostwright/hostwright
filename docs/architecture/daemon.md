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

The declared configuration set is versioned and content-bound. It always contains the explicit Manifest v2 file and includes only external trust or provenance policy-key paths explicitly referenced by that manifest. Relative policy paths resolve against the manifest directory. Hostwright does not search for profiles, infer filenames, or load remote configuration. Team workflow profiles remain explicit CLI inputs and are not daemon approval inputs.

Every target is opened with `O_NOFOLLOW` after validating the complete parent chain. Targets must be bounded NUL-free UTF-8, root- or current-user-owned regular single-link files without group/other writes. Device, inode, ownership, mode, link count, size, and modification metadata must remain exact across the read. The request binds the sorted target records, each content SHA-256, and one configuration-set SHA-256. The lifecycle driver securely reopens every exact target before planning, before revalidation, and immediately before execution; any identity or byte drift refuses the stale plan.

The daemon monitors only the parent directories of that validated set so atomic rename is observable. Events are coalesced into one pending bit, and the existing five-second level trigger remains authoritative if an event is missed. A change wakes the scheduler early without changing the cadence or retry contract. Replacing the same bytes does not create a new accepted content generation, while an identity change during an admitted reconciliation still forces a fresh iteration.

Each iteration:

1. Securely reads and validates the complete declared configuration set.
2. Maps the manifest into desired runtime state.
3. Observes runtime state through `RuntimeAdapter`.
4. Runs bounded in-process loopback health checks for configured running services.
5. Computes health and durable workload/project restart-budget inputs without replacing the authoritative desired revision.
6. Computes a deterministic reconciliation plan with restart-state blocking and refuses blockers.
7. Classifies the plan's elective action classes and evaluates the exact Manifest v2 maintenance policy. Outside a window it records or reuses one durable current deferral and never enters the lifecycle driver.
8. Calls the shared lifecycle driver with every exact configuration target, the configuration-set and manifest SHA-256 values, state path, project identity, bounded parallelism, and any exact maintenance admission binding.
9. The lifecycle driver freshly observes, compiles `up`, binds local image evidence, confirms the exact plan, revalidates the maintenance policy/token/open interval immediately before effects, and executes through `LifecycleSagaExecutor`.
10. The saga acquires one project-scoped active operation group, persists intent and compensation, fences effects, re-observes ambiguous results, and verifies, compensates, interrupts, or enters a safe hold.
11. Only after the saga result, persists daemon health, restart, observed-state, operation, maintenance, event, and bounded correlated-trace evidence, then sleeps according to cadence or bounded failure backoff.

The shared saga is the only daemon path that publishes the authoritative desired revision before effects. The outer loop never overwrites the last healthy revision merely because it read a new manifest. An empty lifecycle DAG records convergence. Verified execution records mutation. Compensation, interruption, safe hold, or a thrown error is a failed loop iteration and cannot be reported as convergence.

The daemon records `daemon.started`, `daemon.configuration.accepted`, `daemon.configuration.rejected`, `daemon.reconcile.converged`, `daemon.reconcile.mutated`, `daemon.reconcile.compensated`, `daemon.reconcile.interrupted`, `daemon.reconcile.safe-hold`, `daemon.reconcile.failed`, `daemon.backoff`, `daemon.sleep_wake_resumed`, `daemon.stopped`, `health.check.*`, and `restart.policy.state` events. One accepted event is persisted for each new content-bound configuration set. Repeated observation of the same invalid input is fingerprint-deduplicated; its raw bytes and path are not recorded, and the prior authoritative desired state remains unchanged. Event payloads and matching `daemon.reconcile` operation records expose bounded hashes, the accepted generation, versioned reason code, reconciliation and lifecycle plan hashes, node counts, checkpoint, and whether the plan contained mutation nodes.

Those events and daemon operation records are local forensic inputs for `hostwright events`, `hostwright recovery`, `hostwright diagnostics`, and the explicit local metrics projection. Every iteration also owns one canonical trace context. Successful iterations retain deterministic bounded detail or a root summary; failures retain the bounded plan, provider, health, saga, event, and operation correlation needed to reconstruct the failed lifecycle. Each new daemon reconciliation operation records one bounded non-negative `durationMilliseconds` value when the clock evidence is valid; legacy/malformed durations remain valid ledger rows but count as unsupported metrics samples. Local cursor pages and bounded long-poll watches read the authoritative SQLite append order, resume through exact event-bound cursors, and report retention gaps without adding a daemon listener. After a durable event transaction commits, a bounded structured mirror is emitted under the `dev.hostwright` OSLog subsystem with the daemon-run correlation identifier. The mirror contains fixed metadata rather than event messages or payloads; it is not authoritative and is never exported or uploaded. See [Durable Events and Local Watches](../reference/events.md), [Local Observability](../reference/observability.md), [Bounded Local Metrics and SLOs](../reference/metrics.md), and [Correlated Local Traces](../reference/traces.md).

## Mutation Policy

Both daemon modes may execute only the supported `up` lifecycle DAG through the exact production CLI lifecycle driver. There is no daemon-specific provider executor and no direct Apple command path. The daemon reuses provider capability binding, exact plan confirmation, project/resource UUID ownership, provider/project generations, fencing, the three-attempt node retry limit, compensation, and safe holds.

The daemon uses the shared Gate 7 last-verified-healthy compensation contract: exact inverse effects must be followed by fresh prior-revision ownership, running, and configured-probe proof or a reason-coded safe hold. It does not add garbage collection, broad deletion, Phase 09 transport, or multi-host authority. Unsupported drift and unmanaged collisions fail before mutation. Explicit CLI lifecycle and cleanup confirmation contracts remain unchanged.

### Health-gated rollout

The shared update DAG persists exact prior and candidate revision identity before effects and orders startup, readiness, liveness, dependency, and optional stable-observation gates before promotion. Stable observation re-runs configured readiness and liveness probes and persists its first continuously healthy timestamp. A process restart therefore resumes the exact stage and candidate rather than creating a duplicate workload. Promotion freshly re-observes the provider, exact candidate lifecycle, dependency states, probe checkpoint, and elapsed stable interval; missing, stale, unhealthy, or ambiguous evidence refuses promotion. Versioned lifecycle text and JSON status report the stage, node counts, exact prior/candidate identity, configured gates, stable duration, and progress deadline.

### Maintenance windows and change deferral

Manifest v2 may declare one local timezone and 1 through 64 recurring or one-shot windows. Each window explicitly lists the elective `create`, `start`, `restart`, `update`, and `remove` action classes it admits. A plan requiring multiple classes is admitted only when one active window allows every class. Recurring windows resolve daylight-saving gaps to the first representable later time and repeated times to the first occurrence. One-shot timestamps are canonical UTC. There is no cloud scheduler or filesystem-event dependency.

Outside every applicable window, the daemon records one current versioned deferral in the existing schema-v17 operation ledger, including exact plan/policy digests, action classes, first-deferral time, hard deadline, state, and confirmation token. A newer validated plan supersedes the prior pending record transactionally. Clock rollback cannot resurrect an older transition because durable append order is authoritative. Expired or cancelled work remains denied; sleep or a missed event is handled by the next level-triggered iteration.

`hostwright maintenance preview` is read-only. Status, exact-token cancellation, and explicit reason-bearing emergency override do not touch runtime. An override admits only its exact unchanged plan and policy. Immediately before lifecycle effects, the driver securely reopens the configuration set and revalidates the plan digest, policy digest, exact current token, and still-open interval. A concurrent cancellation, config change, closed window, or supersession refuses mutation. Existing active saga recovery and security-stop actions bypass elective windows because delaying them could leave an ambiguous or unsafe effect.

### Restart budgets and crash-loop holds

Manifest v2 may declare a project rolling budget with top-level `restartBudget.maxAttempts` and `restartBudget.window`. Each service `restart` policy may additionally declare `maxAttempts`, `window`, `backoff`, `maxBackoff`, `jitter`, `stableRun`, and `priority`. Defaults are 10 attempts per 300 seconds for a project and 3 attempts per 300 seconds for a workload, with 60-second initial backoff capped at 300 seconds, zero jitter, and a 60-second stable-run reset.

The daemon orders restart candidates by priority and exact identity, admits only remaining project capacity, and excludes blocked workloads plus their dependents from that lifecycle iteration. Independent eligible workloads continue. A workload consumes a durable attempt only when its exact mutating lifecycle node has a persisted forward `started` step; a mutation by another service cannot charge it. Each attempt records reason class, workload/project attempt number, policy digest, operation identity, deterministic bounded backoff, and outcome in schema v17. Repeated unchanged observations do not rewrite restart state or emit duplicate state events.

Attempts at the workload limit enter `crashLoopBlocked` with an exact SHA-256 hold token. Holds survive daemon and host restart. A stable healthy run resets the rolling workload state only after the declared duration. `hostwright restart-budget status` is read-only. `hostwright restart-budget release` requires the exact current project, service, and hold token; it atomically records the release generation, history, and event without starting or restarting the workload. A stale token changes nothing.

Restart state and history writes are fenced by that release generation inside the same SQLite transaction. A daemon iteration holding an older snapshot therefore cannot overwrite a concurrent manual release or resurrect its cleared hold.

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
- `crashLoopBlocked`: inspect `hostwright restart-budget status --project <project-id> --json`, correct the workload failure, then release only the exact current hold token. Release does not perform runtime mutation; the next level-triggered iteration re-observes before any admission.
- `projectBudgetBlocked`: wait for the rolling project window to expire or correct higher-priority failures. There is no project-wide bypass or implicit reset.
- `maintenanceDeferred`: inspect `hostwright maintenance status --project <project-id> --json`; wait for the reported applicable window or use only the exact current token for an explicitly justified override.
- `maintenanceDeadlineExpired` or `maintenanceCancelled`: the plan remains non-mutating. Change the validated desired generation when new work is intended; do not reuse an old token.
- maintenance confirmation mismatch at effect time: preserve the deferral and saga evidence. The policy, token, window, or configuration changed after admission, so the daemon must re-observe on a later level-triggered iteration.
- rollout promotion refused: inspect the lifecycle rollout status and exact operation group. Correct the failed or ambiguous startup, readiness, liveness, dependency, stable-observation, or progress-deadline evidence; do not delete the candidate or rewrite checkpoints by hand.

Status and validation are read-only. A failed preflight performs no plist or launchctl mutation. Cleanup must be done through `uninstall`, which refuses changed, linked, wrongly owned, or permission-invalid files.

## Current Sequenced Limitations

- privileged helper
- image, volume, or unmanaged cleanup
