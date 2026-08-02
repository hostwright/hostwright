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
Long operations acknowledge with a durable operation reference and expose
progress through a stream. Mutating acceptance persists request identity,
idempotency key, authorization and admission decisions, operation reference,
and audit record before acknowledgement.

The normal CLI is a client of this API. Local help/version rendering may remain
local. The Bootstrap API v2.1 is limited to `daemon install`, `daemon repair`,
and `daemon uninstall`; every daemon-ready read or mutation uses the persistent
socket. The complete frozen command classification is
[`phase09-cli-parity-inventory.json`](../../contracts/v0.0.2/phase09-cli-parity-inventory.json).
Gate 9 proves parity and removes direct runtime/state mutation bypasses; this
document does not claim that removal yet.

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
ad-hoc CDHash produced by the secure bootstrap path. An optional Hostwright
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

## Audit, profiles, and persistence

Audit records are canonical append-only SHA-256 chains, grouped into P-256
signed segments. Keys are in Keychain; public verification material and key
rotations are state data. Verification must expose removal, reordering, forks,
truncation, unauthorized key change, and clock anomalies. Retention removes
only a sealed prefix and appends a signed retention checkpoint. If audit append
fails, a security-sensitive mutation fails closed; read-only APIs remain
available with explicit degraded health. See
[`phase09-audit-v2.1.json`](../../contracts/v0.0.2/phase09-audit-v2.1.json).

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
grants decide which input snapshots and proposed actions are accepted.

The upper limits are 16 MiB module, 1 MiB input, 1 MiB output, 64 MiB memory,
five-second normal deadline, and a 30-second absolute ceiling. Existing
WasmKit 0.3.1 is the pinned runtime anchor. Gate 10 installs the separately
pinned official Swift WASM SDK and proves the Swift guest SDK against
WasmKit/WasmKitWASI; it does not introduce Wasmtime, Rust, or a public registry.

The XPC protocol is independently versioned at v1. Its service identifier is
`dev.hostwright.xpc-provider`, team `993YC3JY4Q`, and entitlement set is
exactly `com.apple.security.app-sandbox=true`. Reciprocal code requirements,
bounded dictionaries, request IDs, deadlines, cancellation, and crash
isolation are mandatory. Its sole reference native operation is read-only code
identity proof: team, code identifier, CDHash, and declared entitlement
projection. No secret or host mutation crosses it. Gate 11 supplies the signed,
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
