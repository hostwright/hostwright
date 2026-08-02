# Bounded Local Metrics and SLOs

Phase 08 Gate 13 provides a schema-v1, local, read-only metrics projection over the existing schema-v17 SQLite authority. It adds no metrics table, background collector, network listener, scrape endpoint, persistent API, authentication surface, or automatic upload. Collection occurs only when an operator runs `hostwright metrics`; a metrics failure cannot block, authorize, or alter control work.

## Snapshot

```bash
hostwright metrics snapshot --state-db /absolute/private/state.sqlite --output json
```

The command requires an existing, current, secure state database. It never creates or migrates missing or older state. One shared state fence and SQLite read transaction produce fixed aggregate series, three observational SLO results, the source database SHA-256 and byte count, retention truth, and a confirmation-ready `snapshotSHA256`. The generated timestamp is informational and is excluded from that identity, so an unchanged source projection retains the same confirmation hash.

The catalog contains nine counters, four gauges, one histogram, and one summary. Every descriptor owns its label keys and fixed values. Project, service, resource, operation, image, provider, host, endpoint, path, error text, credentials, secret references, and other user-controlled values cannot become labels. A snapshot has 59 fixed series under a hard limit of 128. Histogram boundaries are `0.01`, `0.05`, `0.1`, `0.25`, `0.5`, `1`, `2.5`, `5`, `10`, and `30` seconds. The reconciliation summary reports count, sum, minimum, maximum, and mean; it does not publish unstable quantiles.

Rejected source evidence increments only `invalid-record`, `unsupported-duration`, `overflow`, or `series-budget`. Legacy daemon records without a bounded numeric duration remain valid but count as `unsupported-duration`.

## Observational SLOs

The fixed SLO calculations are:

- reconciliation success ratio at least `0.99`;
- runtime-action success ratio at least `0.99`;
- reconciliation duration p95 no more than `5` seconds.

Each calculation needs at least 20 eligible samples. Smaller populations report `insufficient-data`, not success. The p95 result uses the fixed histogram boundaries. These are local observations of retained source records, not external availability guarantees or a Phase 09 service contract.

## Explicit export

```bash
hostwright metrics export \
  --state-db /absolute/private/state.sqlite \
  --output-path /absolute/private/new-metrics.json \
  --confirm-snapshot <snapshotSHA256> \
  --output json
```

Export recomputes the current snapshot and refuses a stale confirmation. The parent must already be a canonical current-user private directory without access-granting ACLs. Hostwright creates exactly one new mode-`0600`, single-link regular file through a parent-directory descriptor with exclusive/no-follow flags, verifies its bytes and path identity, and never overwrites. Cancellation or write/identity failure removes only the exact newly created incomplete file. A successful export is operator-owned and is never uploaded or silently deleted by daemon, distribution, or retention cleanup.

## Retention and failure handling

Metrics have no separate sample store. Counters, histograms, and summaries reflect retained authoritative events, operations, health, restart, maintenance, cleanup, storage, network, and ownership rows; gauges reflect current rows. `hostwright state retention` therefore reports the metrics producer available with zero separate metric-file records. Confirmed compaction changes future projections only by deleting source rows under their existing class rules and verified backup boundary.

If snapshot validation, SQLite compatibility, cardinality, export confirmation, private-path, cancellation, or byte verification fails, preserve the reported state and inspect it with `hostwright state integrity`. Do not delete the database, WAL sidecars, or a changed output path. No fallback collector, raw-row export, unbounded label, network exporter, or fabricated success is used.
