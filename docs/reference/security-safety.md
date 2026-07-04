# Security And Safety Notes

Hostwright `v0.1.0-alpha.1` is not production ready.

## Runtime Boundary

All Apple container runtime behavior must go through `RuntimeAdapter`.

The CLI, reconciler, state store, health checks, networking, and observability modules must not shell out directly to Apple container for runtime behavior.

## Mutation Boundaries

Supported mutation is intentionally narrow:

- one create-missing-service action after explicit plan hash confirmation;
- one restart-policy-allowed managed start action;
- exact cleanup-eligible managed container delete after dry-run token confirmation.

Hostwright does not implement broad lifecycle management, stop commands, restart commands, image replacement, mount mutation, port mutation, rollback, or daemon reconciliation.

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

Cleanup does not delete images, volumes, networks, Apple builder resources, base images, or unmanaged containers.

## Secrets And Redaction

Hostwright redacts known secret-like values in command output, logs, state payloads, events, and failure messages.

Redaction is heuristic. Users should not place real credentials in manifests, logs, examples, fixtures, or issue reports.

## Unsupported Security-Sensitive Scope

This alpha does not include:

- privileged helper;
- installer or launch agent;
- daemon reconciliation loop;
- DNS or tunnel management;
- cloud control plane;
- Kubernetes, CRI, Docker API, or Docker Compose compatibility;
- GPU/ANE scheduling or Metal/Core ML/MLX container support;
- signing, notarization, SBOM, or binary provenance.

