# Correlated Local Traces

Phase 08 Gate 14 provides a schema-v1 local trace projection over the existing schema-v17 SQLite `event_ledger`. It adds no trace table, schema v18 migration, network listener, persistent API, authentication surface, external exporter, or automatic upload.

## Inspect

```bash
hostwright traces inspect --state-db /absolute/private/state.sqlite --limit 20 --output json
hostwright traces inspect --state-db /absolute/private/state.sqlite --trace-id <uuid> --output json
```

Reads are bounded to 1 through 100 traces. Each view includes the canonical trace and process-correlation UUIDs, terminal status, bounded spans, dropped-span count, linked durable event and operation identifiers, and an exact `traceSHA256`. Reads require an existing compatible database and never create or migrate state.

The fixed span names cover CLI requests, daemon reconciliation iterations, planning, saga execution/recovery, provider observation/application, health evaluation, rollback compensation, finalizers, cleanup verification, and state persistence. A trace contains at most 64 spans, depth 12, eight closed attributes per span, 16 event links, 16 operation links, and 8 KiB per encoded span. User-controlled project, service, resource, provider, path, endpoint, command output, error text, credentials, PII, and secret references are not trace attributes.

CLI and daemon lifecycle work carries one stable context through synchronous code, structured concurrency, and the CLI async bridge. Operations and non-trace events link only after their authoritative SQLite transaction commits. A trace-span event is never recursively mirrored to OSLog. Lifecycle and recovery mutations are sampled; successful read-only and daemon iterations use deterministic 1-of-16 detail sampling with one retained root summary. Failure or cancellation overrides sampling and retains the bounded reconstruction. Sink failure is visible as degraded observability but cannot alter or fabricate the owning control outcome.

## Consent-bound export

First inspect the exact retained trace, then export only with its current hash:

```bash
hostwright traces export \
  --state-db /absolute/private/state.sqlite \
  --trace-id <uuid> \
  --output-path /absolute/private/new-trace.json \
  --confirm-trace <trace-sha256> \
  --output json
```

Export requires a complete trace, exact recomputed confirmation, a canonical current-user-owned private parent, and one new regular single-link mode-`0600` file. Descriptor and path identity are revalidated after the write. The output is capped at 1 MiB. Cancellation, write failure, replacement, symlink, hard-link, overwrite, or confirmation drift removes only the exact incomplete file when its identity is still proven. A successful export is operator-owned and is never uploaded or automatically deleted.

Trace-span rows have the independent Manifest-v2 `traces` retention class. Ordinary `events` and `audits` selection excludes them, while `hostwright events` may still display their durable rows. Compaction remains confirmation-bound, creates a verified backup, honors holds and recovery horizons, and deletes only exact eligible trace event identities.

Support bundles and aggregate soak qualification remain owned by Gates 15 and 16. The `observability.telemetry` capability remains `experimental` until Gate 16 passes.
