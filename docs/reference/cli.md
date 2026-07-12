# CLI Reference

The current CLI provides a dependency-free `hostwright` command surface with narrow RuntimeAdapter-backed operation gates.

## Commands

```bash
hostwright --version
hostwright init
hostwright import-stack <path> [--output text|json] [--team-profile <path>]
hostwright validate [path] [--team-profile <path>]
hostwright plan [path] [--output text|json] [--team-profile <path>]
hostwright status [path] [--state-db <path>] [--output text|json]
hostwright apply [path] --state-db <path> --confirm-plan <hash> [--team-profile <path> --approval-record <path>]
hostwright logs <service> [path] [--tail <n>] [--state-db <path>]
hostwright events --state-db <path> [--project <name>] [--type <event>] [--service <name>] [--severity info|warning|error] [--limit <n>] [--sort asc|desc] [--output text|json]
hostwright recovery --state-db <path> [--project <name>] [--output text|json]
hostwright diagnostics --state-db <path> --bundle <path> [--project <name>] [--manifest <path>]
hostwright cleanup [path] --state-db <path> --dry-run [--team-profile <path>]
hostwright cleanup [path] --state-db <path> --confirm-cleanup <token> [--team-profile <path> --approval-record <path>]
hostwright benchmark --image <local-image> --samples <3-10> --report <path> --source-commit <40-hex> --source-dirty <true|false> --expected-container-version <version> [--attended-sleep-wake-seconds <15-300>] --confirm-live
hostwright doctor [--output text|json]
hostwrightd --foreground --config <hostwright.yaml> --state-db <path> [options]
```

## Output Modes

Text output is the default for every command.

`import-stack`, `plan`, `status`, `events`, `recovery`, and `doctor` also accept `--output json`. JSON output is intended for local scripts and tests. It does not change command behavior, state writes, runtime observation, or mutation gates.

When JSON mode is requested and the CLI can classify the failure, stderr uses this envelope:

```json
{"code":"HW-CLI-001","exitCode":64,"kind":"error","message":"..."}
```

Manifest failures use an `issues` array with stable Hostwright error codes. `doctor --output json` reports compatibility failures as a normal doctor JSON document on stdout with `hasFailures: true` and exit code 65, not as an error envelope.

## Exit Codes

| Exit code | Category | Typical commands |
| ---: | --- | --- |
| `0` | Success | All commands |
| `64` | Usage | Unsupported flags, missing arguments, refused overwrite, or local non-manifest file I/O failure |
| `65` | Validation | Missing/unreadable manifest, manifest/profile/approval validation, and compatibility failures |
| `66` | State unavailable | Explicit SQLite state path could not be opened, migrated, verified, locked, or read |
| `69` | Runtime unavailable or evidence blocked | Runtime observation/mutation unavailable, or benchmark prerequisites/dimensions remain blocked |
| `70` | Confirmation mismatch | Plan, cleanup token, approval scope, or approval hash bindings do not match the current operation |
| `71` | Unsafe operation | Planner/apply safety policy blocked mutation |
| `72` | Partial failure | Cleanup completed with mixed success/failure, or benchmark command/identity/cleanup evidence failed |

## `hostwright --version`

Prints the current release candidate version:

```text
0.1.0-alpha.1
```

The first public release target is `v0.1.0-alpha.1`.

## `hostwright init`

Creates `hostwright.yaml` in the current directory only when the file does not already exist.

`--force` is not implemented; existing manifests are not overwritten.

A local write failure uses `HW-CLI-005` and exit code 64.

Failure example:

```text
HW-CLI-002: hostwright.yaml already exists. init will not overwrite it.
```

## `hostwright import-stack <path> [--output text|json] [--team-profile <path>]`

Reads a narrow safe stack-file subset and prints converted `hostwright.yaml` text to stdout. It does not write files, create `hostwright.yaml`, read or write state, observe Apple container, contact registries, pull images, or mutate runtime resources.

A missing or unreadable stack-file input uses `HW-CLI-005` and exit code 64. JSON mode returns the standard error envelope on stderr.

Supported import input is intentionally small:

- top-level `name` or `project`;
- top-level `services`;
- service `image`;
- service `command` as an inline array;
- service `environment` as a key-value map with plain or quoted scalar values;
- service `ports` as string list entries like `"8080:8080"`;
- service `volumes` only when each source is an explicit host path such as `./data` or `/tmp/data`;
- service `healthcheck.test` only as `["CMD", ...]`;
- service `healthcheck.interval`;
- service `restart` as a scalar policy or `restart.policy`.

Unsupported, unknown, or high-risk stack-file fields fail closed with stable diagnostics. This includes build contexts, named volumes, `secrets`, `configs`, `env_file`, `depends_on`, `deploy`, `network_mode`, `networks`, DNS/service discovery fields, shell health checks, cloud/tunnel semantics, and lifecycle behavior that Hostwright cannot convert safely.

Text success prints the converted manifest and warnings on stderr. JSON success uses:

```json
{
  "kind": "stackImport",
  "sourcePath": "compose.yaml",
  "succeeded": true,
  "manifest": "version: 1\nproject: demo\n...",
  "warnings": []
}
```

JSON import failures use the standard validation exit code `65` and include policy reason codes when the local policy layer classified the rejection:

```json
{
  "kind": "error",
  "code": "HW-MANIFEST-003",
  "exitCode": 65,
  "sourcePath": "compose.yaml",
  "issues": [
    {
      "code": "HW-MANIFEST-003",
      "severity": "error",
      "policyReasonCode": "secureExposureUnsupported",
      "message": "..."
    }
  ]
}
```

Import is conversion-only. It does not imply Docker Compose compatibility or runtime compatibility. Review the converted manifest and run `hostwright validate` and `hostwright plan` before any confirmed apply.

When `--team-profile` is present, the converted manifest is also evaluated against that explicit local profile. Text mode keeps converted manifest stdout parseable and writes profile hashes to stderr; JSON mode adds a `teamPolicy` object. No profile is discovered by default.

## `hostwright validate [path] [--team-profile <path>]`

Reads `hostwright.yaml` by default, or a provided path, and validates the restricted Hostwright manifest shape.

It does not:

- contact registries;
- contact Apple container;
- check whether images exist remotely;
- mutate runtime state.

With an explicit profile, validation also enforces its strict-only requirements and prints the profile and exact manifest SHA-256 hashes. `requireImageDigest` rejects tag-only images even when the manifest defaults to `allow-tags`.

Failure example:

```text
HW-MANIFEST-002: service 'api' must declare an image.
```

## `hostwright plan [path] [--output text|json] [--team-profile <path>]`

Reads and validates the manifest, maps the supported manifest subset into runtime-shaped desired state, runs planning policy checks, and prints a non-mutating dry-run plan.

The output includes a deterministic plan hash, typed issues, typed planned actions, and an explicit execution-unavailable notice.

Runtime observation infrastructure exists behind `RuntimeAdapter`, but `hostwright plan` does not inspect Apple container by default and does not claim resources are running, stopped, healthy, or unhealthy.

With an explicit profile, output includes `profileHash`, `manifestHash`, the exact `planHash` binding, and `approvalRequiredForMutation: true`.

JSON shape:

```json
{
  "kind": "plan",
  "project": "api-local",
  "planHash": "...",
  "teamPolicy": {
    "profileIdentifier": "dev.hostwright.team.local",
    "profileHash": "...",
    "manifestHash": "...",
    "planHash": "...",
    "approvalRequiredForMutation": true
  },
  "observationConnected": false,
  "issues": [],
  "drift": [],
  "actions": []
}
```

## `hostwright apply [path] --state-db <path> --confirm-plan <hash> [--team-profile <path> --approval-record <path>]`

Runs the narrow confirmed apply gate.

This command:

- validates the manifest;
- observes Apple container through `RuntimeAdapter`;
- recomputes the deterministic plan;
- requires an explicit state database path;
- requires the supplied plan hash to match the current observed plan;
- persists desired state, observed state, operation intent, and an apply-start event before mutation;
- executes exactly one `createMissingService`, restart-policy-allowed `startManagedService`, or restart-policy-allowed `restartManagedService` action through `RuntimeAdapter`;
- records operation recovery groups, forward runtime steps, rollback-unavailable steps, checkpoints, and redacted manual recovery hints;
- records success or failure events and operation status.

When `--team-profile` is selected, `--approval-record` is mandatory. The approved record must match the exact profile SHA-256, manifest SHA-256, current plan hash, and `apply` scope. Hostwright computes the approval SHA-256 and carries all four hashes into runtime confirmation and redacted append-only audit records. Missing, rejected, stale, wrong-scope, or mismatched approvals fail before mutation.

It refuses mutation when:

- `--state-db` is missing;
- `--confirm-plan` is missing or mismatched;
- runtime observation fails;
- the plan has blockers;
- zero executable actions exist;
- more than one executable action exists;
- a create action uses mounts, privileged host ports, broad bind addresses, flag-like image values, or service command tokens beginning with `-`;
- a create action cannot confirm the local Apple container image;
- a start action is not for an observed Hostwright-managed stopped, created, or exited service allowed by restart policy;
- a restart action is not for an exact Hostwright-owned running service with a fresh persisted unhealthy health result and a matching ownership record.
- an operation group with the same idempotency key still has an active lease; the error reports its redacted owner, checkpoint, and expiry without attempting mutation.
- a profile-aware approval is absent, rejected, wrong-scope, or bound to different profile, manifest, or plan data.

An interrupted operation can reuse the same plan only when its persisted checkpoint proves runtime execution never began (`pre-runtime-state-incomplete`). Completed operations and interruptions with ambiguous or post-runtime state remain blocked.

Manifest-declared ports are published to `127.0.0.1` by default during Hostwright-created container creation. Sensitive environment values are passed to the runtime for execution, but plan output, state rows, events, logs, and errors use redacted values.

It does not implement user-facing stop/restart commands, image replacement, port mutation, mount mutation, automatic rollback, image pull, unattended daemon mutation, broad bind exposure, or multi-action apply.

Failure example:

```text
HW-CLI-003: Confirmed plan hash does not match current observed plan.
```

## `hostwright status [path] [--state-db <path>] [--output text|json]`

Without `--state-db`, reports manifest-level status only.

A missing or unreadable manifest is a validation failure (`HW-MANIFEST-004`, exit 65), including in JSON mode; absence is not reported as successful status.

With `--state-db`, validates the manifest, observes Apple container through `RuntimeAdapter`, persists a status observation event and snapshot to the explicit state database path, and renders desired services against observed lifecycle/health/port facts.

It does not mutate runtime state.

JSON shape:

```json
{
  "kind": "status",
  "manifest": {"path": "hostwright.yaml", "valid": true, "exists": true},
  "runtime": {"observed": true},
  "services": []
}
```

## `hostwright logs <service> [path] [--tail <n>] [--state-db <path>]`

Reads the last log lines for a declared and observed Hostwright-managed service through `RuntimeAdapter`.

Rules:

- default tail is 100 lines;
- maximum tail is clamped to 1000 lines;
- the adapter receives the exact observed runtime identifier rather than recomputing a container name; an explicit state path supplies migrated legacy ownership hints;
- log output is redacted before display;
- `--follow`, attach, interactive, and exec behavior are not implemented;
- when `--state-db` is supplied, a `logs.read` event with the exact resource identifier is persisted.

Failure example:

```text
HW-RUNTIME-001: logs requires an observed Hostwright-managed service.
```

## `hostwright events --state-db <path> [--project <name>] [--type <event>] [--service <name>] [--severity info|warning|error] [--limit <n>] [--sort asc|desc] [--output text|json]`

Reads the SQLite event ledger from an explicit, already-migrated state database path and renders events in deterministic timestamp/id order.

It does not inspect runtime state and does not create or migrate the database as a read side effect.

Filters are applied after project selection and before rendering:

- `--type <event>` matches the event type, such as `cleanup.failed`.
- `--service <name>` matches a service name on event rows that carry one.
- `--severity info|warning|error` matches event severity.
- `--limit <n>` returns the first `n` filtered records in the selected order.
- `--sort asc|desc` defaults to `asc`.

JSON shape:

```json
{
  "kind": "events",
  "stateDatabasePath": "/tmp/hostwright.sqlite",
  "filters": {"sort": "asc"},
  "events": []
}
```

## `hostwright recovery --state-db <path> [--project <name>] [--output text|json]`

Reads operation recovery groups and steps from an explicit, already-migrated state database path. For older state databases that contain managed restart recovery records but no Phase 18 operation group for the same operation, the command renders those restart records as legacy recovery entries.

It does not inspect runtime state, create or migrate the database as a read side effect, retry operations, or roll back runtime changes. Recovery output distinguishes:

- no automatic recovery required;
- manual inspection required after a failed or interrupted operation;
- rollback unsupported because no safe inverse operation is proven.

Active groups include their redacted lock owner and lease expiry in text and JSON output. A group with no persisted mutation intent can be reacquired after expiry, which marks the old group interrupted. A recorded intent remains blocked unless the persisted checkpoint proves runtime execution never began; ambiguous or post-runtime interruptions require manual inspection.

JSON shape:

```json
{
  "kind": "recovery",
  "stateDatabasePath": "/tmp/hostwright.sqlite",
  "operationGroups": []
}
```

## `hostwright diagnostics --state-db <path> --bundle <path> [--project <name>] [--manifest <path>]`

Writes a local redacted JSON diagnostics bundle to the exact `--bundle` path.

The command reads only the explicit, already-migrated state database path and optional manifest path. If `--manifest` is omitted, the bundle is state-only; it does not discover `hostwright.yaml` from the current directory.

The bundle includes:

- telemetry policy: local-only, no upload;
- state schema/version metadata;
- optional manifest summary;
- redacted events, operations, operation groups, operation group steps, health results, restart policy state, restart recovery records, ownership records, and observed snapshots.

The command does not inspect Apple container, observe runtime state, mutate runtime state, create or migrate a missing database, overwrite an existing bundle path, or upload telemetry.

Example:

```bash
hostwright diagnostics --state-db /tmp/hostwright.sqlite --bundle /tmp/hostwright-diagnostics.json --project api-local
```

## `hostwright cleanup [path] --state-db <path> --dry-run [--team-profile <path>]`

Plans cleanup candidates only. A candidate is eligible only when all of these are true:

- an ownership record marks the resource cleanup-eligible;
- the resource type is `container`;
- the runtime identifier is exact and Hostwright-owned;
- the project/service match the manifest;
- live observation shows the service is created, stopped, or exited, not running.

The dry run prints an exact confirmation token and classifies ownership-backed and observed-only resources:

With an explicit profile, the token also binds the profile and manifest hashes. The dry run prints those hashes and requires a new cleanup-scoped approval for confirmed deletion. It does not accept `--approval-record` because review must occur after the exact token is known.

- `eligible`: exact Hostwright-owned created/stopped/exited container covered by the token.
- `ambiguous`: duplicate observed runtime identities make the target unsafe.
- `stale`: ownership exists but no matching live container is observed, or runtime reports it missing.
- `running`: live container is running and is never deleted by cleanup.
- `unknown`: runtime lifecycle is unknown.
- `blocked`: ownership/service/adapter state does not safely match the live observation.
- `never-delete`: cleanup eligibility is disabled, the record is not a container, belongs to another project, is not Hostwright-managed, or is observed without a Hostwright ownership record.

Failure example:

```text
HW-CLI-001: cleanup requires exactly one of --dry-run or --confirm-cleanup <token>.
```

## `hostwright cleanup [path] --state-db <path> --confirm-cleanup <token> [--team-profile <path> --approval-record <path>]`

Deletes only `eligible` containers covered by the current cleanup token through `RuntimeAdapter`.

Profile-aware confirmed cleanup requires an approval record bound to the exact profile hash, manifest hash, cleanup token, and `cleanup` scope. Approval never changes eligibility, ownership, lifecycle, or exact-identifier checks.

It never deletes images, volumes, networks, or unmanaged containers and never uses broad flags such as `--all` or `--force`.

If one runtime delete fails after another succeeds, the process exits with code `72` and preserves successful deletions in the report. If a delete succeeds but success-state persistence fails, the process reports state unavailable and keeps the deletion visible in stdout.

See `docs/reference/team-workflow.md` for the strict JSON schemas and review sequence.

## `hostwright benchmark ... --confirm-live`

Runs an explicitly confirmed local hardware benchmark and writes a schema-v2 JSON report to a path that must not exist. Required inputs bind the report to a source commit, dirty state, local image, sample count, and expected Apple container version.

Before mutation, the command records RuntimeAdapter metadata/capabilities, exact Apple container version, and the requested local image's descriptor digest, selected platform-variant digest, architecture, and OS. Unexpected version, missing local image, non-arm64 variant, or missing cleanup capability stops before creation.

The command performs 3-10 iterations. Each iteration creates a unique labeled `hostwright-v2-bench-...` resource through `RuntimeAdapter`, starts a bounded process, records boot/poll durations and one exact non-streaming stats sample, waits for terminal-state quiescence, deletes only that identifier, and verifies absence. It never pulls the image, uses a default path, writes SQLite, deletes images/volumes, uses broad cleanup, or uploads the report.

`--attended-sleep-wake-seconds <15-300>` keeps the first bounded process available during an operator-attended window. The command does not put the Mac to sleep. It records sleep/wake as observed only when wall time exceeds monotonic uptime by at least two seconds and the exact resource is observable after wake.

Exit behavior is evidence-driven:

- `0`: every dimension was measured and exact cleanup succeeded;
- `69` / `HW-BENCH-002`: one or more capabilities or dimensions are blocked, including an unexecuted attended sleep/wake protocol;
- `72` / `HW-BENCH-003`: a command, version, identity, ownership, report-validation, or cleanup failure occurred.

Blocked and failed runs still write their report when encoding and file output succeed. Missing confirmation or an existing report path is refused before runtime access.

This command records local evidence only. Its values are not capacity, compatibility, efficiency, or comparative performance claims.

## `hostwright doctor [--output text|json]`

Runs safe local checks only:

- OS version string;
- architecture/macOS compatibility gate;
- Swift toolchain version through a controlled `swift --version` process;
- `container` executable lookup only;
- `hostwright.yaml` presence;
- explicit state-path policy;
- local-only telemetry policy;
- resource intelligence with local host facts and explicit unmeasured benchmark dimensions.

`doctor` does not run Apple container commands. In live output, Apple container version remains unavailable unless an injected or fixture-backed resource report supplies it.

JSON shape:

```json
{
  "kind": "doctor",
  "hasFailures": false,
  "resourceReport": {
    "measurementMethod": "localProcessInfoSnapshot",
    "memoryPressure": {
      "status": "unmeasured"
    },
    "limits": [
      "No production density or capacity guarantee."
    ]
  },
  "checks": []
}
```

## `hostwrightd --foreground --config <path> --state-db <path> [options]`

Runs the foreground development daemon loop. It requires explicit config and state paths.

Options:

- `--interval <seconds>`: base reconciliation cadence; default `30`.
- `--jitter <seconds>`: deterministic jitter cap; default `5`.
- `--max-backoff <seconds>`: repeated-error backoff cap; default `300`.
- `--max-iterations <count>`: stop after a bounded number of iterations for development proof.
- `--lock-file <path>`: explicit daemon lock path; default is `<state-db>.hostwrightd.lock`.

Each iteration validates the manifest, observes runtime through `RuntimeAdapter`, computes a plan, and records daemon events plus operation records in the explicit state database.

It does not call `RuntimeAdapter.execute`, does not install a launch agent, and does not perform unattended runtime mutation.

Shell completion remains research-only in Phase 12. Hostwright does not install shell completions or mutate shell profile files.
