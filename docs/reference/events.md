# Durable Events and Local Watches

The schema-v17 SQLite `event_ledger` is Hostwright's durable local event authority. Phase 08 Gate 12 adds a schema-v1 read projection and cursor contract without changing the database schema, event rows, provider APIs, or Control API. Existing `hostwright events` snapshot reads remain timestamp-sorted and read-only; their default page is 100 records and the maximum explicit `--limit` is 1,000.

## Cursor pages

Use `--cursor beginning` to read retained events in durable SQLite append order:

```bash
hostwright events --cursor beginning --limit 100 --output json
```

The response includes `schemaVersion`, `cursorSchemaVersion`, `mode`, `status`, `moreAvailable`, `nextCursor`, and bounded event records. Each streamed event has a database append `position`, an opaque cursor, a SHA-256 `eventReference` over the complete stored redacted record, one fixed event class, up to four validated operation references found in the redacted payload, and an audit reference when the event belongs to a protected audit class. Event classes cover desired changes, plans, actions, health, policy, recovery, garbage collection, provider state, operator decisions, and general state.

Resume with the exact returned cursor:

```bash
hostwright events --cursor '<returned-cursor>' --limit 100 --output json
```

A cursor binds schema version 1, the exact safe event identifier, and the event's SHA-256. Hostwright resolves the retained event's current SQLite append identity on every read, so a cursor remains usable after authoritative `VACUUM`. If the anchor still exists but its content changed, `HW-EVENT-002` fails closed. If retention removed the anchor, the command returns status `retention-gap`, identifies the earliest and latest retained cursors, and returns the earliest bounded retained page. Clients must record the gap before continuing from `nextCursor`; Hostwright never pretends missing history was delivered.

`beginning` is the only non-opaque cursor sentinel. Invalid, noncanonical, oversized, or unsafe cursor/filter input fails with `HW-EVENT-001` or `HW-EVENT-003`. Cursors contain only validated event identity and digests, never event messages, payloads, paths, credentials, or secrets.

## Watches

`--watch` is a bounded local long poll, not a server or filesystem-event edge:

```bash
hostwright events --watch --timeout 30 --limit 100 --output json
hostwright events --cursor '<returned-cursor>' --watch --timeout 30 --output json
```

Without a cursor, watch first anchors at the latest committed event and waits only for later matching events. With a cursor, it resumes after that exact event. One invocation returns at most one page and exits when it has events, detects a retention gap, reaches the 1-to-300-second timeout, or is cancelled. Synchronous bounded output supplies backpressure: Hostwright does not queue an unbounded stream while a consumer is slow. A timeout is a successful read with status `timeout`; cancellation is `HW-EVENT-004` and leaves no state, file, socket, process, or runtime artifact.

Project, event type, service, and severity filters apply inside the bounded database query. The cursor advances across nonmatching committed rows so repeated filtered watches do not rescan or duplicate them. Event primary-key uniqueness prevents the same external notification identity from producing two semantic rows, and cursor resume never returns an acknowledged row twice.

## Operations and recovery

Event reads never create, migrate, compact, repair, or otherwise mutate the state database. A missing or older database still requires the explicit state migration workflow. Existing v16 events become schema-v1 stream records after the one approved v16→v17 migration without a Gate 12 table or v18 migration. SQLite failures and cursor-integrity failures preserve the original database and return exact local errors.

For planned event retention and compaction, use `hostwright state retention` and confirmation-bound `hostwright state compact`. For operation checkpoint recovery, use `hostwright recovery`. OSLog remains a best-effort local mirror; it is not a replacement cursor or durable watch source. No network listener, persistent API, authentication, RBAC, remote watch, external export, or automatic upload is introduced.
