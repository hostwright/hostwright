# ADR 0005: No CRI First

Status: Accepted

## Decision

Do not implement a CRI shim in the first supported release.

## Rationale

The first supported release is a local single-host control plane, not a Kubernetes node integration layer.

## Consequences

CRI, PodSandbox compatibility, kubelet replacement behavior, and Kubernetes scheduler behavior are out of scope.

