# ADR 0006: No Full Compose Parity

Status: Superseded by ADR 0009 and the v0.0.2 Phase 13 roadmap

## Decision

The earlier release retained a narrow import-only subset. This is historical context, not a current non-goal.

## Rationale

Hostwright needs a narrow manifest model for desired-state control. Full Compose parity would import a large compatibility surface before the runtime, state, and reconciliation foundations are proven.

## Consequences

Manifest v2 stays a Hostwright contract. Phase 13 separately implements Compose import, execution, update, export, and loss reporting; every unsupported platform-specific field must return a stable explicit result rather than being silently dropped.
