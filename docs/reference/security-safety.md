# Security And Safety Notes

Hostwright `0.0.2-dev` is not production ready. The active release target is `v0.0.2`; security-sensitive features remain unsupported until their owning roadmap issue has clean security and runtime evidence.

The v0.0.2 program turns earlier unsupported security-sensitive scope into explicit implementation work for trusted install, secrets, supply chain, storage, networking, tunnels, autonomous mutation, identity/RBAC/admission/audit, plugins, clusters, interoperability, GUI/MDM, and optional cloud control. This does not make those capabilities supported today. The exact current state is emitted by `hostwright capabilities --json` and the implementation/verification ownership is in the [v0.0.2 plan](../roadmap/v0.0.2/IMPLEMENTATION_PLAN.md).

## Runtime Boundary

All Apple container runtime behavior must go through `RuntimeAdapter`.

The CLI, reconciler, state store, health checks, networking, and observability modules must not shell out directly to Apple container for runtime behavior.

Production subprocess execution uses one shared bounded implementation. It passes arguments directly without a shell, resolves named tools only through root-owned path chains, constructs a minimal environment instead of inheriting the parent, pins the working directory by file descriptor, closes unrelated descriptors, verifies executable identity before continuing a suspended child, bounds stdin/stdout/stderr and time, distinguishes cancellation from timeout, and cleans the inherited session process group before releasing its PID fence. See [Secure Process Execution](process-execution.md) for the executable contract, migration, recovery, and test matrix.

## Mutation Boundaries

Supported mutation is intentionally narrow:

- one create-missing-service action after explicit plan hash confirmation;
- one restart-policy-allowed managed start action;
- one restart-policy-allowed managed restart action for an exact Hostwright-owned running/unhealthy service;
- exact cleanup-eligible managed container delete after dry-run token confirmation.
- explicitly confirmed benchmark create/start/exact-delete for unique versioned Hostwright-owned resources using a pre-existing local image and bounded process.

Hostwright does not implement broad lifecycle management, user-facing stop commands, user-facing restart commands, image replacement, mount mutation, port mutation, automatic rollback, or unattended daemon mutation.

Restart policy state can block the narrow managed-start and managed-restart paths through backoff, preexisting operator hold state, manual-disable from `restart.policy: no`, and crash-loop protection. Managed restart also requires exact Hostwright ownership, live observed running state, a fresh persisted unhealthy health result from the selected state database, operation ledger entries, restart recovery records, and operation recovery group records. The foreground daemon records restart state but does not start or restart services by itself.

New runtime resources use collision-resistant v2 identifiers and exact labels for managed state, identity version, project, service, optional instance, and resource identifier. Mutation plans retain the exact observed identifier. State-backed legacy identifiers remain readable for upgrade continuity, but labels or ownership records may not be inferred from a Hostwright-looking name.

Operation recovery records are audit and recovery guidance only. They record checkpoints, failed/completed steps, and rollback-unavailable status; they do not authorize automatic inverse runtime operations.

## Local State Boundary

State-backed commands default to the per-user Application Support database. An explicit CLI override wins over `HOSTWRIGHT_STATE_DB`, which wins over the default. Before SQLite or daemon-lock use, Hostwright enforces absolute normalized paths, safe root/current-user parent ownership, no group/other-writable or access-granting-ACL parents, no user-controlled directory symlinks, exact `0700` owned directories, and current-user-owned regular single-link `0600` sensitive files without special bits or access-granting ACL entries. Creation explicitly applies those modes instead of depending on the caller's `umask`.

The default-path legacy migration accepts only a compatible checksum-valid Hostwright SQLite ledger. It refuses destination conflicts, SQLite sidecars, active writers, cross-filesystem moves, identity changes, and ambiguous crash state. A synchronized journal makes the one atomic rename resumable; unknown `~/.hostwright` files are never moved or removed.

`hostwright paths` exposes origin, readiness, effective lock path, pending-journal state, and policy failures without creating state. `hostwright doctor` validates existing state plus prospective parent/layout safety before first use. See [Local Paths, Permissions, and Legacy Migration](local-paths.md) for the full security and recovery contract.

These controls prevent Hostwright from crossing filesystem trust boundaries. They do not sandbox another process already running under the same macOS account.

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

Phase 35 added the fail-closed local unsigned distribution lane. Phase 02 retains it and adds a separate trusted-release path. `hostwright-dist` accepts explicit paths only, rejects dirty clean-build inputs, validates all three ARM64 executables by execution and Mach-O slice, creates exact manifests, binds SHA-256/SPDX/provenance sidecars, rejects hidden/link/path/mode/digest drift before install, and exercises atomic replacement with reverse-order rollback under a temporary prefix.

Lifecycle mutation is restricted to checksum-verified installer-owned files beneath an explicit `hostwright-dist-*` temporary directory. Update and uninstall refuse modified owned files. Uninstall removes only exact owned files and installer-created empty directories, then compares unrelated prefix content with its initial snapshot.

The trusted path requires exact non-ambiguous Developer ID Application and Installer fingerprints from one team, a preconfigured `notarytool` Keychain profile, two byte-identical clean payload builds, hardened-runtime signatures, Apple acceptance, online ZIP tickets, a stapled package ticket, Gatekeeper acceptance, exact payload/package inventories, per-artifact SPDX, source/digest-bound provenance, sorted checksums, exact single-signer CMS verification, and final independent extraction/expansion verification. Secrets are not accepted in argv. SIGINT/SIGTERM and explicit cancellation use the same bounded process-tree cleanup path.

The protected release workflow separates build/sign, attestation, and publication. Repository code runs with read-only contents permission and no OIDC or publication authority. A GitHub-hosted no-checkout job receives only OIDC/attestation authority for the retained signed files. Only the final no-checkout publication job receives contents write permission. Actions are commit-pinned, tags are immutable, published bytes are downloaded and compared, GitHub attestations are verified, and a failure after tag creation removes the release/tag.

Current public Hostwright releases nevertheless remain source-only. Local unsigned artifacts are non-publishable, and no trusted artifact is called supported until real Developer ID identities, notarization, Gatekeeper, signed `.pkg`, system lifecycle, vendor-tap publication/install, and clean-Mac evidence pass. No usable identities or release variables are configured on the reviewed machine/repository, and the vendor tap does not yet exist.

## Control Surface Boundary

Future GUI or local control surfaces must use Hostwright command contracts or the explicit `hostwright-control` subset while preserving the same validation, redaction, ownership, selected-state-path, and RuntimeAdapter boundaries. Mutation remains outside the current one-shot API, so plan-hash confirmation and cleanup-token authority are not exposed through it.

They must not call Apple container, SQLite, `RuntimeAdapter`, state migrations, cleanup deletion, health execution, or diagnostics upload directly. `hostwright-control` delegates only plan, status, events, recovery, and doctor to existing CLI contracts, requires launch-fixed absolute paths, rejects request-selected paths and mutation names, bounds one stdin request and one stdout response, and then exits. It adds no GUI code, daemon API, listener, web dashboard, hosted diagnostics, telemetry upload, or remote control.

Configured files must be existing regular non-symlink files with safe ownership, no group/world write permission, and no set-ID bits. This check reduces accidental or cross-account substitution; it is not an operating-system sandbox or a guarantee against the invoking account replacing its own files. State-backed status can perform compatible path/schema migration, observation snapshot, and audit writes to the launch-configured database or the secure default when no state override is configured. No API operation mutates runtime.

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

## Secrets And Redaction

Hostwright keeps execution environment values separate from display and persistence values. Runtime command construction receives the manifest value, while command output, logs, state payloads, events, plan output, and failure messages use redacted values.

Plaintext credential-like environment keys in `env` are rejected. Use `secretEnv` with `keychain://<service>/<account>` references for local secret values. The reference is not a secret value, but Hostwright still redacts keychain reference labels from state, diagnostics, plans, and errors because labels can reveal local account context.

After an explicitly confirmed create resolves a `secretEnv` reference, Hostwright transports the value to the Apple CLI only through its bounded child environment and passes `--env KEY` so the CLI inherits it. The resolved value is not placed in argv or an environment file. Runtime result specs, output, errors, state, events, and diagnostics apply exact-value redaction before leaving the execution boundary.

Hostwright does not use the live macOS Keychain by default in this phase. The default CLI secret store fails closed before mutation, and unit-contract tests inject a test-only in-memory secret store. The opt-in read-only `MacOSKeychainSecretStore` uses an interaction-disabled authentication context, excludes synchronizable items, and is covered by live add/read/exact-delete/post-delete tests. Production Hostwright code does not create, update, or delete Keychain items.

Redaction is heuristic. Users should not place plaintext credentials in manifests, logs, examples, fixtures, or issue reports.

Health check stdout, stderr, command payloads, events, operation recovery hints, operation recovery metadata, and persisted result metadata are redacted before display or storage.

Diagnostic bundles are local-only JSON exports. They redact known secret-like values before writing, use exclusive `0600` creation, refuse to overwrite an existing file, and are never uploaded by Hostwright. They can still contain sensitive local context such as project names, service names, file paths, hostnames, resource identifiers, event timing, and redacted-but-contextual metadata. Review bundles before sharing.

## Untrusted Manifest Input

Treat `hostwright.yaml` files from third parties as untrusted input. Hostwright validates a restricted manifest subset and rejects unsupported YAML, Kubernetes-style fields, Compose-style fields, unknown service fields, unsupported manifest versions, unsafe host-root or parent-traversal mount sources, and unsafe environment keys before planning or mutation.

`hostwright validate` and `hostwright plan` are non-mutating review gates. Operators should still inspect image names, port publishes, environment values, volume paths, and loopback health probe commands before running any confirmed `apply` or daemon loop.

Secret references do not make third-party manifests trusted. A manifest can still point at local secret labels, images, paths, and ports that the operator must review before confirmed mutation.

## Image Trust Boundary

Manifest `imagePolicy: require-digest` can require service image references to use `@sha256:<64 lowercase hex characters>` before planning or mutation. This is local string validation only. It does not contact registries, resolve mutable tags, pull images, verify cosign/Sigstore signatures, inspect OCI referrers, generate or validate SBOMs, run vulnerability scanners, or prove build provenance.

Operators should still decide which registries, image publishers, digests, and local images they trust. A digest-pinned reference is a content identifier input to Hostwright, not a complete supply-chain trust guarantee.

## Network Exposure

The currently executable Manifest v2 subset uses `"host:container"` syntax and does not expose a bind-address field. Hostwright-created Apple container publishes use explicit `127.0.0.1:host:container` bindings by default. Broad bind addresses such as `0.0.0.0` and `::` remain blocked when represented in runtime desired state, and observed non-target services occupying the same host port block mutation planning when live observation is available. Phase 07 may expand this only with explicit LAN/ingress policy, identity, and cleanup.

## Accelerator Boundary

Apple GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator helpers, host accelerator device exposure, and accelerator-aware scheduling are not implemented in current core scope.

Phase 10 implements a host-native accelerator service only with a threat model, mutual workload authentication, IPC boundary, quotas, cancellation, redaction/audit, cleanup, and policy gates. Private or undocumented accelerator interfaces remain rejected.

## Unsupported Security-Sensitive Scope

The current development build does not yet include the following. Their v0.0.2 implementations are owned by Phases 02–15; this list is a present-tense safety boundary, not a non-goal list:

- privileged helper;
- installer or launch agent;
- unattended daemon mutation;
- DNS or tunnel management;
- cloud control plane;
- Kubernetes, CRI, Docker API, or Docker Compose compatibility;
- GPU/ANE scheduling, Metal/Core ML/MLX/PyTorch MPS container support, host-native accelerator helpers, or host accelerator device exposure;
- generic plugin loader, capability invocation, remote plugin registry, binary plugin distribution, or untrusted extension execution;
- cloud team service, central remote control, hosted audit log, user tracking, enterprise support workflow, or remote policy distribution;
- credentialed passing Developer ID/notarization/stapling/Gatekeeper evidence, published signed installer verification, vendor-tap availability, dependency/image SBOM claims, or vulnerability scanning;
- external telemetry, hosted diagnostics, or automatic diagnostic upload.
- support SLA, enterprise support workflow, enforced CODEOWNERS, or branch-protection policy.
