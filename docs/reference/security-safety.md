# Security And Safety Notes

Hostwright `0.0.2-dev` is not production ready. The active release target is `v0.0.2`; security-sensitive features remain unsupported until their owning roadmap issue has clean security and runtime evidence.

The v0.0.2 program turns earlier unsupported security-sensitive scope into explicit implementation work for trusted install, secrets, supply chain, storage, networking, tunnels, autonomous mutation, identity/RBAC/admission/audit, plugins, clusters, interoperability, GUI/MDM, and optional cloud control. The exact current state is emitted by `hostwright capabilities --json`; only the qualified networking, storage, lifecycle, and distribution subsets described there are supported on this development line.

## Runtime Boundary

All Apple container runtime behavior must go through `RuntimeAdapter`.

The CLI, reconciler, state store, health checks, networking, and observability modules must not shell out directly to Apple container for runtime behavior.

Production subprocess execution uses one shared bounded implementation. It passes arguments directly without a shell, resolves named tools only through root-owned path chains, constructs a minimal environment instead of inheriting the parent, pins the working directory by file descriptor, closes unrelated descriptors, verifies executable identity before continuing a suspended child, bounds stdin/stdout/stderr and time, distinguishes cancellation from timeout, and cleans the inherited session process group before releasing its PID fence. See [Secure Process Execution](process-execution.md) for the executable contract, migration, recovery, and test matrix.

## Mutation Boundaries

Supported application mutation requires an exact lifecycle plan hash and one durable schema-v17 operation group. `up`, `down`, `run`, `start`, `stop`, `restart`, `rm`, and `update` revalidate provider identity, capability digest, project/resource generation, ownership UUID, and fence before every mutation wave. Intent and compensation are persisted before effects; ambiguous results are re-observed; automatic rollback runs only when ownership and every inverse effect are provable. Otherwise Hostwright records a safe hold.

Phase 04 workload lifecycle remains separate from Phase 05 image preparation, Phase 06 storage, and the exact Phase 07 networking boundary. Image commands implement strict Apple CLI pull/build/push/tag/load/save/inspect plus exact Hostwright-owned delete/prune. Storage commands implement exact Hostwright-owned named volumes, snapshots, verified backup/restore, quotas, reclaim, and orphan recovery. Networking commands implement exact owned networks, DNS, ingress, certificates, policy, and tunnels; none of these surfaces add unattended daemon mutation or broad/unmanaged cleanup.

Restart policy state can block managed restart through backoff, operator hold, manual disable, and crash-loop protection. The daemon computes that state before lifecycle admission and refuses a blocking reconciliation plan; supported admitted work executes only through the shared fenced lifecycle saga.

Manual hold release is a same-user confirmation boundary, not a bearer-authentication mechanism. It requires the exact private state database, project, service, and current hold token; the release generation fences later state/history writes so a stale daemon snapshot cannot restore a cleared hold.

Maintenance cancellation and emergency override are also same-user exact-state confirmation boundaries, not authentication or remote approval. The token binds the current project, reconciliation plan, policy digest, elective action classes, and first-deferral time. A newer plan, changed policy, prior cancellation/admission/failure, or stale token changes nothing. The lifecycle driver reopens the declared configuration set and rechecks that exact binding plus the still-open interval immediately before effects. Safety recovery and security-stop actions cannot be placed behind an elective window.

## LaunchAgent Boundary

The Phase 08 daemon lifecycle owns one current-user label and plist: `dev.hostwright.daemon` at `~/Library/LaunchAgents/dev.hostwright.daemon.plist`. It permits only root- or current-user-owned executable/config inputs and requires its own lifecycle artifacts to be current-user-owned. Canonical paths, regular single-link files, non-writable-by-group/others modes, and access-granting ACL absence are checked at the applicable boundaries. Plist, lifecycle journal, status, rollback metadata, and logs are private; the plist uses absolute arguments, has no `EnvironmentVariables` key, and sets a `0077` umask. Before runtime construction, the managed executable revalidates itself and replaces its process image once when needed with an exact initial environment containing only the validated current-user `HOME`, fixed C locale, and trusted system `PATH`.

The running daemon securely reopens the explicit manifest and only its declared local trust/provenance key files with `O_NOFOLLOW`. It rejects symlinks, hard links, unsafe owners or modes, non-UTF-8/NUL content, oversize input, identity changes during read, and target drift between plan and mutation. Parent-directory notifications are bounded wake hints; the level-triggered scan remains authoritative. Invalid, partial, future-version, or permission-invalid input cannot replace the last accepted desired state, and rejection evidence contains stable hashes and reason codes rather than raw configuration or paths.

Lifecycle mutation is serialized by a non-blocking advisory lock on the exact validated home-directory inode, then intent is atomically exclusive and durable before launchctl or plist effects. Completion requires exact launchctl path/program/state/PID plus single-process executable proof. Deleted-executable processes are detected through bounded kernel process arguments when `proc_pidpath` is unavailable. Changed plist bytes, linked files, symlinks, unsafe permissions, duplicate controllers, an unowned persistent disable override, a loaded `homebrew.mxcl.hostwright`, or any unmanaged `hostwrightd` fail closed. No lifecycle error authorizes process termination or ownership inference.

Disable state is changed only through `launchctl enable|disable` for the exact managed target. Uninstall removes only hash-bound lifecycle files after bootout and clears that exact disabled override; it preserves configuration, SQLite state, distribution payload, external Homebrew records, and unrelated files. Daemon workload mutation is separate from LaunchAgent lifecycle and requires exact provider capability, plan confirmation, ownership, project generation, durable intent, fencing, and post-effect verification.

New runtime resources use collision-resistant v2 identifiers and exact labels for managed state, identity version, project, service, optional instance, and resource identifier. Mutation plans retain the exact observed identifier. State-backed legacy identifiers remain readable for upgrade continuity, but labels or ownership records may not be inferred from a Hostwright-looking name.

## Local Control Authorization Boundary

The persistent Control API authorizes the kernel- and code-bound local subject
after session revalidation and before a mutation can enter idempotency or
accepted state. Unknown operations require `daemon/admin`; an unbound subject
has no permissions. Every healthy authorization decision is appended to the
tamper-evident audit trail. An audit append failure blocks mutation before
durable acceptance, while read-only handling retains the Gate 4 degraded-audit
behavior.

Schema v20 stores five immutable default roles, custom roles, scoped bindings,
and expiring delegations. The fixed resources, verbs, global/project/resource
scopes, and AND-only conditions are defined by the Phase 09 golden contracts.
Explicit deny rules override every allow. Authorization explanations return
stable reason codes and sorted matching rule identifiers. The in-process cache
is keyed by a digest of the complete persisted RBAC snapshot, so a role,
binding, delegation, revocation, or expiry change takes effect without a daemon
restart.

Bootstrap creates one global owner binding only for the installing declared
subject. SQLite and repository guards preserve at least one global owner and
make built-in roles immutable. `security-admin` may grant only permissions it
already holds; custom role, binding, and delegation paths compare each allowed
resource/verb pair against the actor's current authority. Owner cannot be
delegated, delegations must expire in the future, conditional grants by a
non-owner are refused, stale generations fail, and only a delegator or global
owner may revoke a delegation.

The implemented Control API management operations are `rbac.preview`, the
`rbac.role.*`, `rbac.binding.*`, and `rbac.delegation.*` families. Their typed
payloads compose the frozen `RoleDefinition`, `RBACBinding`, `RBACDelegation`,
`ControlRequestEnvelope`, and scalar generation fields; request-supplied actor
or creation timestamps are not authoritative. Mutation responses and errors
are bounded and sanitized. Gate 9 still owns normal CLI parity, so these
operations do not yet claim a complete CLI surface.

Schema-v17 ownership authority binds exact resource/project UUIDs, resource/project/provider generations, controller, provider, fencing token, and a deterministic ownership proof. A delete or cleanup records versioned deletion intent and ordered finalizers before provider mutation, then requires fresh exact runtime absence and released dependent port/tunnel finalizers before removing the ownership row. Missing, legacy, forged, stale, live-leased, or ambiguous authority fails closed. Cleanup never searches by a Hostwright-looking name, deletes an unmanaged resource, or treats provider acceptance as proof of absence.

`hostwright ownership handoff` is a local recovery compare-and-swap, not authentication or general lease takeover. It accepts only an expired exact `lifecycle-v1` group/plan/fence/controller/expiry tuple, targets the bounded `resume` or `rollback` controller, and atomically advances the group lease plus every bound ownership record. An in-flight effect holds a private per-group OS fence, so handoff cannot overtake it. Lifecycle recovery replaces the fixed controller with one UUID-qualified process owner through a second single-winner compare-and-swap; the former controller and losing recovery processes cannot mutate, append evidence, finalize, clean up, or terminalize the group. Other mutation kinds retain their existing native recovery contracts and are refused by this command. A live or changed lease, unsupported operation kind, malformed authority, or stale proof changes nothing.

Operation recovery records bind exact checkpoints, failed/completed steps, verified effects, and precomputed inverse actions. Confirmed resume or rollback re-observes the runtime and proceeds only when identity, ownership, fence, and effect remain exact.

Automatic compensation and confirmed rollback select prior revisions only from exact healthy ownership/recovery evidence. Completion requires one exact resource UUID/generation and fresh running plus configured startup/readiness/liveness proof. Ambiguous effects, irreversible hooks, missing ownership/inverses, unavailable prior or sensitive configuration, compensation failure, and failed restored health use stable bounded safe-hold reason codes. Restored-health failure preserves owned resources and cannot trigger inverse-of-rollback candidate recreation.

## Local State Boundary

State-backed commands default to the per-user Application Support database. An explicit CLI override wins over `HOSTWRIGHT_STATE_DB`, which wins over the default. Before SQLite or daemon-lock use, Hostwright enforces absolute normalized paths, safe root/current-user parent ownership, no group/other-writable or access-granting-ACL parents, no user-controlled directory symlinks, exact `0700` owned directories, and current-user-owned regular single-link `0600` sensitive files without special bits or access-granting ACL entries. Creation explicitly applies those modes instead of depending on the caller's `umask`.

The default-path legacy migration accepts only a compatible checksum-valid Hostwright SQLite ledger. It refuses destination conflicts, rollback journals, unsafe or non-WAL sidecars, active writers, cross-filesystem moves, identity changes, and ambiguous crash state. A validated WAL source is checkpointed to sidecar-free DELETE mode while Hostwright holds an exclusive SQLite lock. A synchronized journal makes the one atomic rename resumable; unknown `~/.hostwright` files are never moved or removed.

Authoritative state is bound to SQLite `application_id` `0x48575254` (`HWRT`). Hostwright claims a legacy zero identifier only inside a validated explicit migration and rejects a foreign nonzero identifier before persistent connection configuration. State connections require `NOFOLLOW`, pre/post-open inode validation, private database and sidecar metadata, defensive/untrusted-schema mode, bounded SQL and memory behavior, WAL/FULL plus macOS full-fsync barriers, and a bounded writer fence. Managed transaction bodies cannot begin, commit, roll back, or savepoint around Hostwright's boundary; cancellation and storage-pressure failures require verified rollback.

`hostwright paths` exposes origin, readiness, effective lock path, pending-journal state, and policy failures without creating state. `hostwright doctor` validates existing state plus prospective parent/layout safety before first use. Existing state is accepted only as a checkpointed sidecar-free snapshot, opened with SQLite immutable read-only semantics after file identity validation. Doctor uses an existing shared fence without creating one, revalidates identity after inspection, and refuses rollback journals or nonempty WAL data rather than checkpointing another writer. See [Local Paths, Permissions, and Legacy Migration](local-paths.md) for the full security and recovery contract.

These controls prevent Hostwright from crossing filesystem trust boundaries. They do not sandbox another process already running under the same macOS account, and they cannot force a same-user program that opens the SQLite file directly to honor Hostwright's writer fence. Direct external writes are unsupported and must stop before restore, repair, or recovery.

Event cursors bind only a validated non-secret event identifier and SHA-256 of the complete stored redacted row. Cursor input is canonical and size-bounded; modified retained rows fail integrity and deleted anchors produce an explicit retention gap. Watches are local read-only long polls with bounded filters, page size, timeout, and synchronous output backpressure. They create no listener, credential, state row, file, socket, or runtime resource. The SQLite ledger remains authoritative; OSLog is only a best-effort local mirror. See [Durable Events and Local Watches](events.md) and [Local Observability](observability.md).

Metrics use only fixed catalog-owned names, label keys, and label values. No project, service, resource, operation, provider, path, endpoint, host, error text, secret, credential, or PII becomes a label or raw-row export. Snapshot is a shared-fenced read of existing schema-v17 authority and creates no sample store or listener. Export requires an exact recomputed confirmation hash and a canonical current-user private parent; an `openat`-bound exclusive/no-follow mode-`0600` file is revalidated by descriptor and path identity before success. Cancellation or failure removes only the exact created incomplete file. There is no automatic upload. See [Bounded Local Metrics and SLOs](metrics.md).

Trace records use only fixed span names and closed attribute keys/values, canonical UUID context, bounded depth/count/size, and post-commit event/operation identifiers. Raw output, errors, paths, manifests, project/service/resource names, credentials, PII, and secret references are not accepted as attributes. Trace failure never changes control status. Export requires a complete retained trace plus its exact recomputed hash and uses the same exclusive descriptor-bound private-file contract as metrics. Trace rows retain independently under the Manifest-v2 `traces` class; no listener, external exporter, or automatic upload exists. See [Correlated Local Traces](traces.md).

## Policy Boundary

Policy evaluation is local, deterministic, and non-mutating. `HostwrightPolicy` explains allow/warning/blocker decisions for planner safety checks, cleanup classification, image policy, env/secrets, lifecycle requests, secure exposure requests, untrusted manifests, accelerator placeholders, and extension declarations.

Policy decisions do not execute Apple container, write SQLite, contact registries, upload telemetry, configure DNS, create tunnels, distribute team policy, or apply automatic overrides. Unknown, ambiguous, or high-risk settings remain blocked unless a later reviewed implementation adds a narrower explicit gate.

## Team Workflow Boundary

Team workflow support is explicit local profile and approval data only. Hostwright accepts strict-only profile requirements and exact profile/manifest/plan-bound approvals; it does not provide policy weakening, a cloud team service, central remote control, hosted audit log, user tracking, enterprise support workflow, or remote policy distribution.

Team profiles cannot bypass plan-hash confirmation, cleanup tokens, ownership checks, redaction, secure selected-state policy, local-only diagnostics, or `RuntimeAdapter`. Approval records authorize only the exact bound apply or cleanup operation; they do not override hard-coded safety gates.

Benchmark execution is separate from apply/cleanup state. It requires all source, image, sample, report, expected-version, and live-confirmation inputs; refuses an existing report path; records every attempted exact identifier; waits for terminal-state quiescence; and verifies absence after delete. It has no image-pull, force-delete, broad-cleanup, state-write, or upload path. An attended sleep/wake option observes a timing gap and exact post-wake identity but never initiates system sleep.

## Extension Boundary

Extension execution is limited to the explicit `hostwright extension check` handshake. Hostwright evaluates a strict typed declaration for identity, declaration/protocol version, reviewed-local trust, one read-only capability, purpose, required boundaries, and exact executable SHA-256 before it starts a process. It does not discover, install, distribute, persist, or invoke extension capabilities.

Built-in and reviewed-local non-mutating declarations can receive allow decisions only when they declare the required RuntimeAdapter, HostwrightState, local policy, redaction, audit, explicit-state-path, local-only/no-upload, confirmation, ownership, and no-runtime-mutation boundaries for the requested capability.

Executable declarations additionally require explicit absolute paths, caller-owned regular non-symlink files, no group/world write access, an exact digest, and an approved kind/capability pair. The executable is copied from an open descriptor into a private mode-`0500` staging directory. The one-shot process receives a minimal environment and descriptor-pinned `/` working directory; stdin, timeout, stdout, and stderr are bounded; inherited descriptors are closed; task/process cancellation and inherited process-group cleanup are enforced; strict response bindings are verified; raw stderr is not surfaced; and staging cleanup must finish before success.

Third-party, untrusted, unsupported-version, empty, missing-boundary, runtime-mutation, state-write, networking-provider, tunnel-provider, secret-resolution, and accelerator extension declarations fail closed. The reviewed-local process is not an operating-system sandbox and retains the invoking account's ambient file, process, and network privileges. Hostwright terminates descendants that remain in its inherited session/process group, including children that ignore `SIGTERM`; it does not claim to contain native code that deliberately establishes a new session or uses ambient account authority directly. The digest must therefore correspond to code the operator actually reviewed. Phase 09 issues #203 and #204 own capability-limited WASI and signed XPC isolation.

## Governance Boundary

`GOVERNANCE.md`, `CONTRIBUTING.md`, and `SECURITY.md` define maintainer review triggers for dependencies, release artifacts, runtime mutation, state migrations, cleanup, secret handling, diagnostics, policy, networking, external compatibility, multi-host, accelerator, GUI, website, and public support claims.

These documents are process controls only. They do not add branch protection, CODEOWNERS enforcement, support SLAs, hosted diagnostics, telemetry upload, cloud services, or release artifacts.

## Release Distribution Boundary

Phase 35 added the fail-closed local unsigned distribution lane. Phase 02 retains it and adds a separate trusted-release path. `hostwright-dist` accepts explicit paths only, rejects dirty clean-build inputs, validates all four ARM64 executables by execution and Mach-O slice, creates exact manifests, binds SHA-256/SPDX/provenance sidecars, and rejects hidden/link/path/mode/digest drift before an artifact becomes installable. The standalone unsigned `lifecycle` evidence command remains restricted to an explicit `hostwright-dist-*` temporary directory.

The installed lifecycle is a separate ownership boundary for an explicit existing prefix. The prefix must be normalized, non-symlink, root/current-user owned, and not group/other writable; protected system roots are refused. A private lifecycle fence serializes mutation. Durable status, an operation journal, transaction-bound staged payload, exact prior-payload inventory, optional verified SQLite snapshot, and a one-generation rollback record bind every effect to one installation UUID and generation.

Install and upgrade require complete verified artifacts and refuse payload collisions or modified current ownership. Repair accepts only the exact installed semantic version and source commit; it can restore a missing or content-corrupted owned regular file but refuses symlinks, hard links, special files, special permission bits, unsafe ownership, and ambiguous lifecycle metadata. Arbitrary downgrade is refused. Rollback is possible only from the verified prior generation retained by the current successful upgrade.

Uninstall re-verifies every owned payload path. `preserve` removes only verified installed payload and lifecycle metadata and leaves the bound state database. `remove` additionally requires a generation-bound plan token, snapshots the compatible Hostwright database, and removes only that database plus its existing SQLite sidecars. Backup catalogs, configuration, caches, logs, unrelated prefix content, and Apple container resources are not deleted. Interrupted mutations remain journaled for deterministic `hostwright-dist recover`; operators must not delete recovery metadata manually.

The Apple Installer bridge does not write package payload directly into `/usr/local`. It stages only beneath the private root-owned `/Library/Application Support/Hostwright/InstallerPayload`; its elevated `package-apply` boundary verifies the exact `dev.hostwright.cli` receipt/version, staged manifest and file identities, executable signatures against the Team ID embedded by the trusted release build, package-origin status, and normalized `/usr/local` prefix before delegating to the existing fenced lifecycle. Package uninstall supports preserve only, forgets only that receipt after commit, and records interrupted receipt/staging cleanup for `recover`. Package remove-data planning and uninstall fail before mutation rather than inferring or searching for per-user state from an elevated process. Generic archive mutation is refused for package-owned generations, and no privileged daemon or automatic uninstaller is introduced.

The distribution lifecycle does not create, register, or autostart a LaunchAgent. It stops and restores only an exact safe current-user Homebrew launchd record bound to the installed prefix, and fails closed on record or live-service ambiguity. An unmanaged installed `hostwrightd` is never terminated or adopted. The separate `hostwright daemon` controller owns only `dev.hostwright.daemon`. The distribution contract is in [Installed Distribution Lifecycle](installed-lifecycle.md).

The trusted path requires exact non-ambiguous Developer ID Application and Installer fingerprints from one team, a preconfigured `notarytool` Keychain profile, two byte-identical clean payload builds, hardened-runtime signatures, Apple acceptance, online ZIP tickets, a stapled package ticket, Gatekeeper acceptance, exact payload/package inventories, per-artifact SPDX, source/digest-bound provenance, sorted checksums, exact single-signer CMS verification, and final independent extraction/expansion verification. Secrets are not accepted in argv. SIGINT/SIGTERM and explicit cancellation use the same bounded process-tree cleanup path.

The protected release workflow separates build/sign, attestation, and publication. Repository code runs with read-only contents permission and no OIDC or publication authority. A GitHub-hosted no-checkout job receives only OIDC/attestation authority for the retained signed files. Only the final no-checkout publication job receives contents write permission. Actions are commit-pinned, tags are immutable, published bytes are downloaded and compared, GitHub attestations are verified, and a failure after tag creation removes the release/tag.

Current public Hostwright releases nevertheless remain source-only. Local unsigned artifacts are non-publishable, and no trusted artifact is called supported until real Developer ID identities, notarization, Gatekeeper, signed `.pkg`, system lifecycle, vendor-tap publication/install, and clean-Mac evidence pass. No usable identities or release variables are configured on the reviewed machine/repository. The vendor-tap repository exists, but it has no qualified formula until immutable signed public artifacts are available.

## Control Surface Boundary

Daemon-ready local control uses the authenticated, user-private Unix-socket
Control API v2.1. It has no TCP listener. Kernel peer credentials, audit token,
live code identity, the persisted subject, RBAC, admission, effective-intent
reauthorization, durable idempotency, and tamper-evident audit all run before a
mutation handler. The one-shot `hostwright-control` companion remains only the
bounded bootstrap path for daemon installation and repair. Neither surface
permits request-selected state paths or direct calls around the shared
validation, ownership, provider, migration, and audit boundaries.

Admission policies are bounded declarative documents, not arbitrary native
code. Conflicting writes, malformed policy state, stale plan hashes, expired or
ambiguous exceptions, effective-authority escalation, and audit failure deny a
mutation before effects. Only an explicit advisory non-mutating extension may
ignore its own execution failure. Dry-run admission has no durable request or
runtime effect.

Phase 09 schema v18 adds the persistent identity foundation without yet opening a Control API listener. Authentication cross-checks `getpeereid`, `LOCAL_PEERPID`, and `LOCAL_PEERTOKEN`; binds the audit-token UID, GID, PID, PID version, audit session, daemon generation, socket device/inode, and nonce; and validates live code through `SecTaskCreateWithAuditToken` plus strict `SecCode` requirements. Installed peers are restricted to the frozen Hostwright team and identifier set. Ad-hoc peers require an explicit native CDHash pin. Optional P-256 proof refines but never replaces kernel and code identity. Sessions are persisted before use and are invalidated immediately by subject, credential, native CDHash, session, credential rotation, expiry, or daemon-generation change.

Configured files must be existing regular non-symlink files with safe ownership, no group/world write permission, and no set-ID bits. This check reduces accidental or cross-account substitution; it is not an operating-system sandbox or a guarantee against the invoking account replacing its own files. State-backed status can perform compatible path/schema migration, observation snapshot, and audit writes to the launch-configured database or the secure default when no state override is configured. An image mutation can affect only the exact versioned image request accepted by the shared coordinator. Source-consuming and destructive requests are bound to structured pre-observation digests before provider effects. Load verifies the complete inventory delta, and interrupted creation recovery requires durable reference-to-digest proof before adoption or exact rollback.

## Cleanup Safety

Cleanup is destructive and requires all of these:

- a selected state database that passes the secure local path policy;
- dry-run first;
- matching cleanup token;
- Hostwright ownership record;
- live runtime observation;
- exact Hostwright-owned container identifier;
- matching project and service;
- created, stopped, or exited lifecycle state.

Dry-run reports ambiguous, stale, running, unknown, blocked, and never-delete records without deleting them. Confirmation deletes only records classified as eligible in the current dry-run plan.

Cleanup does not delete images, volumes, networks, Apple builder resources, base images, or unmanaged containers.

## Storage Boundary

Named-volume authority comes from schema-v17 project/resource UUIDs, provider ID, generation, fencing token, ownership proof, and current provider observation. A name or filesystem path is never sufficient. The shipped `hostwright-local` provider confines managed data below its private Application Support root; its signed helper validates peer UID, process identity, code signature, bounded protocol frames, capability digest, deadline, idempotency key, and mutation context.

Bind mounts use descriptor-based no-symlink validation and reject host root, devices, traversal, unsafe ownership or permissions, and identity swaps. Writable attachment, detach, snapshot, restore, expansion, delete, and reclaim revalidate generation and fencing immediately before effects. One-writer and read-only-many rules are enforced from both durable state and provider observation.

Snapshot and backup promotion requires exact content and metadata hashes. Backup key material and S3 credentials are resolved only from typed Keychain references inside the provider; credential values never enter argv, state, logs, result JSON, or diagnostics. Remote targets require one validated HTTPS origin and exact bucket, region, prefix, and credential-reference identity. Restore creates a new target identity and promotes it only after complete verification.

Volume deletion and prune require a current dry-run hash. Active attachments, durable operations, holds, retained policy, changed metadata, unknown ownership, unmanaged data, and unverified snapshot/backup prerequisites fail closed. Abrupt or ambiguous effects remain in an exact resumable record; recovery re-observes before retrying. `hostwright cleanup` remains container-only—storage deletion occurs only through `hostwright volume` and its independent confirmation boundary.

## Secrets And Redaction

Hostwright keeps execution environment values separate from display and persistence values. Runtime command construction receives the manifest value, while command output, logs, state payloads, events, plan output, and failure messages use redacted values.

Plaintext credential-like environment keys in `env` are rejected. Use `secretEnv` with a typed `keychain://`, `env-file://`, `local-file://`, `external://`, or `plugin://` reference. A reference is not the secret value, but Hostwright redacts every provider reference from state, diagnostics, plans, and errors because it can reveal local account or path context.

Registry credentials use a distinct endpoint-derived Keychain service/account and the same durable schema-v9 mutation boundary. Login secrets come only from stdin or an attended no-echo terminal. Docker and OCI auth files are opened without following symlinks, must be exact current-user-owned private regular files, and are identity-checked after bounded reads. Credential helpers run through the secure subprocess boundary with the registry on stdin and never receive credentials in argv.

Registry network traffic is HTTPS-only with system TLS validation, bounded headers and bodies, no cookies or cache, and at most three same-origin redirects. Basic and Bearer authorization are never forwarded across origins. Bearer challenges, token documents, requested scopes, expiry, refresh, and rotation are validated before reuse; refresh tokens are sent only to the original HTTPS token realm. Errors and capability output contain no credential, token, auth-file content, or helper stderr.

After an explicitly confirmed create resolves a `secretEnv` reference, Hostwright transports the value to the Apple CLI only through its bounded child environment and passes `--env KEY` so the CLI inherits it. The resolved value is not placed in argv or an environment file. Runtime result specs, output, errors, state, events, and diagnostics apply exact-value redaction before leaving the execution boundary.

The default CLI resolves Keychain items and guarded local environment or value files only for the exact project, resource generation, service, and environment key granted by the confirmed workload plan. External and plugin providers fail closed unless an explicitly configured resolver registers the matching stable provider and grant; Hostwright never falls back to a shell command or network lookup. The production `MacOSKeychainSecretStore` uses an interaction-disabled authentication context, excludes synchronizable items, uses `WhenUnlockedThisDeviceOnly`, and creates, updates, lists metadata for, and exactly deletes only Hostwright-owned Keychain items.

Redaction is heuristic. Users should not place plaintext credentials in manifests, logs, examples, fixtures, or issue reports.

Health check stdout, stderr, command payloads, events, operation recovery hints, operation recovery metadata, and persisted result metadata are redacted before display or storage.

Diagnostic bundles are local-only JSON exports. They redact known secret-like values before writing, use exclusive `0600` creation, refuse to overwrite an existing file, and are never uploaded by Hostwright. They can still contain sensitive local context such as project names, service names, file paths, hostnames, resource identifiers, event timing, and redacted-but-contextual metadata. Review bundles before sharing.

## Untrusted Manifest Input

Treat `hostwright.yaml` files from third parties as untrusted input. Hostwright validates a restricted manifest subset and rejects unsupported YAML, Kubernetes-style fields, Compose-style fields, unknown service fields, unsupported manifest versions, unsafe host-root or parent-traversal mount sources, and unsafe environment keys before planning or mutation.

`hostwright validate` and `hostwright plan` are non-mutating review gates. Operators should still inspect image names, port publishes, environment values, volume paths, and loopback health probe commands before running any confirmed `apply` or daemon loop.

Secret references do not make third-party manifests trusted. A manifest can still point at local secret labels, images, paths, and ports that the operator must review before confirmed mutation.

## Image Trust Boundary

Manifest `imagePolicy: require-digest` requires service image references to use `@sha256:<64 lowercase hex characters>` before planning or mutation. For both policies, lifecycle dry-run resolves the local provider record to an immutable descriptor plus exact Linux platform variant and binds that evidence, platform, provider, and capability digest into the confirmation hash. A moved tag or changed descriptor, variant, platform, provider, or capability produces a new plan or fails closed before mutation.

Resolution uses only bounded local provider evidence and does not contact registries or pull missing images. With no `imageTrust` declaration, digest locks remain content identity rather than publisher trust. With `imageTrust`, a separate offline preflight requires an exact passing signature record or exact active exception before provider mutation.

Operators should still decide which registries, image publishers, digests, and local images they trust. A digest-pinned reference is a content identifier input to Hostwright, not a complete supply-chain trust guarantee.

Image lifecycle operations never treat mutation stdout as state. Apple CLI results come from bounded structured inventory observed before and after the operation, with immutable descriptor-digest verification. Credentials remain within the registry/provider boundary and are never accepted as image CLI fields or copied into argv, state, progress, diagnostics, or provenance.

Confirmed lifecycle intent stores the complete non-secret lock before provider effects. Schema-v13 state keeps separate desired and postcondition-observed lock evidence plus immutable signature, SBOM, vulnerability, and build-provenance records. Plan-bound authorization events make recovery revalidate the same digest, policy, Gate 6 graph, artifact bytes, and current trust material before further effects. `status` and one-shot Control status expose bounded evidence without credentials.

Image delete and prune require exact Hostwright-owned reference/provider/digest records and refuse content referenced by a live container. Schema-v14 cache pressure planning applies deterministic size/retention policy only to provider-scoped accounted content. Deletion requires an exact confirmed plan, an exclusive fenced lease, post-delete observation, and durable recovery accounting; active shared leases, operator or policy pins, desired digest locks, live references, concurrent reference changes, and unmanaged content block it. Native prune, `--all`, `--force`, global or automatic garbage collection, and unmanaged deletion remain unavailable. The Containerization helper reports image mutations unavailable before effects.

## OCI Referrer Transport Boundary

OCI referrers are opaque typed artifact transport in Gate 6. Discovery accepts only exact repository and subject digests, validates any declared index subject, bounds pages, descriptors, graph depth, object bytes, and total bytes, and follows only same-origin HTTPS pagination. Fallback-tag reads and updates are allowed only when the truncated tag preserves exact digest identity; updates additionally require an ETag or create-only condition. Hostwright refuses non-injective or unfenced fallback behavior before effects.

Fetch verifies descriptor size, digest, media type, graph edges, and root subject binding before caching. Publish persists non-secret durable intent first, uploads children before manifests, verifies exact remote bytes after mutation, and records ownership only for root manifests proven newly created by that operation. Interrupted publication resumes by exact operation group and plan. Credentials stay inside the authorized transport and are absent from argv, graph payload descriptions, state intent, progress, diagnostics, and errors.

Narrow retention leases use exact UUID fencing tokens. Remote cleanup requires a confirmed plan hash, an inactive lease set, immutable Hostwright publication evidence, exact remote content and subject revalidation, and post-delete absence. Fallback cleanup conditionally removes only the matching descriptor and restores it if the exact manifest delete fails. It never deletes blobs, unrelated manifests, indexes belonging to another subject, or invokes a registry-wide prune. This remote artifact-retention boundary is separate from schema-v14 local content-cache accounting and does not authorize runtime-image or OCI-cache pressure deletion.

Phase 08 state compaction is another separate local boundary. It accepts only a fully validated Manifest-v2 policy and an exact dry-run token, creates a verified rollback backup, and deletes only allowlisted schema-v17 rows whose age/count eligibility, recovery horizon, hold status, terminal state, finalizers, references, UUID generation/fence identity, and complete logical snapshot still match. Security, trust, provenance, vulnerability, secret, approval, operator, maintenance, and retention events are isolated in the audit class. Backup pruning uses only a verified private catalog identity and same-parent atomic staging. Journal, torn-commit, terminal-effect, or integrity ambiguity blocks ordinary state access and preserves evidence. Database pressure never authorizes global/native prune, runtime mutation, current authority deletion, recovery-horizon reduction, hold bypass, or unmanaged filesystem cleanup.

Phase 08 support bundles are an explicit local disclosure boundary, not an automatic crash collector. Preview and create project only fixed bounded version, capability, configuration-shape, integrity, OSLog, event, metrics, trace, operation, and evidence fields. Record IDs are hashed; raw manifest values, event/operation payloads, paths, environment values, secret stores, Keychain contents, credentials, and private keys are excluded. A fresh preview hash is required before one new private file. Optional macOS CMS encryption receives plaintext only on bounded subprocess standard input and persists only encrypted output plus a recipient-reference hash. A private durable journal records file intent and exact identity; recovery safe-holds on ambiguity. Deletion requires both retained Hostwright creation evidence and an unchanged single-link device/inode/hash/size identity. No bundle is uploaded, retained externally, overwritten, broadly discovered, or deleted by compaction, daemon cleanup, distribution uninstall, or another file's receipt. See [Privacy-Safe Support Bundles](support-bundles.md).

Gate 6 transport does not interpret artifact contents. Gate 7 interprets only standardized Sigstore bundle v0.3 message signatures for exact digest-bound image trust. Gate 8 interprets only bounded SPDX 2.3 and CycloneDX 1.5/1.6 image-SBOM JSON. Gate 9 interprets only the bounded signed vulnerability-report contract. Gate 10 interprets only DSSE Ed25519 envelopes whose payload is an in-toto Statement v1 with the SLSA provenance v1 predicate and the exact image subject. Gate 11 adds bounded accounting, pins, leases, deterministic pressure planning, and exact confirmed deletion for Hostwright-owned unreferenced local content; it does not broaden any registry or unmanaged-content deletion authority.

## Image Signature Verification Boundary

Cosign is an explicit verifier dependency, not a credentialed registry client. Hostwright accepts only a current-user- or root-owned immutable executable, requires cosign v3.0.6 or newer within major version 3 on Darwin ARM64, checks executable identity before and during work, and records the executable version and SHA-256. Registry credentials, tokens, usernames, helper output, and environment secrets never enter cosign argv, stdin, output, durable intent, or diagnostics.

The verifier receives the exact subject manifest on stdin and private temporary paths for verified bundle bytes and copied trust material. Keyed authorities use an exact public key. Keyless authorities additionally require exact certificate identity, exact HTTPS OIDC issuer, and an explicit Sigstore TrustedRoot JSON document. Thresholds count distinct active authorities only; expired, not-yet-valid, or revoked authorities do not count.

Mutation stdout is never trust state. A successful record binds the exact descriptor digest, policy/material SHA-256, Gate 6 discovery UUID and graph SHA-256, trusted-root digest, matched authority IDs, threshold, verifier identity, and timestamp. Lifecycle preflight reloads and verifies the graph and cached subject bytes. Exceptions require a strict external approval record and are exact, time-bounded, revocable, audited, and plan-bound. Missing, changed, incomplete, expired, or ambiguous evidence fails before runtime mutation.

## Image SBOM Boundary

SBOM input is untrusted. Parsing rejects duplicate JSON fields, unsupported specification versions, excessive bytes, depth, components, strings, licenses, hashes, and duplicate component identities. Image binding is accepted only from the exact SHA-256 checksum/hash in the document. OCI artifact manifests, documents, subjects, annotations, and optional provenance identity pairs are digest-verified from a complete Gate 6 graph before immutable schema-v11 persistence and again before query, export, lifecycle execution, or recovery.

Archive generation opens one owned regular non-symlink OCI tar, rejects traversal, links, unsafe entry types, duplicates, malformed headers, size/digest drift, and ambiguous subject matches, and scans only bounded Alpine and Debian package databases through the secure subprocess boundary. Cancellation is checked while indexing and reading and terminates the bounded extractor process group. Temporary layer copies and failed export outputs use exact-path cleanup only.

Credentials are not accepted by SBOM CLI or Control fields and never enter generator argv, document metadata, durable intent, state evidence, progress, errors, diagnostics, or provenance. Gate 8 does not claim that a package inventory is vulnerability-free, that declared licenses are legally complete, or that a referenced provenance artifact is valid.

## Image Vulnerability Policy Boundary

Vulnerability reports are untrusted input. Hostwright accepts only one bounded versioned JSON contract with duplicate and unknown fields rejected, normalized finding identities, exact SHA-256 image/report/referrer binding, coherent database and generation timestamps, and one complete digest-verified Gate 6 graph. Report bytes must have exact Sigstore evidence that passes the manifest's image-signature policy; an image signature is not inferred to sign a report.

Policy selectors are deterministic and ANDed. A matching known finding always blocks unless an exact unexpired manifest allowlist entry applies. Fail-open is restricted to configured stale-database or unavailable-report cases and never suppresses a known matching finding. Decisions record freshness, data age, candidate/allowlisted/blocking findings, reason codes, policy hashes, and immutable report identity. Lifecycle and recovery recompute current freshness and finding disposition before effects.

Exception approvals are external bounded JSON records. They bind one prior blocked decision ID and digest, exact image/report/referrer, vulnerability and signature policy hashes, database identity/version, and blocked-findings digest. They are accepted only during their approval/expiry window, are revocable, and cannot authorize changed evidence. Referrer cleanup refuses immutable vulnerability-report references.

Credentials are not accepted by vulnerability CLI or Control fields and never enter cosign argv, report data, durable intent, decisions, events, diagnostics, or build provenance. Gate 9 evaluates supplied signed reports; it does not run or update a vulnerability scanner/database.

## Image Build Provenance Boundary

Build records, OCI archives, DSSE envelopes, public keys, and cached referrer graphs are untrusted input. Record parsing is byte-, depth-, collection-, and string-bounded; duplicate and unknown fields fail closed. The exact SHA-256 OCI manifest/index named by the selected service must be present in the archive. Source, dependency, and material identities accept only bounded credential-free HTTPS or URN values and reject user information, query strings, fragments, filesystem paths, traversal, or conflicting digests.

Generation emits an in-toto Statement v1 with the SLSA provenance v1 predicate and binds the exact image, builder identity/version, build type, invocation UUID, source and dependency materials, digest-only command model, allowlisted environment-variable names, network policy, timestamps, output, and reproducibility result. It never records native argv, environment values, secret values, auth material, host paths, mutation stdout, or undeclared metadata. The Ed25519 private key is resolved only at the signing boundary from an exact workload-authorized typed secret reference; state stores only the reference digest and never the reference or key bytes.

Verification re-observes one complete Gate 6 graph and requires the exact provenance referrer, subject, DSSE payload type, statement and envelope digests, signature, active signer material, builder, build type, material set, age, and optional reproducibility proof. Immutable schema-v14 evidence is not treated as current by itself: status, lifecycle execution, and recovery reload and digest-verify the graph and current manifest policy material before effects. Cancellation leaves a fenced interrupted group, recovery requires the exact plan and signing-reference digest, rollback never deletes registry content, and exact referrer cleanup refuses any immutable provenance reference.

Gate 10 does not inspect source repositories, run a build, establish a remote builder identity, infer reproducibility, sign through registry credentials, or claim SLSA conformance beyond the strict provenance v1 statement contract and policy checks implemented here.

## Network Exposure

Legacy `"host:container"` mappings still canonicalize to `127.0.0.1` TCP publication by default. Structured Phase 07 networking adds explicit localhost/LAN/public policy, certificates, peer identity, and exact cleanup. Broad binds remain blocked unless the requested exposure policy, interface, CIDR, authentication mode, provider capability, and confirmation path all match the qualified contract.

## Accelerator Boundary

Apple GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator helpers, host accelerator device exposure, and accelerator-aware scheduling are not implemented in current core scope.

Phase 10 implements a host-native accelerator service only with a threat model, mutual workload authentication, IPC boundary, quotas, cancellation, redaction/audit, cleanup, and policy gates. Private or undocumented accelerator interfaces remain rejected.

## Unsupported Security-Sensitive Scope

The current development build does not yet include the following. Their v0.0.2 implementations are owned by Phases 02–15; this list is a present-tense safety boundary, not a non-goal list:

- privileged helper;
- supported/qualified installer channel or launch agent;
- daemon mutation outside the shared local lifecycle saga or without exact ownership and fencing;
- arbitrary DNS mutation or unmanaged tunnel management;
- cloud control plane;
- Kubernetes, CRI, Docker API, or Docker Compose compatibility;
- GPU/ANE scheduling, Metal/Core ML/MLX/PyTorch MPS container support, host-native accelerator helpers, or host accelerator device exposure;
- generic plugin loader, capability invocation, remote plugin registry, binary plugin distribution, or untrusted extension execution;
- cloud team service, central remote control, hosted audit log, user tracking, enterprise support workflow, or remote policy distribution;
- credentialed passing Developer ID/notarization/stapling/Gatekeeper evidence, published signed installer verification, vendor-tap availability, dependency/image SBOM claims, or vulnerability scanning;
- external telemetry, hosted diagnostics, or automatic diagnostic upload.
- unredacted OSLog fields, OSLog-derived operation authority, or automatic unified-log export.
- support SLA, enterprise support workflow, enforced CODEOWNERS, or branch-protection policy.
