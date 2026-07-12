# Security And Safety Notes

Hostwright `v0.1.0-alpha.1` is not production ready.

## Runtime Boundary

All Apple container runtime behavior must go through `RuntimeAdapter`.

The CLI, reconciler, state store, health checks, networking, and observability modules must not shell out directly to Apple container for runtime behavior.

## Mutation Boundaries

Supported mutation is intentionally narrow:

- one create-missing-service action after explicit plan hash confirmation;
- one restart-policy-allowed managed start action;
- one restart-policy-allowed managed restart action for an exact Hostwright-owned running/unhealthy service;
- exact cleanup-eligible managed container delete after dry-run token confirmation.

Hostwright does not implement broad lifecycle management, user-facing stop commands, user-facing restart commands, image replacement, mount mutation, port mutation, automatic rollback, or unattended daemon mutation.

Restart policy state can block the narrow managed-start and managed-restart paths through backoff, preexisting operator hold state, manual-disable from `restart.policy: no`, and crash-loop protection. Managed restart also requires exact Hostwright ownership, live observed running state, a fresh persisted unhealthy health result from the explicit state database, operation ledger entries, restart recovery records, and operation recovery group records. The foreground daemon records restart state but does not start or restart services by itself.

New runtime resources use collision-resistant v2 identifiers and exact labels for managed state, identity version, project, service, optional instance, and resource identifier. Mutation plans retain the exact observed identifier. State-backed legacy identifiers remain readable for upgrade continuity, but labels or ownership records may not be inferred from a Hostwright-looking name.

Operation recovery records are audit and recovery guidance only. They record checkpoints, failed/completed steps, and rollback-unavailable status; they do not authorize automatic inverse runtime operations.

## Policy Boundary

Policy evaluation is local, deterministic, and non-mutating. `HostwrightPolicy` explains allow/warning/blocker decisions for planner safety checks, cleanup classification, image policy, env/secrets, lifecycle requests, secure exposure requests, untrusted manifests, accelerator placeholders, and extension declarations.

Policy decisions do not execute Apple container, write SQLite, contact registries, upload telemetry, configure DNS, create tunnels, distribute team policy, or apply automatic overrides. Unknown, ambiguous, or high-risk settings remain blocked unless a later reviewed implementation adds a narrower explicit gate.

## Team Workflow Boundary

Team workflow support is explicit local profile and approval data only. Hostwright accepts strict-only profile requirements and exact profile/manifest/plan-bound approvals; it does not provide policy weakening, a cloud team service, central remote control, hosted audit log, user tracking, enterprise support workflow, or remote policy distribution.

Team profiles cannot bypass plan-hash confirmation, cleanup tokens, ownership checks, redaction, explicit state paths, local-only diagnostics, or `RuntimeAdapter`. Approval records authorize only the exact bound apply or cleanup operation; they do not override hard-coded safety gates.

## Extension Boundary

Extension architecture is declaration-only in current core scope. Hostwright can evaluate typed extension declarations for identity, declaration API version, trust level, capabilities, and required boundaries, but it does not load, install, distribute, or execute plugins.

Built-in and reviewed-local non-mutating declarations can receive allow decisions only when they declare the required RuntimeAdapter, HostwrightState, local policy, redaction, audit, explicit-state-path, local-only/no-upload, confirmation, ownership, and no-runtime-mutation boundaries for the requested capability.

Third-party, untrusted, unsupported-version, empty, missing-boundary, runtime-mutation, state-write, networking-provider, tunnel-provider, secret-resolution, and accelerator extension declarations fail closed. Future extension implementations require a separate issue, threat model, tests, and maintainer approval.

## Governance Boundary

`GOVERNANCE.md`, `CONTRIBUTING.md`, and `SECURITY.md` define maintainer review triggers for dependencies, release artifacts, runtime mutation, state migrations, cleanup, secret handling, diagnostics, policy, networking, external compatibility, multi-host, accelerator, GUI, website, and public support claims.

These documents are process controls only. They do not add branch protection, CODEOWNERS enforcement, support SLAs, hosted diagnostics, telemetry upload, cloud services, or release artifacts.

## Release Distribution Boundary

Phase 35 defines a fail-closed distribution readiness gate. It records the artifact matrix, signing and notarization evidence, checksum, SBOM, provenance, installer, uninstaller, upgrade, downgrade, rollback, and package-channel requirements that must exist before binary or installer publication.

Current Hostwright releases remain source-only. The distribution gate does not create signed binaries, notarized artifacts, installer packages, launch agents, install scripts, SBOMs, provenance statements, Homebrew formulae, or package-channel support.

## Control Surface Boundary

Future GUI or local control surfaces must use Hostwright command contracts or a future explicit Hostwright API that preserves the same validation, redaction, plan-hash confirmation, cleanup token, ownership, explicit-state-path, and RuntimeAdapter gates.

They must not call Apple container, SQLite, `RuntimeAdapter`, state migrations, cleanup deletion, health execution, or diagnostics upload directly. Phase 21 documents this boundary only; it does not add GUI code, a daemon API, a web dashboard, hosted diagnostics, telemetry upload, or remote control.

## Cleanup Safety

Cleanup is destructive and requires all of these:

- explicit `--state-db`;
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

Hostwright does not use the live macOS Keychain by default in this phase. The default CLI secret store fails closed before mutation, and unit-contract tests inject a test-only in-memory secret store. The opt-in read-only `MacOSKeychainSecretStore` uses an interaction-disabled authentication context, excludes synchronizable items, and is covered by live add/read/exact-delete/post-delete tests. Production Hostwright code does not create, update, or delete Keychain items.

Redaction is heuristic. Users should not place plaintext credentials in manifests, logs, examples, fixtures, or issue reports.

Health check stdout, stderr, command payloads, events, operation recovery hints, operation recovery metadata, and persisted result metadata are redacted before display or storage.

Diagnostic bundles are local-only JSON exports. They redact known secret-like values before writing, refuse to overwrite an existing file, and are never uploaded by Hostwright. They can still contain sensitive local context such as project names, service names, file paths, hostnames, resource identifiers, event timing, and redacted-but-contextual metadata. Review bundles before sharing.

## Untrusted Manifest Input

Treat `hostwright.yaml` files from third parties as untrusted input. Hostwright validates a restricted manifest subset and rejects unsupported YAML, Kubernetes-style fields, Compose-style fields, unknown service fields, unsupported manifest versions, unsafe host-root or parent-traversal mount sources, and unsafe environment keys before planning or mutation.

`hostwright validate` and `hostwright plan` are non-mutating review gates. Operators should still inspect image names, port publishes, environment values, volume paths, and loopback health probe commands before running any confirmed `apply` or daemon loop.

Secret references do not make third-party manifests trusted. A manifest can still point at local secret labels, images, paths, and ports that the operator must review before confirmed mutation.

## Image Trust Boundary

Manifest `imagePolicy: require-digest` can require service image references to use `@sha256:<64 lowercase hex characters>` before planning or mutation. This is local string validation only. It does not contact registries, resolve mutable tags, pull images, verify cosign/Sigstore signatures, inspect OCI referrers, generate or validate SBOMs, run vulnerability scanners, or prove build provenance.

Operators should still decide which registries, image publishers, digests, and local images they trust. A digest-pinned reference is a content identifier input to Hostwright, not a complete supply-chain trust guarantee.

## Network Exposure

Manifest ports use `"host:container"` syntax in this alpha and do not expose a bind-address field. Hostwright-created Apple container publishes use explicit `127.0.0.1:host:container` bindings by default. Broad bind addresses such as `0.0.0.0` and `::` remain blocked when represented in runtime desired state, and observed non-target services occupying the same host port block mutation planning when live observation is available.

## Accelerator Boundary

Apple GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator helpers, host accelerator device exposure, and accelerator-aware scheduling are not implemented in current core scope.

Host-native accelerator helpers or services require a separate threat model, local auth design, IPC boundary, redaction and audit plan, cleanup model, policy gate, and maintainer approval before implementation. Private or undocumented accelerator interfaces are rejected.

## Unsupported Security-Sensitive Scope

This alpha does not include:

- privileged helper;
- installer or launch agent;
- unattended daemon mutation;
- DNS or tunnel management;
- cloud control plane;
- Kubernetes, CRI, Docker API, or Docker Compose compatibility;
- GPU/ANE scheduling, Metal/Core ML/MLX/PyTorch MPS container support, host-native accelerator helpers, or host accelerator device exposure;
- plugin loader, remote plugin registry, binary plugin distribution, or untrusted extension execution;
- cloud team service, central remote control, hosted audit log, user tracking, enterprise support workflow, or remote policy distribution;
- signing, notarization, signature verification, SBOM generation/validation, vulnerability scanning, or binary provenance.
- external telemetry, hosted diagnostics, or automatic diagnostic upload.
- support SLA, enterprise support workflow, enforced CODEOWNERS, or branch-protection policy.
