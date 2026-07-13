# ADR 0005: No CRI First

Status: Superseded by ADR 0009 and the v0.0.2 Phase 12 roadmap

## Decision

The earlier release did not implement a CRI shim. This is historical context, not a current non-goal.

## Rationale

The first supported release is a local single-host control plane, not a Kubernetes node integration layer.

## Consequences

Phase 12 implements CRI v1 through a real Hostwright pod-sandbox VM and guest-agent boundary, plus CNI, CSI, kubelet, Helm, and conformance work. Hostwright will not claim pod semantics by pretending independent per-container VMs share Linux namespaces.
