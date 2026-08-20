# Phase 11 Cluster Contracts

Status: dependency-safe contract slice for P11-C01 (#220) and the contract
portion of P11-C03 (#222). This document does not claim live etcd, VM, Apple
Container, multi-host, or release qualification.

The implementation is isolated in the `HostwrightCluster` target:

- [`ClusterMembership.swift`](../../Sources/HostwrightCluster/ClusterMembership.swift)
  owns cluster identity, membership intent, join tokens, plans, transition
  records, recovery records, deterministic hashes, and quorum-safe planning.
- [`ManagedEtcdArtifact.swift`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift)
  owns the pinned artifact descriptor, archive acceptance boundary, private
  layout, process configuration, snapshot/restore plans, and exact cleanup
  ownership.

## Membership contract

`ClusterID` and `ClusterNodeID` are lowercase canonical UUIDs. Membership
epochs are monotonic `UInt64` values and fail closed on overflow. A membership
intent is canonicalized by node identity, token IDs, and applied plan IDs; a
non-empty intent must contain at least one voter. Peer and client endpoints
must be explicit HTTPS URLs with ports and no credentials, query, or fragment.

The planner supports bootstrap, learner join, learner promotion, voter
removal, and voter replacement. Each plan has a deterministic plan digest,
ordered epoch transitions, and a recovery record whose digest binds the full
transition sequence. Replay of the exact resulting intent is idempotent;
stale epochs, duplicate token use, duplicate identity, invalid topology, and
conflicting replays are rejected.

Voter removal preserves the current quorum and refuses a change that would
leave no voter or fewer surviving voters than the current quorum. Replacement
is planned as learner join, learner promotion, then old-voter removal so the
old voter remains present until the replacement is a voter.

## Managed etcd contract

The descriptor is pinned to etcd `v3.7.1` and the exact official release
metadata:

| Platform | Archive | SHA-256 pin |
| --- | --- | --- |
| Darwin arm64 | `etcd-v3.7.1-darwin-arm64.zip` | `a3e839d9128e170c299b1592bed92d8327f258eb94923aea24a0ccf923cf27e9` |
| Linux arm64 | `etcd-v3.7.1-linux-arm64.tar.gz` | `d7e25e08f694b6ed7792fc7b7a891fe2c3f3d3dccfe2f3bfdb1547b0eb75b6da` |

The delegated Linux value was 66 hexadecimal characters and therefore could
not be a SHA-256 digest. The published etcd release
[`SHA256SUMS`](https://github.com/etcd-io/etcd/releases/download/v3.7.1/SHA256SUMS)
records the 64-character value above. The catalog now accepts only that
authoritative digest; an archive matching the malformed delegated value is
rejected.

For a valid descriptor, archive acceptance is bounded and ordered:

1. Require a current-user-owned, regular, non-group/world-writable archive of
   bounded size.
2. Stream the archive SHA-256 and compare it to the descriptor.
3. Inspect ZIP or tar.gz metadata without extraction.
4. Reject absolute/traversal/backslash/NUL paths, duplicate canonical paths,
   links, special files, unsafe modes, and archives without the exact root and
   `etcd` executable.
5. Emit a provenance record bound to the descriptor, source URL, verifier
   version, and validated entry paths.

The private layout is rooted at the caller-provided absolute directory:

```text
<root>/versions/<version>/<platform>/etcd
<root>/data/<cluster-id>/<node-id>/
<root>/config/<cluster-id>/<node-id>/
<root>/snapshots/<cluster-id>/<node-id>/
<root>/metadata/<cluster-id>/<node-id>/provenance.json
<root>/run/<cluster-id>/<node-id>/
```

Directories are mode `0700`; generated configuration files are planned for
mode `0600`; the supervised process receives a minimal trusted environment and
no join-token or secret material. Snapshot restore requires the quorum to be
stopped. Cleanup accepts only the exact install, data, config, snapshot,
metadata, and runtime directories owned by this layout; the root and shared
parents are never cleanup targets.

The runtime slice adds bounded execution around those contracts. Installation
re-copies and re-verifies the accepted archive into an owned `run` staging
directory, extracts with an exact executable and argument vector, normalizes
the extracted tree to private modes, and atomically publishes only into an
empty version directory. Stale `install-stage-*` directories are recovered
only when they are private and owned by the current user; an existing
installation or provenance record is never overwritten.

Member supervision preflights the installed executable and working directory,
launches with the canonical arguments and minimal environment, discards child
stdio, and exposes explicit `starting`, `running`, `healthy`, `unhealthy`,
`stopping`, `failed`, and `stopped` transitions. Health is accepted only for a
credential-free HTTPS endpoint returning HTTP 200 with the exact etcd health
payload. Snapshot creation and restore copy only private regular-file trees,
record canonical provenance, require a stopped member, publish through owned
staging paths, and roll back partial publication on cancellation or failure.
The focused tests use a non-etcd pause fixture only to exercise process
supervision failure transitions; they do not qualify a real etcd member.

## Deliberate boundary

This target does not implement scheduler placement, authoritative replicated
state, fencing, node agents, remote operations, shared schema migrations, or
capability promotion. Live etcd qualification and VM fault testing remain
blocked until the Phase 08 runtime coordinator explicitly releases the
reserved runtime. No etcd archive was downloaded or launched while the
runtime remains reserved.
