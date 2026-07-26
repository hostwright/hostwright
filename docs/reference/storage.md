# Storage

Hostwright manages persistent storage on one Mac through Storage Provider API v1 and schema-v15 state. The shipped provider ID is `hostwright-local`. It stores only Hostwright-owned data below:

```text
~/Library/Application Support/Hostwright/storage/providers/hostwright-local
```

The provider root, state records, project/resource UUIDs, generations, fencing tokens, and ownership proofs—not a volume name or host path—define authority.

## Manifest

Top-level `volumes` declare capacity, access, and reclaim behavior. A service attaches a declaration with a `volume` mount:

```yaml
version: 2
project: stateful-demo
imagePolicy: require-digest

volumes:
  data:
    provider: hostwright-local
    capacity: 2GiB
    accessMode: read-write-once
    reclaimPolicy: retain
    labels:
      com.example.purpose: database

services:
  database:
    image: example.invalid/database@sha256:<digest>
    volumes:
      - type: volume
        source: data
        target: /var/lib/database
```

Supported access modes are `read-write-once` and `read-only-many`. Supported reclaim policies are `retain`, `delete`, `snapshot-before-delete`, `backup-before-delete`, and `recycle`. `recycle` is accepted only when the provider can prove a safe implementation; the shipped provider otherwise refuses it before deletion.

Bind mounts remain descriptor-validated host paths. Host root, devices, traversal, symlink swaps, unsafe ownership or permissions, and provider mount drift fail before workload mutation. `tmpfs` is memory-backed and never presented as persistent storage.

## CLI

Read-only inspection:

```bash
hostwright volume list --output json
hostwright volume inspect <volume-uuid> --output json
hostwright volume capacity --output json
hostwright volume health --output json
```

Snapshots:

```bash
hostwright volume snapshot create <volume-uuid> \
  --snapshot-id <snapshot-uuid> --name daily
hostwright volume snapshot list <volume-uuid>
hostwright volume snapshot inspect <volume-uuid> <snapshot-uuid>
hostwright volume snapshot retain <volume-uuid> <snapshot-uuid> \
  --owner <owner-id>
hostwright volume snapshot export <volume-uuid> <snapshot-uuid> \
  --output /absolute/output-path
```

Snapshot restore and deletion are confirmation-bound:

```bash
hostwright volume snapshot restore <snapshot-uuid> \
  --source-volume <source-volume-uuid> \
  --to-volume <new-target-volume-uuid> \
  --reference-id <reference-uuid> --dry-run
hostwright volume snapshot restore <snapshot-uuid> \
  --source-volume <source-volume-uuid> \
  --to-volume <new-target-volume-uuid> \
  --reference-id <reference-uuid> --confirm-plan <sha256>
```

Backups use a typed secret reference for encryption key material; plaintext keys are rejected:

```bash
hostwright volume backup create \
  --volume <volume-uuid> \
  --backup-id <backup-uuid> \
  --name nightly \
  --key-ref keychain://hostwright/backup
hostwright volume backup verify <volume-uuid> <backup-uuid> \
  --key-ref keychain://hostwright/backup
hostwright volume backup restore <backup-uuid> \
  --key-ref keychain://hostwright/backup \
  --target <source-volume-uuid>=<new-target-volume-uuid> --dry-run
```

An S3-compatible remote target adds the same destination arguments to `backup create`, `verify`, `retain`, `restore`, and `delete`:

```bash
--remote-s3-endpoint https://s3.example.com \
--remote-s3-bucket hostwright-backups \
--remote-s3-region us-east-1 \
--remote-s3-prefix projects/example \
--remote-s3-access-key-ref keychain://hostwright/s3-access \
--remote-s3-secret-key-ref keychain://hostwright/s3-secret
```

The endpoint must be one HTTPS origin. Bucket, region, prefix, and both distinct Keychain references are validated as one destination; partial or changed destinations fail before remote I/O. The optional prefix is omitted by leaving out `--remote-s3-prefix`.

Destructive volume, snapshot, backup, and prune operations require exactly one `--dry-run` or exact `--confirm-plan <sha256>`. A changed observation, generation, fence, hold, policy, attachment, or ownership proof invalidates confirmation.

`retain` prevents automatic deletion during lifecycle removal. An operator may still explicitly delete that detached, unheld, exact managed volume through `volume delete` with the current confirmation hash; protective snapshot/backup policies continue to require their verified prerequisite.

## Snapshots, Backups, and Restore

A snapshot records one provider-consistent point and exact data/metadata hashes. Backup verifies every selected snapshot, encrypts content through the configured key reference, records exact file hashes and modes, and publishes the catalog only after verification. Cancellation, disk pressure, missing input, tamper, or the wrong key leaves no promoted partial backup.

Remote backup publishes one exact backup-scoped manifest and its encrypted chunks only after local verification. Verification and restore can hydrate missing local backup artifacts from that exact namespace, then apply the same checksum, encryption, ownership, and promotion gates as local backup. Credential values are resolved inside the provider from Keychain references and never enter arguments, state, logs, results, or diagnostics.

Deleting a backup removes only encrypted chunks no longer referenced by any remaining verified backup set. Unknown or malformed catalog entries fail cleanup closed instead of making an unreferenced-content assumption.

Restore always targets a new volume identity. Hostwright verifies the complete backup before promotion, rechecks target ownership and fencing, and preserves the prior authoritative target until the new target is proven. It refuses in-place overwrite, source/target aliasing, changed evidence, or ambiguous effects.

## Capacity and Pressure

Capacity reports separate requested, reserved, used, reclaimable, and available bytes and inodes. Provider quotas are advertised only when enforced. Admission predicts the post-operation state and rejects unsafe create, expansion, or writable attachment before mutation.

Pressure planning is deterministic and bounded. It protects active attachments, durable operations, holds, retained resources, unverified protection artifacts, unknown ownership, and unmanaged data. Pressure may stop unsafe growth or propose exact owned reclaim candidates; it never authorizes global or name-based deletion.

## Reclaim and Orphan Recovery

`retain` is the default. Delete-class policies execute only after dependencies are detached and exact ownership, provider generation, resource generation, fencing, policy, and confirmation still match. `snapshot-before-delete` and `backup-before-delete` additionally require a fresh verified protection artifact.

Orphan discovery compares schema-v15 authority, active durable operations, provider observation, ownership labels, holds, attachments, and tracked history. It classifies missing, leaked, modified, unknown, ambiguous, and unmanaged resources. Ambiguous or changed resources enter a safe hold; only aged, exact Hostwright-owned candidates enter a reclaim plan.

Use:

```bash
hostwright volume prune --dry-run --output json
hostwright volume prune --confirm-plan <sha256> --output json
hostwright volume recover <volume-uuid> \
  --idempotency-key <recorded-operation-key> --output json
```

Recovery resumes only the persisted operation, authority, plan, and provider journal. After timeout, cancellation, crash, or process termination, Hostwright observes the exact resource before deciding whether to retry, finish, or hold. It does not infer success from process output.

## Control API and Provider Boundary

The one-shot Control API v2 exposes the same non-interactive `volume` operations and validation as the CLI. It does not add a listener or alternate mutation path.

`hostwright-storage-helper` is the signed out-of-process boundary for provider requests. Frames are bounded and canonical; peer UID, process identity, executable signature, protocol version, capability digest, deadlines, request IDs, idempotency keys, and mutation context are verified. Revocation, replay, malformed frames, unsafe sockets, cancellation, crash, and helper replacement fail closed.

Remote/shared volumes, network storage systems, multi-Mac attachment authority, Kubernetes CSI adapters, and unmanaged/global garbage collection are not Phase 06 capabilities.
