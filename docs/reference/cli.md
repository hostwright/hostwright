# CLI Reference

The current CLI provides a dependency-free `hostwright` command surface with narrow RuntimeAdapter-backed operation gates.

## Commands

```bash
hostwright --version
hostwright init
hostwright validate [path]
hostwright plan [path] [--output text|json]
hostwright status [path] [--state-db <path>] [--output text|json]
hostwright apply [path] --state-db <path> --confirm-plan <hash>
hostwright logs <service> [path] [--tail <n>] [--state-db <path>]
hostwright events --state-db <path> [--project <name>] [--output text|json]
hostwright cleanup [path] --state-db <path> --dry-run
hostwright cleanup [path] --state-db <path> --confirm-cleanup <token>
hostwright doctor [--output text|json]
```

## Output Modes

Text output is the default for every command.

`plan`, `status`, `events`, and `doctor` also accept `--output json`. JSON output is intended for local scripts and tests. It does not change command behavior, state writes, runtime observation, or mutation gates.

When JSON mode is requested and the CLI can classify the failure, stderr uses this envelope:

```json
{"code":"HW-CLI-001","exitCode":64,"kind":"error","message":"..."}
```

Manifest failures use an `issues` array with stable Hostwright error codes. `doctor --output json` reports compatibility failures as a normal doctor JSON document on stdout with `hasFailures: true` and exit code 65, not as an error envelope.

## Exit Codes

| Exit code | Category | Typical commands |
| ---: | --- | --- |
| `0` | Success | All commands |
| `64` | Usage | Unsupported flags, missing arguments, refused overwrite |
| `65` | Validation | Manifest parse/validation and compatibility failures |
| `66` | State unavailable | Explicit SQLite state path could not be opened, migrated, verified, locked, or read |
| `69` | Runtime unavailable | Runtime observation, logs, or mutation failed through `RuntimeAdapter` |
| `70` | Confirmation mismatch | `apply --confirm-plan` or `cleanup --confirm-cleanup` did not match the current observed plan |
| `71` | Unsafe operation | Planner/apply safety policy blocked mutation |
| `72` | Partial failure | Cleanup completed with mixed success and failure |

## `hostwright --version`

Prints the current release candidate version:

```text
0.1.0-alpha.1
```

The first public release target is `v0.1.0-alpha.1`.

## `hostwright init`

Creates `hostwright.yaml` in the current directory only when the file does not already exist.

`--force` is not implemented; existing manifests are not overwritten.

Failure example:

```text
HW-CLI-002: hostwright.yaml already exists. init will not overwrite it.
```

## `hostwright validate [path]`

Reads `hostwright.yaml` by default, or a provided path, and validates the restricted Hostwright manifest shape.

It does not:

- contact registries;
- contact Apple container;
- check whether images exist remotely;
- mutate runtime state.

Failure example:

```text
HW-MANIFEST-002: service 'api' must declare an image.
```

## `hostwright plan [path] [--output text|json]`

Reads and validates the manifest, maps the supported manifest subset into runtime-shaped desired state, runs planning policy checks, and prints a non-mutating dry-run plan.

The output includes a deterministic plan hash, typed issues, typed planned actions, and an explicit execution-unavailable notice.

Runtime observation infrastructure exists behind `RuntimeAdapter`, but `hostwright plan` does not inspect Apple container by default and does not claim resources are running, stopped, healthy, or unhealthy.

JSON shape:

```json
{
  "kind": "plan",
  "project": "api-local",
  "planHash": "...",
  "observationConnected": false,
  "issues": [],
  "drift": [],
  "actions": []
}
```

## `hostwright apply [path] --state-db <path> --confirm-plan <hash>`

Runs the narrow confirmed apply gate.

This command:

- validates the manifest;
- observes Apple container through `RuntimeAdapter`;
- recomputes the deterministic plan;
- requires an explicit state database path;
- requires the supplied plan hash to match the current observed plan;
- persists desired state, observed state, operation intent, and an apply-start event before mutation;
- executes exactly one `createMissingService` action or one restart-policy-allowed `startManagedService` action through `RuntimeAdapter`;
- records success or failure events and operation status.

It refuses mutation when:

- `--state-db` is missing;
- `--confirm-plan` is missing or mismatched;
- runtime observation fails;
- the plan has blockers;
- zero executable actions exist;
- more than one executable action exists;
- a create action uses mounts, privileged host ports, broad bind addresses, flag-like image values, or service command tokens beginning with `-`;
- a create action cannot confirm the local Apple container image;
- a start action is not for an observed Hostwright-managed stopped, created, or exited service allowed by restart policy.

Manifest-declared ports are published to `127.0.0.1` by default during Hostwright-created container creation. Sensitive environment values are passed to the runtime for execution, but plan output, state rows, events, logs, and errors use redacted values.

It does not implement stop, restart, image replacement, port mutation, mount mutation, rollback, image pull, daemon loops, broad bind exposure, or multi-action apply.

Failure example:

```text
HW-CLI-003: Confirmed plan hash does not match current observed plan.
```

## `hostwright status [path] [--state-db <path>] [--output text|json]`

Without `--state-db`, reports manifest-level status only.

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
- log output is redacted before display;
- `--follow`, attach, interactive, and exec behavior are not implemented;
- when `--state-db` is supplied, a `logs.read` event is persisted.

Failure example:

```text
HW-RUNTIME-001: logs requires an observed Hostwright-managed service.
```

## `hostwright events --state-db <path> [--project <name>] [--output text|json]`

Reads the SQLite event ledger from an explicit, already-migrated state database path and renders events in deterministic timestamp/id order.

It does not inspect runtime state and does not create or migrate the database as a read side effect.

JSON shape:

```json
{
  "kind": "events",
  "stateDatabasePath": "/tmp/hostwright.sqlite",
  "events": []
}
```

## `hostwright cleanup [path] --state-db <path> --dry-run`

Plans cleanup candidates only. A candidate is eligible only when all of these are true:

- an ownership record marks the resource cleanup-eligible;
- the resource type is `container`;
- the runtime identifier is exact and Hostwright-owned;
- the project/service match the manifest;
- live observation shows the service is created, stopped, or exited, not running.

The dry run prints an exact confirmation token.

Failure example:

```text
HW-CLI-001: cleanup requires exactly one of --dry-run or --confirm-cleanup <token>.
```

## `hostwright cleanup [path] --state-db <path> --confirm-cleanup <token>`

Deletes only the exact eligible containers covered by the current cleanup token through `RuntimeAdapter`.

It never deletes images, volumes, networks, or unmanaged containers and never uses broad flags such as `--all` or `--force`.

If one candidate fails after another succeeds, the process exits with code `72` and preserves successful deletions in the report.

## `hostwright doctor [--output text|json]`

Runs safe local checks only:

- OS version string;
- architecture/macOS compatibility gate;
- Swift toolchain version through a controlled `swift --version` process;
- `container` executable lookup only;
- `hostwright.yaml` presence.

`doctor` does not run Apple container commands.

JSON shape:

```json
{
  "kind": "doctor",
  "hasFailures": false,
  "checks": []
}
```

Shell completion remains research-only in Phase 12. Hostwright does not install shell completions or mutate shell profile files.
