# Phase 42: One-Shot Local Control API

Issue #100 implements the first executable subset of the Phase 21 control-surface boundary.

## Implemented

- reusable `HostwrightCLI` command contracts behind the unchanged `hostwright` executable entry point;
- `HostwrightControl` plus `hostwright-control` for one version-1 stdin request, one stdout response, and process exit;
- explicit absolute launch paths for the manifest and optional state database and team profile, with no request-selected or default paths;
- strict operation support for plan, status, events, recovery, and doctor through existing CLI JSON behavior;
- unknown-field, duplicate-field, unsupported-version, unsafe-identifier/filter, oversized-input, and mutation-operation rejection;
- configured-file checks for regular non-symlink type, ownership, write mode, and set-ID bits;
- 64 KiB request, five-second input deadline, 1 MiB response, stable `HW-API-001` through `HW-API-003` errors, and delegated CLI exit-code preservation.

## Evidence

- Ten request/tool unit-contract tests cover strict JSON, escaped duplicate keys, versions, operation/filter rules, explicit launch paths, JSON value round trips, and real pipe EOF, overflow, and timeout behavior.
- Four local-integration tests use real temporary manifests, team-profile files, manifest parsing, a migrated SQLite database, event and recovery rows, redaction, and path-mode/symlink failures. No fake adapter or scripted process establishes a successful result.
- `scripts/integration.sh` invokes the built `hostwright-control` executable with a real manifest, verifies one-line JSON framing and plan output, rejects an `apply` request with exit 65 and `HW-API-001`, and confirms no state database was created.

These are `unit-contract` and `local-integration` results. State-backed status retains existing CLI behavior and can observe runtime, migrate the explicit database, and write snapshot/audit rows; that operation is runtime-non-mutating but not filesystem read-only.

## Boundaries

No apply, cleanup, logs, diagnostics export, benchmark, extension invocation, arbitrary command, direct RuntimeAdapter access, direct SQLite access, default path, persistent daemon, socket, HTTP listener, background service, remote control, telemetry upload, hosted diagnostics, dependency, release tag, GitHub Release, website work, or GUI code was added.
