# ADR 0003: macOS 26 First

Status: Accepted

## Decision

Hostwright targets macOS 26+ first.

## Rationale

The first supported release should avoid misleading users on older macOS versions where Apple container behavior or networking behavior may not match the project assumptions.

## Consequences

`Package.swift` declares macOS 26. Runtime compatibility checks must report unsupported platforms clearly.

