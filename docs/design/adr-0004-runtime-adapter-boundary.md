# ADR 0004: Runtime Adapter Boundary

Status: Accepted

## Decision

All runtime operations must go through `RuntimeAdapter`.

## Rationale

This isolates runtime assumptions, prevents shell-command sprawl, and makes future Apple container integration testable.

## Consequences

CLI, daemon, state, reconciler, health, networking, and observability code must not directly call runtime commands.

