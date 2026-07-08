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

Operation recovery records are audit and recovery guidance only. They record checkpoints, failed/completed steps, and rollback-unavailable status; they do not authorize automatic inverse runtime operations.

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

Hostwright does not use the live macOS Keychain by default in this phase. The default CLI secret store fails closed before mutation, and tests use a fake Keychain backend. A future live Keychain backend must be separately approved, noninteractive, and fail cleanly instead of presenting authentication UI.

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

## Unsupported Security-Sensitive Scope

This alpha does not include:

- privileged helper;
- installer or launch agent;
- unattended daemon mutation;
- DNS or tunnel management;
- cloud control plane;
- Kubernetes, CRI, Docker API, or Docker Compose compatibility;
- GPU/ANE scheduling or Metal/Core ML/MLX container support;
- signing, notarization, signature verification, SBOM generation/validation, vulnerability scanning, or binary provenance.
- external telemetry, hosted diagnostics, or automatic diagnostic upload.
