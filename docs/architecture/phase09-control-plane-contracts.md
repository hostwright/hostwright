# Phase 09 Control Plane Contracts

Status: Gate 1 contract freeze. This document fixes the Phase 09 public and
security boundaries; it is not evidence that the later implementation gates
have shipped. The executable contract types and fixtures are in
[`contracts/v0.0.2`](../../contracts/v0.0.2/README.md).

Phase 09 replaces neither the existing Manifest v2 contract nor the current
one-shot adapter described in
[`control-surface-api-boundary.md`](control-surface-api-boundary.md). It adds
one persistent, authenticated, per-user Unix-socket control plane and routes
daemon-ready CLI work through its shared request pipeline when the relevant
gates are complete.

## Control API v2

`apiVersion` remains `2`. A request without `protocolRevision` is the locked
2.0 plan-only request (`control-plan-request.json`) and must retain its 2.0
response fixture (`control-plan-response.json`). Revision 2.1 is capability
negotiated; a client requesting an unavailable operation fails explicitly.

Revision 2.1 uses canonical JSON framed by one unsigned, big-endian 32-bit
length prefix. A server rejects an over-limit declaration before allocating:

| Item | Fixed limit |
| --- | ---: |
| Transport | Unix `SOCK_STREAM` only |
| Request | 64 KiB |
| Response or stream frame | 1 MiB |
| Unary requests in flight per client | 64 |
| Streams per client | 32 |
| Unary deadline | five minutes |

Requests contain `apiVersion`, `protocolRevision`, `requestID`, `operation`,
`timeoutMilliseconds`, optional `idempotencyKey`, and typed `body`.
Responses repeat the versions and request ID and contain `status`, stable
`reasonCode`, optional `operationRef`, typed `result`, and only sanitized error
metadata. The frozen reason-code vocabulary covers invalid framing/request,
version or operation refusal, deadline/cancellation, identity/authorization/
admission denial, conflict/idempotency/concurrency/stream limits, slow clients
and cursor gaps, audit unavailability, service unavailability, and internal
failure.

Streams use `streamID`, monotonically increasing `sequence`, optional opaque
`cursor`, `kind`, optional `credit`, and typed payload. The only frame kinds
are `open`, `data`, `heartbeat`, `gap`, `ack`, `cancel`, `end`, and `error`.
Client-to-server stream traffic is limited to `open`, output-credit `ack`,
typed runtime-input `data`, per-stream input `end`, and `cancel`;
server-to-client traffic is limited to `open`, output `data`, `heartbeat`,
`gap`, input-credit `ack`, `end`, and `error`. Client and server sequence spaces are independent and each
begins at one. An open carries one of the frozen sources `logs`, `attach`,
`exec`, `events`, `metrics`, `traces`, `operation`, or `state`, an optional
target and canonical filter, a 1--60 second heartbeat interval, and 1--256
units of initial credit. One unit permits one data frame; control, heartbeat,
gap, and terminal frames do not consume credit. An acknowledgement grants
1--256 additional units and may bind the last delivered cursor. Credit may
never exceed 256, a connection may buffer at most 128 unread frames, and a
blocked write is evicted after five seconds.

Exec and attach opens additionally require a stable client `requestID` and
`idempotencyKey`. Their acceptance returns the durable `operationRef` and 16
units of reverse input credit. Client input is a strict canonical object for
bounded base64 stdin, a TTY resize with 1--1000 columns/rows, or an allowed
POSIX signal. Each input consumes one reverse credit and the server returns one
`ack` only after runtime control accepts it. Client `end` half-closes only that
stream's stdin. Read-only sources reject mutation identity. A retry before the
durable started transition may begin; a retry after an ambiguous start never
repeats the external effect and receives a terminal non-replayable gap.

Resume cursors use a Keychain-backed P-256 capability, expire within 24 hours,
and bind the authenticated subject, stream source, target digest, filter
digest, and underlying durable-source cursor. They do not bind a daemon
generation, so a re-authenticated client can resume after restart. Rotation or
revocation of the active cursor key immediately invalidates prior cursors.
Every resume is re-authorized before source delivery. A missing retention
anchor or a non-replayable snapshot discontinuity produces one terminal `gap`
with an earliest/latest re-anchor and requires a fresh open; the server never
continues silently after a gap. Metrics are global-only snapshot/change
streams and reject project filters. Trace, operation, and state watches are
distinct authorized projections of the durable event ledger. State watch
excludes audit, trace, policy, operator, and unrelated event classes.
Operation watch requires a canonical operation reference in the event payload;
an event identifier is never an operation reference. Provider capability failures such as
Apple-container attach or follow-without-resume are explicit terminal errors,
not emulated streams.

Runtime stream targets are Hostwright resource UUIDs, never ambient container
names or provider identifiers. Their filter supplies the manifest service name;
the daemon requires one matching ownership record and then repeats the existing
live inventory, provider generation, resource generation, project generation,
and fencing-token checks immediately before reading logs or executing. Finite
logs use a distinct content-digest plus next-byte-offset cursor per chunk;
exec is deliberately non-replayable and cancellation
terminates its owned process tree.

Long operations acknowledge with a durable operation reference and expose
progress through a stream. Mutating acceptance persists request identity,
idempotency key, authorization and admission decisions, operation reference,
and audit record before acknowledgement.

Every accepted connection completes one bounded authentication handshake before
normal request framing. The server sends a canonical, response-sized
`authentication-challenge` containing revision 2.1, the resolved subject, a
fresh nonce, daemon generation, pinned socket device/inode, the kernel peer
identity projection, native CDHash, and whether a credential proof is required.
The client has five seconds to return one request-sized
`authentication-response`. That response contains either both the declared
credential identifier and canonical DER P-256 signature in base64, or neither;
the challenge decides which form is valid. The signature covers the complete
canonical challenge. Unknown, duplicate, missing, mismatched, replayed, late,
or partially populated handshake fields close the unauthenticated connection
without entering the request pipeline. Kernel credentials and strict code
identity are collected before the challenge and remain authoritative.

The normal CLI is a client of this API. Local help/version rendering may remain
local. The Bootstrap API v2.1 is limited to `daemon install`, `daemon repair`,
and `daemon uninstall`; every daemon-ready read or mutation uses the persistent
socket. The complete frozen command classification is
[`phase09-cli-parity-inventory.json`](../../contracts/v0.0.2/phase09-cli-parity-inventory.json).
Gate 9 proves parity and removes direct runtime/state mutation bypasses; this
document does not claim that removal yet.

Developer ID bootstrap requires the exact Hostwright team and companion
identifier. Initial ad-hoc bootstrap is limited to the securely resolved default
companion adjacent to the live `hostwright` installer while identity state is
absent or empty. The companion validates the live parent identity, records the
installer as owner, and pins the companion's distinct native CDHash as a
non-owner bootstrap identity. Existing ad-hoc state never auto-accepts a changed
installer or companion hash. SwiftPM's deterministic ad-hoc identifier suffix is
restricted to exactly 40 lowercase hexadecimal characters and is never accepted
for a Developer ID build.

## Local identity and socket boundary

The default socket path is already resolved as
`~/Library/Application Support/Hostwright/run/control-v2.sock` by
[`HostwrightLocalPathResolver`](../../Sources/HostwrightCore/LocalPaths.swift).
The future listener must require a current-user-owned mode-`0700` parent and a
mode-`0600` socket, reject symbolic links, non-sockets, and special modes, and
pin the resolved device/inode for its lifetime. It never creates a TCP or
public listener.

For every accepted connection, the daemon cross-checks `getpeereid`,
`LOCAL_PEERPID`, and `LOCAL_PEERTOKEN`, binds the identity to the audit-token
EUID/GID/PID/PID-version, connection, daemon generation, socket device/inode,
and a server nonce, then creates the Security task with
`SecTaskCreateWithAuditToken`. Strict `SecCode` validation accepts only an
installed Hostwright team/identifier requirement or an explicitly recorded
ad-hoc CDHash produced by the secure bootstrap path. `codeDirectoryHash`
preserves the lowercase hexadecimal bytes returned by
`kSecCodeInfoUnique`: 40 characters for a 20-byte Code Directory hash or 64
characters for a 32-byte hash. It is never replaced by a derived digest of
those bytes. An optional Hostwright
P-256 client credential can refine a subject; it never replaces kernel peer
credentials or code identity. Revocation terminates active sessions
immediately.

Existing helper boundaries provide implementation anchors, not equivalent
Phase 09 completion: the storage and network helpers already obtain
`getpeereid`/`LOCAL_PEERPID` and validate `SecCode` team/identifier
requirements. Gate 2 adds the control-plane audit-token and peer-token checks
and the persisted session/revocation model.

## Authorization and admission

RBAC resources are exactly `project`, `service`, `image`, `volume`,
`registry`, `secret-metadata`, `runtime`, `state`, `daemon`, `observability`,
`audit`, `policy`, `profile`, `plugin`, and `provider`. Verbs are exactly
`get`, `list`, `watch`, `plan`, `create`, `update`, `delete`, `start`, `stop`,
`restart`, `execute`, `approve`, `delegate`, and `admin`.

Scopes are global, project UUID, or resource UUID. Conditions are an AND-only
set of project/resource, operation, profile hash, and expiry constraints; no
arbitrary expression language is permitted. Deny overrides allow. Delegation
may grant only a subset of the delegator's effective permissions, must expire,
cannot delegate owner, and cannot override a deny. The default roles are
`viewer`, `operator`, `maintainer`, `security-admin`, and `owner`; bootstrap
grants owner only to the installing declared subject and must preserve at least
one owner. The precise default matrix is
[`phase09-default-role-matrix.json`](../../contracts/v0.0.2/phase09-default-role-matrix.json).

For every mutation, the pipeline order is fixed:

1. Authenticate.
2. Authorize requested intent.
3. Canonicalize.
4. Apply built-in mutation.
5. Apply extension mutation in identifier/version order.
6. Detect conflicting writes to a canonical field.
7. Run built-in validation.
8. Run extension validation.
9. Authorize effective mutated intent.
10. Bind approval.
11. Persist request, operation, and audit data.
12. Acknowledge.

Conflicting canonical-field writes deny. Security-sensitive policy always fails
closed. Only an explicitly declared, audited, non-mutating advisory policy may
be ignored; omission means deny. Exceptions are versioned, auditable records
bound to policy, subject, target, plan hash, approval identity, and expiry.
The frozen request/decision example is
[`phase09-admission-v2.1.json`](../../contracts/v0.0.2/phase09-admission-v2.1.json).

Gate 6 implements this order in the persistent daemon request pipeline. Stored
policy documents use a bounded declarative schema with exact operation names,
AND-only `exists`/`equals` conditions, object-field mutations, and
`required`/`forbidden`/`equals` validation. There is no embedded expression
language. Policy documents and decisions are canonical-digest bound; malformed
documents fail closed except for the frozen advisory, non-mutating extension
case. Mutation policies cannot rewrite `planHash`, `approvalIdentity`, or
`dryRun`. The daemon audits admission, reauthorizes the effective request, and
binds both original and effective requests plus the evaluation digest into
idempotency state before invoking a mutation handler. A dry run returns the
effective request, decisions, target, plan hash, exception IDs, and evaluation
digest without persistence or effects.

Policy and exception administration is available only through strict
`admission.*` Control API operations and the `policy` RBAC resource. Exceptions
require `approve`, identify the approving actor exactly, have a future expiry,
and match one immutable policy ID, subject, derived target, and plan hash.

## Audit, profiles, and persistence

Audit records are canonical append-only SHA-256 chains, grouped into P-256
signed segments. Keys are in Keychain; public verification material and key
rotations are state data. Verification must expose removal, reordering, forks,
truncation, unauthorized key change, and clock anomalies. Retention removes
only a sealed prefix and appends a signed retention checkpoint. If audit append
fails, a security-sensitive mutation fails closed; read-only APIs remain
available with explicit degraded health. See
[`phase09-audit-v2.1.json`](../../contracts/v0.0.2/phase09-audit-v2.1.json).

Audit schema v1 seals every committed record as a one-record segment before a
mutation can be acknowledged. A record digest is SHA-256 over its sorted-key,
UTF-8 JSON preimage with an RFC 3339 fractional-seconds timestamp and without
`recordDigest`. A segment digest is SHA-256 over its sorted-key JSON preimage;
the Keychain P-256 key signs that 32-byte digest. Key identifiers are
`p256:<sha256-of-X9.63-public-key>`. The database stores only public keys,
signed key-transition metadata, DER signatures, and canonical preimages. The
private key, active-key pointer, and latest sealed segment head are
device-local Keychain items scoped to the canonical state-database path.

The external head makes tail truncation observable. A fully verified database
ahead of its external head is the sole automatically recoverable crash state;
a database behind or divergent from the head fails closed. Retention can
delete only a sealed prefix while retaining a signed checkpoint from the
genesis or prior retention anchor to the removed-through segment digest.
Verified backup manifests bind the audit head and active key, and an authorized
restore synchronizes those Keychain values before its maintenance journal is
removed. Export bundles are canonical and independently verifiable from their
public keys, transition signatures, record chains, segment signatures, and
retention checkpoints.

Workload Profile v1 covers filesystem, network, resources, identity, secrets,
images, runtime and syscall options, host access, observability, accelerators,
and extension grants. It permits one parent and rejects cycles. A child may
only tighten unless `profile:weaken` is authorized and explicitly approved.
The exact encoded shape is in
[`phase09-profile-v1.json`](../../contracts/v0.0.2/phase09-profile-v1.json).

Migration boundaries are fixed and each migration creates and verifies an
existing-style pre-migration backup. Old binaries seeing schemas 18–21 refuse
safely; rollback restores the corresponding backup rather than performing a
down-migration.

| Transition | Owned data group |
| --- | --- |
| 17 → 18 | peer identities, sessions, revocations, request/idempotency state |
| 18 → 19 | audit segments/records, key metadata, retention anchors |
| 19 → 20 | roles/bindings/delegations, policies/exceptions, workload profiles |
| 20 → 21 | plugin packages/provenance/grants/activations/revocations/quarantine/rollback |

The exhaustive table identifiers are frozen in
[`phase09-migration-plan-v18-v21.json`](../../contracts/v0.0.2/phase09-migration-plan-v18-v21.json).
`MigrationRunner` is the existing state-migration anchor; Gate 2 begins the
new migration implementation.

## Provider and plugin trust boundaries

Plugin ABI v1 is a fresh-instance WASI Preview 1 command invocation with one
bounded canonical input on stdin, one bounded canonical result on stdout, and
bounded diagnostic stderr. It gets no preopened directory, inherited
environment, ambient network, host socket, state database, Keychain, or direct
runtime access. Host-supplied time and randomness are deterministic. Capability
grants decide which input snapshots and proposed actions are accepted. Every
invocation input carries one canonical `scope`; a capability grant must match
that scope exactly, and every proposed action must repeat the same scope.

The upper limits are 16 MiB module, 1 MiB input, 1 MiB output, 64 MiB memory,
five-second normal deadline, and a 30-second absolute ceiling. Existing
WasmKit 0.3.1 is the pinned runtime anchor. Gate 10 installs the separately
pinned official Swift WASM SDK and proves the Swift guest SDK against
WasmKit/WasmKitWASI; it does not introduce Wasmtime, Rust, or a public registry.

Gate 10 implements that boundary in four parts. `HostwrightWASIProviderSDK` is
the dependency-free guest contract and command runner; its WASI build uses
`FoundationEssentials` and direct bounded stdio so the stripped reference guest
stays below the 16 MiB module ceiling. `HostwrightWASIProviderRuntime` validates
the immutable module path, owner/mode, SHA-256 digest, declared memory maximum,
bounded table/global/element declarations, WASI-only function imports, canonical
result, invocation identity, capability, and exact scope grant.
`hostwright-wasi-provider-worker` creates a new WasmKit/WasmKitWASI store and
Preview 1 bridge for every invocation with no preopens or environment and with
seeded random and fixed clock providers. A fail-closed in-worker watchdog bounds
the worker's peak resident memory to 512 MiB in addition to the 64 MiB guest
linear-memory limit. The outer secure subprocess boundary enforces output
limits, cancellation, and the hard deadline because WasmKit 0.3.1 has no stable
public fuel or epoch-interruption API. The reference guest calls the Preview 1
clock and random imports directly, and repeated fresh instances must produce
identical canonical results.

The reproducible guest build uses the separately installed official toolchain,
an isolated SwiftPM scratch directory, the `swift-6.3.3-RELEASE_wasm` SDK,
release optimization, a 64 MiB declared maximum, and linker stripping. The
Gate 10 harness owns the exact command, reference/adversarial interop traffic,
single active-run lock, source/toolchain digests, the published SDK archive
checksum, a cryptographically recomputed expanded-bundle digest, and signed
evidence; it never selects or mutates the Xcode toolchain used by the host
build. Each worker's canonical executable identity and process-start identity
are appended to the pinned ownership ledger while the child is suspended and
before it is continued; ledger failure prevents execution.

The XPC protocol is independently versioned at v1. Its service identifier is
`dev.hostwright.xpc-provider`, team `993YC3JY4Q`, and entitlement set is
exactly `com.apple.security.app-sandbox=true`. Reciprocal code requirements,
bounded dictionaries, request IDs, deadlines, cancellation, and crash
isolation are mandatory. Its sole reference native operation is read-only code
identity proof: team, code identifier, the native 40-or-64-character CDHash,
and declared entitlement projection. No secret or host mutation crosses it. Gate 11 supplies the signed,
notarized, stapled qualification package only as evidence.

Packages contain a canonical manifest, immutable content digests, compatibility
range, grants, provenance, and CMS signature. Sources are explicit local
directories or configured HTTPS registries via existing brokered networking;
there is no default public registry. Installation is immutable and
digest-addressed; activation selects a verified digest after staging and health
checking, update is atomic, and rollback selects a prior verified digest.
Revocation cancels sessions, terminates provider instances, invalidates caches,
and quarantines the digest without daemon restart. Cleanup can remove only
artifacts recorded in that plugin's ownership ledger. The package and invocation
fixtures are [`phase09-plugin-v1.json`](../../contracts/v0.0.2/phase09-plugin-v1.json)
and [`phase09-plugin-invocation-v1.json`](../../contracts/v0.0.2/phase09-plugin-invocation-v1.json).

## Serial implementation ownership

Until these shared contracts are frozen, no downstream implementation may run.
After freeze, Gate 2–12 remain serial because each changes the same request
pipeline and persistence authority. Recommended module boundaries are:

| Module | Owns | First gate |
| --- | --- | ---: |
| `HostwrightControlPlane` | public envelopes, schemas, fixtures, reason codes | 1 |
| `HostwrightDaemonCore` | socket listener, sessions, request pipeline, drain/restart | 2–3 |
| `HostwrightState` | v18–v21 records, verified backup/restore | 2–5, 12 |
| `HostwrightPolicy` | RBAC, admission, profile evaluation | 5–7 |
| `HostwrightObservability` | audit verification/export and stream health | 4, 8 |
| provider/plugin modules | WASI, XPC, package lifecycle | 10–12 |

Each later gate must provide focused U/I/L/M/S/R evidence, preserve passing
evidence unless an explicitly recorded dependency changes, and stop on a
failure. The existing one-shot adapter and declaration-only extension boundary
remain current behavior until their respective gates prove replacement.

## Gate 8 contract impact and evidence invalidation

Gate 8 completed the Gate 1 stream placeholder with the already-planned
full-duplex behavior. The reviewed delta is restricted to revision 2.1 stream
traffic: strict typed server acceptance, typed client stdin/resize/signal
input, reverse input credit, durable `exec`/`attach` request identity, explicit
audit health, server cancellation terminalization, and the frozen per-frame,
per-stream, per-subject, and daemon-wide limits documented above. It does not
change revision 2.0, unary revision 2.1, schema v20, RBAC vocabulary,
admission ordering, audit format, or Workload Profile v1.

This delta invalidates only the stream-dependent slices of the prior immutable
Gate 1, 3, 4, 5, 6, and 7 evidence. Their unrelated passing evidence remains
valid. Gate 8 must supersede those slices by rerunning the production-decoded
goldens, persistent transport/authentication, audit fail-closed/degraded-health,
stream RBAC, effective-intent admission, workload/runtime authority, and
restart/recovery tests in its single immutable six-cell root. Any later change
to these stream fixtures, limits, direction rules, cancellation modes, or
durable lifecycle semantics invalidates Gate 8 and every downstream consumer.
