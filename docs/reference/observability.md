# Local Observability

Hostwright emits structured local records to macOS unified logging under subsystem `dev.hostwright`. This OSLog stream is a best-effort diagnostic mirror. The schema-v17 SQLite event ledger remains the durable authority for operation, policy, recovery, and cleanup truth.

Inspect the stable human or machine-readable contract with `hostwright observability status` or `hostwright observability status --json`. The status reports schema, subsystem, categories, collection controls, size limits, durable and rotation authorities, and the explicit no-upload policy without reading or creating state.

## Log contract

Every Hostwright OSLog message uses record schema version 1 and contains a stable `HW-OBS-*` reason code, one correlation identifier, an outcome, and at most 12 fixed-name fields. Categories are bounded to `cli`, `daemon`, `reconciliation`, `runtime`, `health`, `recovery`, `state`, `security`, `lifecycle`, and `garbage-collection`. Every field carries a public/private construction annotation and defaults to private replacement; production code marks only fixed reviewed metadata public after redaction. Field values are single-line, limited to 128 UTF-8 bytes, the complete structured payload is limited to 2,048 bytes, and at most 64 lifecycle signpost intervals may be active in one process.

The production CLI emits correlated start and terminal records. State events committed while that command executes are mirrored only after their SQLite transaction succeeds and use the same correlation identifier. The managed and foreground daemon use one process-run correlation identifier; daemon event commits are mirrored through the same post-commit boundary. A failed command, daemon run, or event transaction cannot emit a success record.

Hostwright OSLog payloads do not copy command output, runtime stdout/stderr, event messages, event payloads, project names, service names, configuration paths, or manifest bytes. Dynamic fields pass construction-time exact-value and pattern redaction for credentials, authorization tokens, Keychain references, private keys, email addresses, local paths, IP addresses, and line-injection characters before they are marked public for structured local inspection. Fixed CLI command families replace unrecognized input with `unknown`. macOS adds its own unified-log metadata, which can include the local process image path, PID, user ID, and boot identity; Hostwright neither controls nor exports that system metadata.

The production sink supports explicit enablement and a minimum severity. Disabled or filtered records report a non-success emission result to their caller but do not change control-plane outcomes. Invalid record identity/shape, size, and reason/outcome contracts use stable `HW-OBS-001`, `HW-OBS-002`, and `HW-OBS-003` errors; a degraded injected sink reports `HW-OBS-130`. Unified-log persistence and rotation remain macOS responsibilities; Hostwright does not claim OSLog durability and never reconstructs operation success from a log entry. CLI and daemon run boundaries emit fixed lifecycle signpost intervals for local timing. No external exporter, listener, hosted telemetry, or automatic upload exists.

## Local inspection

Use the absolute macOS tool path because some shells provide a different `log` command:

```bash
/usr/bin/log show --last 5m --style ndjson \
  --predicate 'subsystem == "dev.hostwright"'
```

Narrow to one category or correlation identifier when investigating:

```bash
/usr/bin/log show --last 5m --style ndjson \
  --predicate 'subsystem == "dev.hostwright" AND category == "cli"'
```

OSLog collection reads existing system-managed local records and creates no Hostwright file. `~/Library/Logs/Hostwright` remains the private stdout/stderr destination for the managed LaunchAgent and is not an OSLog store. Use `hostwright events` for durable local event evidence.

## Current boundary

Phase 08 Gates 11–13 provide structured OSLog, durable local event cursors and bounded long-poll watches, plus a fixed-cardinality schema-v1 metrics/SLO projection and confirmation-bound local file export. Metrics read only retained schema-v17 authority and add no listener or automatic upload; see [Bounded Local Metrics and SLOs](metrics.md). Correlated traces, privacy-safe support bundles, and aggregate soak qualification remain owned by later Phase 08 gates. The `observability.telemetry` capability therefore remains `experimental` until the aggregate Gate 16 evidence passes.
