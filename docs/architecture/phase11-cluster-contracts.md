# Phase 11 Cluster Contracts

Status: dependency-safe contract slices for P11-C01 (#220), cluster CA and
mTLS peer trust P11-C02 (#221), the contract portion of P11-C03 (#222),
authenticated node agents P11-C05 (#224), and cluster fencing P11-C07 (#226),
plus an opt-in qualification of the pinned Darwin artifact's private install
and cleanup path. This document does not claim a live mTLS transport, live etcd
health, quorum/fault, VM, Apple Container, physical multi-host, or release
qualification.

The implementation is isolated in the `HostwrightCluster` target:

- [`ClusterMembership.swift`](../../Sources/HostwrightCluster/ClusterMembership.swift)
  owns cluster identity, membership intent, join tokens, plans, transition
  records, recovery records, deterministic hashes, and quorum-safe planning.
- [`ClusterCertificateTrust.swift`](../../Sources/HostwrightCluster/ClusterCertificateTrust.swift)
  owns public cluster-CA trust bundles, exact peer identity and certificate
  validation, bounded rotation overlap, revocation, and the authenticated
  node-client bridge into the cluster-session contract.
- [`ClusterCertificateLifecycle.swift`](../../Sources/HostwrightCluster/ClusterCertificateLifecycle.swift)
  owns non-exportable macOS Keychain CA/leaf credentials, private public-only
  metadata, sequential generation rotation, and crash recovery.
- [`ClusterNodeAgentTransportSecurity.swift`](../../Sources/HostwrightCluster/ClusterNodeAgentTransportSecurity.swift)
  owns the source-only client/server adapter from lifecycle identities and
  certificate trust into authenticated cluster sessions and handoffs.
- [`ManagedEtcdArtifact.swift`](../../Sources/HostwrightCluster/ManagedEtcdArtifact.swift)
  owns the pinned artifact descriptor, archive acceptance boundary, private
  layout, process configuration, snapshot/restore plans, and exact cleanup
  ownership.
- [`ClusterSession.swift`](../../Sources/HostwrightCluster/ClusterSession.swift)
  owns the authenticated node-session challenge/proof contract, session
  binding, lifecycle, revocation, membership-epoch fencing, and strict wire
  decoding helpers, including the credential-free consumer handoff that Phase
  12 can adapt to its guest-agent boundary.
- [`NodeAgentTransport.swift`](../../Sources/HostwrightCluster/NodeAgentTransport.swift)
  owns the bounded authenticated local subprocess/socket producer, strict
  request/response framing, and cancellation/peer-identity boundary.

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

## Cluster certificate trust contract

`ClusterCertificateAuthority` accepts only a bounded DER-encoded, self-signed
P-256 root with the exact Hostwright CA URI, critical CA and key-signing
constraints, no extended-key usage, and a single cluster/generation binding.
`ClusterCertificateTrustBundle` contains public certificates and fingerprint
revocations only. It permits one current authority or one sequential
old/current overlap; a second concurrent rotation, nonsequential generation,
cross-cluster authority, duplicate authority, malformed fingerprint, or
attempt to revoke a trust anchor fails closed.

Peer identities use one canonical URI that binds cluster UUID, node UUID,
role, and certificate generation. `ClusterMutualTLSVerifier` requires the
exact URI as the sole SAN, P-256/ecdsa-with-SHA-256, a non-CA leaf, digital
signature key usage, the role's exact client/server EKU set, explicit validity,
an unrevoked fingerprint, and a two-certificate path to the generation's
pinned authority with network fetching disabled. Only a verified
`node-agent-client` peer can derive a deterministic, non-secret
`ClusterSessionCredential`; the resulting public key is exercised through the
existing challenge/proof authority in tests.

`ClusterCertificateLifecycle` is the production credential owner behind this
public trust contract. It generates a permanent, non-extractable P-256 CA key
and one permanent, non-extractable leaf key for each requested role in macOS
Keychain. Every item has an exact cluster/node/generation/role tag and an
operation-bound ownership label; resolution uses the persisted opaque item
references and exact ownership attributes rather than an ambient identity
search. Issued certificates use the
same sole URI SAN and exact CA, key-usage, and role-specific EKU constraints
that `ClusterMutualTLSVerifier` enforces. The lifecycle returns `SecIdentity`
handles and the public certificate chain, never private-key bytes.

Only public DER, fingerprints, canonical identities, and bounded opaque
Keychain persistent references are stored outside Keychain. The containing
directory is current-user-owned mode `0700`; canonical metadata and journal
files are mode `0600`, digest-bound, size-bounded, opened without following
symlinks, fsynced, and atomically renamed under a cross-process file lock.
Malformed encoding, altered digests, unsafe ownership or permissions, item
collisions, mismatched public keys, and missing or changed persistent-reference
targets fail closed.

Bootstrap and rotation first persist a `creating` journal, generate and verify
all exact-scoped Keychain items, persist an `activating` journal with their
public evidence, then atomically publish metadata. Restart recovery compensates
an incomplete create only when the items carry that journal operation's exact
ownership ID; a later foreign scope collision fails closed without deletion.
Recovery otherwise idempotently finishes activation. Structural ownership and
certificate-chain validation is separate from current-time credential use, so
an expired generation can still be rotated or retired while identity use stays
fail-closed. Rotation permits one
sequential current/retiring overlap; retirement journals the complete retiring
evidence, exact-deletes only those certificate/key pairs, publishes the
single-generation metadata, and replays safely if a crash occurred after
either delete or publish. Locked-Keychain and denied noninteractive access do
not fall back to an untrusted credential source.

Certificate-derived session credentials are admitted only after lifecycle
recovery has validated the digest-bound metadata against its exact
noninteractive Keychain certificate/key pairs under the cross-process lock.
Admission also checks the bound leaf and authority validity interval at the
session operation's explicit millisecond timestamp. Both exact generations
remain valid during the published overlap. Once retirement
publishes single-generation metadata, every later challenge, authentication,
session validation, and handoff authorization fences the retired generation;
the current generation remains valid only while its certificate is valid.
Missing, expired, noncanonical, tampered, stale metadata-only, or unrecoverable
transition state fails closed instead of treating a caller-supplied credential
catalog as generation authority. This decision is durable across lifecycle
restart even though live session records themselves remain source-only and
in-memory in this slice.

The focused lifecycle tests create an isolated temporary Keychain and private
temporary metadata directory; they neither select nor enumerate the user's
login Keychain and delete the isolated Keychain after each case. This slice
still does not open a network listener or claim a live TLS handshake. Reciprocal
network transport and live authenticated qualification remain P11-C05 work.

## Node-agent transport security adapter

`ClusterNodeAgentTransportSecurityAdapter` prepares one immutable transport
security configuration without opening a listener or connection. Its client
side requires the active `node-agent-client` lifecycle identity and the exact
expected server node and generation; its server side requires the active
`node-agent-server` identity and the exact expected client node and generation.
The adapter matches the `SecIdentity` leaf and one-authority public chain to the
lifecycle evidence, exposes only the opaque identity handle and public chain,
and revalidates the local certificate at construction and before every peer
authentication. Retiring local credentials cannot prepare a new adapter.

Peer authentication delegates to `ClusterMutualTLSVerifier`, so the cluster,
node, role, generation, validity, revocation, key usage, and pinned two-item
chain remain one fail-closed policy. A specifically expected retiring peer can
finish during the bounded authority overlap, but an absent generation fails
before authentication and must not be inferred from certificate input. The
server result derives the exact public `ClusterSessionCredential`; its handoff
helper first binds cluster, node, and subject to that authenticated certificate
and then invokes `ClusterSessionHandoffAuthorizing` for the complete live
session, expiry, revocation, epoch, and fencing checks.

The adapter holds a trust-bundle snapshot. Rotation, retirement, or revocation
publishes a new snapshot and requires a replacement adapter before accepting
new peer authentication. Focused tests use real ephemeral certificates and
non-exportable keys in isolated temporary Keychains. This contract prepares the
security callbacks a later transport may consume; it does not claim a Network
framework integration, TLS handshake, network socket, listener, or physical
multi-host qualification.

## Authenticated cluster-session contract

`ClusterSessionCredential` binds one bounded credential identifier and subject
identifier to one `ClusterNodeID` and an exact P-256 X9.63 public key.
`ClusterSessionCredentialCatalog` is the non-secret credential authority input;
duplicate credential identities and invalid public-key material fail before a
session authority is created. Private keys are never accepted by the contract.

`ClusterSessionAuthority` issues a canonical, sorted-key
`hostwright-cluster-session-v1` challenge. The challenge binds the cluster ID,
node ID, current membership epoch, subject, credential ID, a 32-byte random
nonce, and bounded issue/expiry timestamps. The client returns a canonical DER
P-256 signature over the complete challenge. `ClusterSessionWireContract`
reuses the Phase 09 strict decoder boundary so unknown, missing, noncanonical,
or malformed handshake fields fail before authentication state changes.

Authentication accepts only a challenge issued by the same authority, in the
current membership epoch and validity window, with the catalog's exact public
key. A challenge is consumed before signature verification, so a rejected
proof cannot be retried. Successful authentication creates a binding carrying
the cluster/node identity, subject, credential, membership epoch, session
expiry, and a monotonic fencing token. Only one active session per subject is
allowed: a new authentication fences the prior session. Credential revocation
and membership-epoch advancement fence every affected session immediately.

The lifecycle is explicit and deterministic: `active` sessions validate only
when their complete binding and current fencing token match; `close` and
`fence` are idempotent for already terminal records; expiry, closure, fencing,
stale epochs, replayed challenges, identity mismatch, and proof failures each
have stable typed errors.

`ClusterSessionAuthority.bootstrapConsumer(from:subjectID:nowMilliseconds:)`
creates a canonical `hostwright-cluster-session-handoff-v1`
`ClusterSessionHandoff` only after that same source session authorizes. The
handoff contains only its session ID, cluster/node identity, membership epoch,
subject, fencing token, and issue/expiry timestamps. It deliberately omits the
credential ID, challenge ID, nonce, public-key material, and proof/signature.
`ClusterSessionHandoffAuthorizing.authorize(_:subjectID:nowMilliseconds:)`
is the exact Phase 12 consumption seam: the guest-agent authentication boundary
retains only the handoff and calls this authority method immediately before
dispatch. The authority compares the complete handoff to its session record and
then rechecks active state, expiry, credential revocation, membership epoch,
and the monotonic fence, so altered, stale, expired, revoked, or malformed
handoffs fail closed. The handoff is neither a credential nor a transport
protocol and carries no persistence semantics.
Credentials derived from verified node-agent certificates additionally require
the lifecycle-backed generation authority. Their exact certificate and
authority fingerprints, cluster/node/generation identity, canonical subject,
node identity, and public key must still match a recovered, Keychain-backed
current or overlapping lifecycle generation at the explicit authorization
time. Retirement or certificate expiry therefore fences already-issued
handoffs at the next authorization boundary rather than allowing them to
survive until ordinary session expiry.

`ClusterNodeAgentLocalTransport` is the bounded P11-C05 producer for a local
node-agent subprocess. It requires a concrete `ClusterSessionAuthority`,
creates the handoff through `bootstrapConsumer`, reauthorizes it through
`ClusterSessionHandoffAuthorizing` immediately before launch, and sends only a
strict request over a private length-prefixed Unix `SOCK_STREAM`. The launched
executable is validated with the secure subprocess boundary, receives a
minimal environment, and gets the socket path only as a launch argument; the
handoff itself is sent in the socket frame. The socket is checked for current
user ownership, socket type, and absence of group/world write permission.
Process and socket I/O run on a utility queue with bounded deadlines and
cancellation that terminates the owned subprocess. There is no network,
persistence, CA/mTLS, or multi-host behavior in this slice.

`ClusterNodeAgentLocalTransport` is the bounded P11-C05 producer for a local
node-agent subprocess. It requires a concrete `ClusterSessionAuthority`,
creates the handoff through `bootstrapConsumer`, reauthorizes it through
`ClusterSessionHandoffAuthorizing` immediately before launch, and sends only a
strict request over a private length-prefixed Unix `SOCK_STREAM`. The launched
executable is validated with the secure subprocess boundary, receives a
minimal environment, and gets the socket path only as a launch argument; the
handoff itself is sent in the socket frame. The socket is checked for current
user ownership, socket type, and absence of group/world write permission.
Process and socket I/O run on a utility queue with bounded deadlines and
cancellation that terminates the owned subprocess. There is no network,
persistence, CA/mTLS, or multi-host behavior in this slice.

This source-only authority is the admission and fencing contract, not a claim
of durable replicated session storage, an mTLS network transport, or live
node-agent qualification. Durable session records and reciprocal network
transport remain P11-C05 work. The Phase 08 runtime lock is released, but
physical multi-host evidence and live authenticated member health remain
unclaimed.

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
state, consensus-backed cluster fencing, remote operations, shared schema
migrations, or capability promotion. Its node-agent transport is intentionally
limited to the authenticated local subprocess/socket producer described above;
the later consumer, remote transport, and replicated-state work must consume
the handoff authority seam. The opt-in
`ManagedEtcdArtifactTests/testOfficialDarwinArchiveCanBeVerifiedInstalledAndCleanedWhenExplicitlyProvided`
qualification accepts only the pinned official Darwin archive, executes the
installed binary's version check, validates canonical provenance, and removes
only exact owned paths. Live authenticated health, quorum/fault behavior, VM
qualification, and physical multi-host evidence remain blocked by the missing
mTLS transport integration and lab prerequisites; the Phase 08 runtime release
does not claim those cells.
