# Phase 20: Observability And Diagnostics

## What changed

- `hostwright events` can filter by project, event type, service, severity, limit, and ascending or descending sort order.
- `hostwright diagnostics --state-db <path> --bundle <path>` writes a local redacted JSON bundle from existing state rows.
- Diagnostic bundles include state schema metadata, optional explicit manifest summary, events, operations, operation recovery groups and steps, health results, restart state, restart recovery records, ownership records, and observed snapshots.
- `hostwright status` and `hostwright doctor` report local-only telemetry policy and explicit state-path boundaries.
- State diagnostics export is isolated inside `HostwrightState`; CLI code does not read SQLite directly.

## Assumptions

- Diagnostic export is an operator-driven local file operation.
- The explicit state database path remains the source of diagnostic truth.
- Redaction removes known secret-like values, but bundles can still contain sensitive local context such as project names, service names, paths, hostnames, identifiers, and timestamps.

## Rejected paths

- No external telemetry.
- No hosted diagnostics.
- No automatic upload.
- No OSLog integration.
- No production support-bundle workflow.
- No runtime observation or mutation during diagnostics export.
- No hidden default state path.
