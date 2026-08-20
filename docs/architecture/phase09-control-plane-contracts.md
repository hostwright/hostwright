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
and audit record before acknowledgement. The bounded canonical accepted or
terminal response is persisted with the durable request before it is returned;
an exact request/idempotency replay decodes that response and never reinvokes
the handler or synthesizes a result-less replacement.

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
existing-style pre-migration backup. Old binaries seeing schemas 18–22 refuse
safely; rollback restores the corresponding backup rather than performing a
down-migration.

| Transition | Owned data group |
| --- | --- |
| 17 → 18 | peer identities, sessions, revocations, request/idempotency state |
| 18 → 19 | audit segments/records, key metadata, retention anchors |
| 19 → 20 | roles/bindings/delegations, policies/exceptions, workload profiles |
| 20 → 21 | plugin packages/provenance/grants/activations/revocations/quarantine/rollback |
| 21 → 22 | one active installed-identity bucket with atomic same-subject code-hash rotation |

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
and declared entitlement projection. No secret or host mutation crosses it.

Gate 11 implements this boundary as the `HostwrightXPCProvider` library, a
separately packaged `hostwright-xpc-provider-service`, and a qualification-only
client. The client pins the service requirement before activation; the service
pins the daemon requirement before accepting a request. Before accepting any
reply, the client re-reads the connected service's live `SecCode` identity and
rejects every entitlement set except the single sandbox key. The service also
strict-validates its own live identity before returning that exact projection,
and a completed response must match the independently inspected live proof.
The dictionary codec rejects unknown
keys, wrong XPC types, unsupported versions, invalid or overlong request IDs,
timeouts outside 1–5000 milliseconds, invalid proof fields, and error text over
its fixed bound. Client cancellation, deadline expiry, provider revocation,
peer failure, and service crash close the connection and resolve the request
with stable local reason codes.

The Gate 11 live harness constructs a proper per-user `.app` containing the
`.xpc` service, signs both boundaries with the pinned Developer ID identity,
and exercises proof, restart, timeout, cancellation, revocation, malformed and
oversized replies, crash isolation, and wrong identifier, entitlement, team,
and client identities. The immutable live cell requires an externally supplied
Keychain notary profile, notarizes the ephemeral package, staples and validates
the ticket, and then removes only ledger-pinned launchd jobs, processes, and
temporary files. The package is qualification evidence, not a release artifact.

Packages contain a canonical manifest, immutable content digests, compatibility
range, grants, provenance, and CMS signature. Sources are explicit local
directories or configured HTTPS registries via existing brokered networking;
there is no default public registry. A local source must use its exact lexical
canonical path and that path's `realpath` must be identical; symlink aliases and
noncanonical spellings fail before discovery or lifecycle persistence, and the
daemon never rewrites signed provenance. Installation is immutable and
digest-addressed; activation selects a verified digest after staging and health
checking, update is atomic, and rollback selects a prior verified digest.
Revocation cancels sessions, terminates provider instances, invalidates caches,
and quarantines the digest without daemon restart. Cleanup can remove only
artifacts recorded in that plugin's ownership ledger. The package and invocation
fixtures are [`phase09-plugin-v1.json`](../../contracts/v0.0.2/phase09-plugin-v1.json)
and [`phase09-plugin-invocation-v1.json`](../../contracts/v0.0.2/phase09-plugin-invocation-v1.json).

Gate 12 implements this lifecycle in schema v22 and the authenticated
`plugin.*` Control API. The daemon loads bounded DER certificates only from the
out-of-band, root-owned authority at
`/Library/Application Support/Hostwright/plugin-trusted-signers-v1`; every
directory component and authority file must remain root-owned and not writable
by group or other users. The daemon never creates or modifies this authority,
and Hostwright exposes no command or Control API that provisions it. A system
administrator must provision the canonical manifest and public DER certificates
externally; an absent authority permits no plugin package verification. A caller
may reference a configured signer identifier but cannot supply or alter trust material. Unknown
signers and legacy caller-certificate fields fail closed. Multiple active
certificates may overlap for a stable signer identifier during rotation. Both
the provenance signature over the immutable package digest and the manifest
signature over the canonical signature-free payload must verify against the
same configured certificate. Compatibility uses a bounded AND-only
semantic-version range, and update accepts only a version greater than every
installed version for the same identifier. The manifest is the complete
dependency closure: undeclared files, traversal, symlinks, special files,
content substitution, and signer substitution fail closed.

Absence of the fixed authority path is the only state that loads an empty trust
set while allowing daemon startup. Once the path exists, an empty, partial,
malformed, extra-entry, unreadable, or otherwise unsafe authority is globally
startup-fatal. External root provisioning must assemble and validate the complete
directory separately and publish it atomically; staged population of the live
authority path is unsupported.

The immutable store records rollback/install intent before effects, copies
through descriptor-safe reads into a private stage, records exact file and
directory device/inode/content ownership before atomic rename, and publishes
only the verified digest directory. Cleanup pins each parent directory and
performs descriptor-relative identity rechecks before removal. Interrupted
effects persist a terminal-audit-pending stage; terminal audit append succeeds
before that stage becomes final, so audit failure remains restart-retryable.
Provider health then runs through the
Gate 10 WASI worker or Gate 11 reciprocal XPC identity proof before the state
pointer changes. Active WASI invocation resolves that pointer back to the exact
immutable digest and grant, never a caller-supplied path. Revocation and
quarantine cancel in-flight work and only sessions for affected digests.
Configured HTTPS retrieval enforces the manifest or content limit inside the
transport as bytes arrive. `hostwright extension` lifecycle commands construct direct typed
`plugin.*` requests and never expose a local state-mutation fallback.

## Serial implementation ownership

Until these shared contracts are frozen, no downstream implementation may run.
After freeze, Gate 2–12 remain serial because each changes the same request
pipeline and persistence authority. Recommended module boundaries are:

| Module | Owns | First gate |
| --- | --- | ---: |
| `HostwrightControlPlane` | public envelopes, schemas, fixtures, reason codes | 1 |
| `HostwrightDaemonCore` | socket listener, sessions, request pipeline, drain/restart | 2–3 |
| `HostwrightState` | v18–v22 records, verified backup/restore | 2–5, 12 |
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

## Downstream qualification and closure contracts

Gates 13–16 have dedicated fail-closed dispatch paths in the shared Phase 09
qualification harness. The shared entry point retains the Gate 1 skeleton and
routes only the dedicated commands for Gates 13–16; an absent or unexpected
dedicated script is an error, never an implicit qualification.

Gate 13 is the ancestry and compatibility boundary. Its diagnostic path may
report the local compatibility matrix, but formal preparation requires an
exact immutable Phase 08 completion receipt and an ancestry proof against the
current Phase 09 source. The qualification path consumes the receipt and
immutable evidence digests only; it does not inspect a Phase 08 checkout,
branch worktree, process, runtime, or mutable state.

Gate 14 consumes a passed, CMS-verified Gate 13 bundle and binds the exact
500-execution aggregate matrix plus its security and resilience checks. A
diagnostic aggregate result has `claim: "none"`; it cannot be promoted to
formal evidence by the dispatcher or by a fixture substitution.

Gate 15 is the single continuous macOS qualification. It binds current Gates
1–14 evidence, signed/notarized identities, owned-resource ledgers, and the
same-process continuous-time sample chain. Its runner and daemon identities are
versioned kernel-derived bindings over each canonical executable path, complete
argv, and exact process start time, and each observed state database must report
the current schema v22 authority. A failed or interrupted root is retained and
cannot be resumed with a replacement process or partial elapsed time. The
qualification-only tool is rooted at
`Qualification/HostwrightPhase09QualificationTool`, is not reachable from any
declared product. The process-boundary checker permits only the two explicitly
named qualification executable paths (`Qualification/HostwrightPhase09QualificationTool`
and `Tests/HostwrightTunnelQualificationTool`) outside `Sources`. The regular
`HostwrightTestSupport` target is test-only, must remain at
`Tests/HostwrightTestSupport`, and is rejected from every product closure. The
shipped-product lint gate verifies the full local target graph and rejects
`Foundation.Process` from every product closure.

Gate 16 is local closure verification in
[`phase09-gate16-qualification.sh`](../../scripts/phase09-gate16-qualification.sh).
The shared router resolves every command from its own canonical Phase 09 path,
rejects symlink and protected-worktree boundary crossings, and validates the
worktree before dispatching contract, diagnose, prepare, run, status, or
finalize. Gate 16 `diagnose` emits non-qualifying canonical JSON; `run 16` and
`status 16` are explicit read-only local state/preflight reports with
`claim: "none"`. They never execute closure, create evidence, or perform a
public action; the router forwards even missing or invalid `finalize 16`
receipt arguments to Gate 16 after its repository boundary is valid, so the
Gate 16 failure-freeze trap can run. Only valid receipts can publish
`final-v1`.

`prepare` requires the fixed Gate 15 qualification parent and an exact
lowercase UUID root, then binds current HEAD, source, configuration,
toolchain, dependency, manifest, checksum, and CMS digests. The Gate 15
manifest and every transitive manifest must carry the current source,
configuration, toolchain, and dependency digests plus the exact signing
identity, signing fingerprint, embedded certificate SHA-256, and Team ID;
formal mode accepts only passed/formal, non-test manifests and sealed receipts,
including every transitive dependency record. Each dependency receipt and
manifest must carry the complete canonical marker profile (`formal: true`,
`formalClaim: true`, `testMode: false`, `qualifying: true`, `status: passed`,
`sealed: true`); missing, unknown, contradictory, legacy/schema-bypass, and
nested nonformal/test markers fail closed. Gate 16 applies the same exact marker
set to final-v1 and reused evidence before CMS sealing/publication. Their
dependency documents must match those fields. Gate 16 verifies CMS first,
extracts the certificate
actually embedded in the verified CMS, and compares its identity, SHA-1
fingerprint, certificate SHA-256, and Team ID to the pins. Identity-list
presence is not evidence. The Gate 15 ownership ledger
has an exact header and schema; every ledgered resource kind (temporary
root/file, socket, process, container, XPC, launchd, and Keychain) must have a
structured absence receipt at closure. Unknown or ignored kinds, live
discovery, and the Gate 15 `cmsVerified` boolean are never trusted.

`finalize` imports only a fixed local receipt export. It requires exactly PR
#206 with the declared head/base/merge SHAs, required verification labels,
the exact check names without duplicates, an approved review, every Phase 09
child state, an evidence comment, cleanup records, and a terminal hard-stop;
each PR, review, comment, issue, cleanup, absence, and hard-stop record is
bound to PR #206, the head SHA, and the merge SHA. Timestamps are strict UTC
values, including every `observedAt`, and form one strictly increasing total
order. The merge proof must contain exactly two parents in base-then-head
order. Prepared manifests and closure plans are authenticated before
finalization, and the receipt PR body and evidence comment must equal the
generated files byte-for-byte as well as by digest. Any failure freezes the
root permanently and disallows a retry. The finalize EXIT freeze trap is
installed immediately after a valid prepared root is recognized and before
receipt argument/path validation, including missing or invalid receipt paths.

Sealing is staged: preparation cryptographically seals the prepared manifest,
closure plan, generated PR body, generated evidence comment, and their binding
with the pinned signer. Finalization builds a complete private `final-v1`
directory containing the authoritative terminal manifest, receipts,
cleanup/hard-stop records, preseal index, checksums, CMS, and extracted signer
metadata. CMS sign, certificate extraction, round-trip verification, and all
staged checks must pass before one directory rename publishes `final-v1`; the
root-level manifest remains `prepared` until that rename. Closure, dependency,
manifest, and prepared-binding digests are rebuilt after final bindings are
added, then the prepared and final checksum/CMS relationships are reverified
against the exact staged bytes. The active finalization lock and owned temporary
artifacts are cleaned and verified before the one atomic rename; a durable
terminal lock remains to prevent concurrent reuse. Every JSON record
inside `final-v1` directly carries the same `sourceCommit`/`headCommit`,
`mergeCommit`, and `prNumber: 206`; exact binding, preseal artifact-digest,
and seal-reference checks run before atomic publication. There are no
sequential final artifact moves. `finalization_completed` is set only after the
atomic rename succeeds; no fallible cleanup or verification is required after
publication. A cleanup failure freezes the root before any passed `final-v1`
can be visible and permanently disallows retry. Test mode uses
private deterministic fixtures and a test CMS envelope, reports `test-passed`
only inside `final-v1` with `claim: "none"`, and cannot create formal or live
evidence.

The script performs only local validation and sealing work, including roadmap
`validate`, `self-test`, and `check-pr`; it does not execute network,
GitHub/public-action, `enforce-closure`, push, commit, merge, label/comment,
branch-delete, tag, or release operations. Any remote review, transition, or
repository operation remains coordinator-only and requires fresh explicit
maintainer approval after the exact generated plan is inspected.

These downstream paths are qualification infrastructure and do not alter the
Control API, migration, plugin, signing, or runtime product claims above.

## Gate 9 → Gate 8 release-time handoff

This section is an execution runbook, not qualification evidence. It is
intentionally not executable while the retained Phase 08 runtime owns the
Apple Container service. The Phase 08 owner must first provide an explicit
release boundary and the exact current runtime, project, and process
identifiers. Every preflight failure is a stop condition; no command below
deletes, stops, restarts, or recreates a Phase 08 resource.

### Read-only release preflight

Run the following from the Phase 09 checkout only, after the Phase 08 release
boundary has been announced. Replace the two `P08_*` values only with the
identifiers in that release receipt; do not broaden them into cleanup patterns.

```bash
set -euo pipefail
export P09_REPO=/Users/dev/Documents/hostwright-phase09
export P09_QUAL=/Volumes/T9/hostwright/qualification
export P08_RUNTIME_ID=hostwright-v2-p08-soa-web-27cc4ed52496a1ebce99ec8846250834
export P08_PROJECT_ID=p08-soak-d785738e

cd "$P09_REPO"
test "$(git branch --show-current)" = feat/v0.0.2-phase-09
test "$(/bin/realpath "$(git rev-parse --show-toplevel)")" = "$P09_REPO"
test -z "$(git status --porcelain --untracked-files=all -- . ':(exclude)tmp')"
test -d "$P09_QUAL" && test ! -L "$P09_QUAL"
test ! -e "$P09_QUAL/.phase09-gate09-active-v1"
test ! -e "$P09_QUAL/.phase09-gate08-active-v1"

# Read-only Apple Container inventory. An unavailable inventory is fail-closed.
container list --all --format json | /usr/bin/jq -e \
  --arg id "$P08_RUNTIME_ID" --arg project "$P08_PROJECT_ID" \
  'all(.[];
    .id != $id and
    (.configuration.labels["dev.hostwright.project"] // "") != $project and
    ((.configuration.labels["dev.hostwright.project"] // "")
      | startswith("p08-soak-") | not))'

# Read-only process inventory. A match is a stop, never a cleanup instruction.
if /bin/ps -axo pid=,command= | /usr/bin/grep -E '[h]ostwright-v2-p08-|[p]08-soak-'; then
  exit 75
fi
```

The clean-branch check is deliberate: `prepare` binds `HEAD`, the
working-tree digest, configuration, and toolchain, and live qualification
rejects a dirty source tree. The active-lock checks are also deliberate. A
preserved lock from a failed root is evidence, not permission to remove it; the
qualification owner must perform any separately authorized stale-lock
disposition while preserving the original root. This handoff supplies no
delete or lock-removal command.

### Gate 9, then Gate 8

After the preflight succeeds, allocate a new root for each gate. Never reuse a
failed or partially prepared root, and do not set
`HOSTWRIGHT_PHASE09_HARNESS_TESTING` for a live attempt.

```bash
export P09_GATE9_UUID="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
export HOSTWRIGHT_PHASE09_GATE_ROOT="$P09_QUAL/phase09-gate09-$P09_GATE9_UUID"
/bin/mkdir -m 700 "$HOSTWRIGHT_PHASE09_GATE_ROOT"
/bin/bash scripts/phase09-gate09-qualification.sh prepare 9
/bin/bash scripts/phase09-gate09-qualification.sh run 9
```

Gate 9 runs its six cells serially. A non-zero result freezes progress: retain
the root, active-run marker, parent lock, failure receipt, and diagnostics;
do not rerun that root, remove its lock, or start Gate 8. A successful result
is usable only when the script has produced a passed manifest, checksum, and
CMS sidecar and has released its active-run and parent locks. The derived
Gate 9 live root is
`/Volumes/T9/hostwright/qualification/.p09g9-${P09_GATE9_UUID:0:17}`; the
script's ownership ledger is the only authority for cleanup of its process,
container, Keychain, and files.

Only after those post-Gate-9 conditions are verified, allocate a distinct Gate
8 root and run the same two commands with gate 8:

```bash
test "$(/usr/bin/jq -r .gate "$HOSTWRIGHT_PHASE09_GATE_ROOT/manifest-v1.json")" = 9
test "$(/usr/bin/jq -r .status "$HOSTWRIGHT_PHASE09_GATE_ROOT/manifest-v1.json")" = passed
test -s "$HOSTWRIGHT_PHASE09_GATE_ROOT/evidence-v1.sha256"
test -s "$HOSTWRIGHT_PHASE09_GATE_ROOT/evidence-v1.cms"
test ! -e "$HOSTWRIGHT_PHASE09_GATE_ROOT/active-run-v1"
test ! -e "$P09_QUAL/.phase09-gate09-active-v1"
test ! -e "/Volumes/T9/hostwright/qualification/.p09g9-${P09_GATE9_UUID:0:17}"

export P09_GATE8_UUID="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
export HOSTWRIGHT_PHASE09_GATE_ROOT="$P09_QUAL/phase09-gate08-$P09_GATE8_UUID"
/bin/mkdir -m 700 "$HOSTWRIGHT_PHASE09_GATE_ROOT"
/bin/bash scripts/phase09-gate08-qualification.sh prepare 8
/bin/bash scripts/phase09-gate08-qualification.sh run 8
```

Gate 8 has the same immutable-failure rule and its derived live root is
`/Volumes/T9/hostwright/qualification/.p09g8-${P09_GATE8_UUID:0:17}`. Do not
advance to Gate 11 from this handoff: Gate 11 remains separately blocked until
`HOSTWRIGHT_NOTARY_PROFILE` and its expected Keychain credential are available.
