# ADR 0006: No Full Compose Parity

Status: Accepted

## Decision

Do not chase full Docker Compose parity in the first supported release.

## Rationale

Hostwright needs a narrow manifest model for desired-state control. Full Compose parity would import a large compatibility surface before the runtime, state, and reconciliation foundations are proven.

## Consequences

The `hostwright.yaml` schema starts small and explicit.

