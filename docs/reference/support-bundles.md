# Privacy-Safe Support Bundles

Phase 08 Gate 15 adds a schema-v1, local-only support-bundle workflow under `hostwright diagnostics support`. It preserves the earlier `hostwright diagnostics --bundle <path>` diagnostics-v1 export. Support bundles add preview and confirmation, optional macOS CMS encryption, durable file-effect recovery, retained ownership evidence, and receipt-proven exact deletion. They add no listener, uploader, hosted support service, credential-store reader, schema v18 migration, or Phase 09 API.

## Preview and create

Use an existing compatible schema-v17 state database and, when configuration shape is useful, the exact Manifest-v2 file:

```bash
hostwright diagnostics support preview \
  --state-db /absolute/private/state.sqlite \
  --manifest /absolute/private/hostwright.yaml \
  --output json

hostwright diagnostics support create \
  --state-db /absolute/private/state.sqlite \
  --manifest /absolute/private/hostwright.yaml \
  --output-path /absolute/private/new-support-v1.json \
  --confirm-preview <previewSHA256> \
  --output json
```

Preview is non-mutating and reports the fixed section inventory, availability, retained and dropped record counts, encoded byte counts, estimated total bytes, deterministic bundle ID, and confirmation SHA-256. The informational generation time is outside the confirmation identity. Support-command OSLog records are excluded from their own snapshot so an otherwise unchanged preview can be confirmed; any other selected evidence change invalidates the confirmation and requires a fresh preview.

Create recomputes the complete preview before any file or journal effect. It refuses a stale hash, cancellation, an absent or unsafe parent, and any existing output. A successful plaintext bundle is one canonical JSON file with exact mode `0600`, one link, invoking-user ownership, synchronized bytes and parent, a verified output hash, and an operator-owned receipt. Hostwright never uploads it or schedules it for automatic deletion.

## Fixed bounded content

The bundle contains only these schema-v1 sections, in order:

1. product, contract, operating-system, architecture, and Swift version inventory;
2. the existing capability report;
3. Manifest shape counts and policy-presence booleans;
4. non-mutating state-integrity result, database hash, byte count, and fixed check statuses;
5. recent `dev.hostwright` OSLog records after validation and construction-time redaction;
6. recent durable events without messages or payloads;
7. the fixed-label local metrics/SLO snapshot;
8. bounded local traces;
9. operation status records without payloads, idempotency keys, project IDs, or service names;
10. audit and support-evidence identities without messages or payloads.

Event, evidence, and operation row identifiers outside the trace graph are one-way domain-separated hashes. Trace, span, correlation, and linked event or operation identities remain canonical bounded UUIDs so the selected trace can be reconstructed; they contain no names or paths. Manifest project/service names, images, commands, environment, mount paths, port values, probe details, raw desired or observed state, event messages/payloads, operation payloads, OSLog process paths, and database rows are not copied. Keychain items, Docker/OCI credential files, environment-secret values, private keys, tokens, and raw credential stores are never read for bundle collection.

The fixed record caps are 200 logs, 200 events, 20 traces, 200 operations, and 200 evidence records. Each section and the combined encoded section payload must remain within 3 MiB; plaintext is capped at 4 MiB and encrypted output at 8 MiB. Oversized or malformed input is dropped with a count or fails before output creation. Truncation never turns a secret-like field into an accepted value.

## Optional platform encryption

To encrypt before anything reaches disk, provide a non-secret Keychain certificate reference:

```bash
hostwright diagnostics support create \
  --state-db /absolute/private/state.sqlite \
  --output-path /absolute/private/new-support-v1.cms \
  --confirm-preview <previewSHA256> \
  --encrypt-recipient support-recipient@example.test \
  --output json
```

Hostwright passes plaintext on standard input to the fixed `/usr/bin/security cms -E` boundary and captures bounded CMS DER on standard output. Plaintext is never placed in an intermediate file, the recipient reference is never persisted, and durable evidence contains only its SHA-256. Missing, ambiguous, or invalid recipient certificates fail without a bundle. Hostwright does not generate, import, export, or delete certificates.

## Status, recovery, and exact deletion

```bash
hostwright diagnostics support status --state-db /absolute/private/state.sqlite --output json
hostwright diagnostics support recover --state-db /absolute/private/state.sqlite --output json

hostwright diagnostics support delete \
  --state-db /absolute/private/state.sqlite \
  --bundle /absolute/private/new-support-v1.json \
  --confirm-bundle <outputSHA256> \
  --output json
```

Create and delete persist a private canonical journal beside the selected state-maintenance journal before the external file effect. The journal binds operation, bundle, preview, hashed path, encryption choice, and—after creation—the exact device, inode, byte count, and content hash. Recovery finalizes a proven completed effect, records a proven no-effect outcome, or enters a safe hold. It never guesses whether a changed file is the original.

Deletion requires a retained Hostwright creation receipt for the exact path hash and output hash. Immediately before unlink, Hostwright reopens through a pinned private parent and revalidates type, owner, mode, ACL policy, single-link count, device, inode, size, and hash. A symlink, hard link, overwrite, replacement, missing receipt, stale confirmation, or identity drift is preserved and refused. Successful deletion verifies absence and records a durable deletion receipt. It does not remove the parent, state database, distribution payload, daemon files, or any other bundle.

If `status` reports pending recovery, stop creating or deleting bundles and run `recover` with the same state database. If recovery reports `HW-SUPPORT-012`, preserve both the reported file and the private journal; inspect ownership and identity instead of renaming, overwriting, or deleting either one. State backup/restore does not authorize deletion of an operator-owned bundle.

## Retention and failures

Creation, deletion, and no-effect failure receipts use the `supportEvidence` Manifest-v2 retention class in the existing event ledger. They contain hashes, sizes, reason codes, and operation/bundle identities—not the output path or bundle content. Ordinary `events`, `audits`, and `traces` retention remain disjoint. Confirmed compaction may remove only eligible expired receipts after the normal recovery horizon, hold, verified-backup, and exact-candidate checks. It never deletes the external operator-owned bundle.

Stable errors are `HW-SUPPORT-001` through `HW-SUPPORT-013`: invalid contract, changed preview, unsafe output path, section or total size limit, invalid recipient, encryption unavailable or failed, unavailable ownership receipt, changed bundle identity, required recovery, recovery safe hold, and cancellation. JSON errors carry the exact code and normal bounded CLI exit classification without exposing the output path.

The workflow requires a current schema-v17 database. Schema v16 must be upgraded by an existing state-writing workflow; support reads do not migrate it. Future schemas and old-binary downgrade attempts fail closed. The bundle is troubleshooting evidence for the recorded local host only. It is not an attestation, audit-chain export, support SLA, remote telemetry stream, or proof of Phase 08 aggregate soak completion.
