# Devlog 0004: RuntimeAdapter Contract Infrastructure

## Goal

Harden the RuntimeAdapter boundary before any Apple container observation begins.

## What Changed

- Added typed runtime models for service identity, desired services, observed services, lifecycle state, health state, ports, mounts, environment values, events, capabilities, and adapter metadata.
- Expanded `RuntimeAdapter` to include metadata, capabilities, observation, planning, and future mutation hooks.
- Added `MockRuntimeAdapter` for deterministic tests.
- Added runtime command specs, command results, command classification, timeout model, process-runner protocol, fake process runner, and redaction policy.
- Updated runtime and reconciler smoke checks for the new models.
- Updated runtime adapter docs, requirements, acceptance matrix, limitations, build status, and maintainer notes.

## What Phase 4 Does Not Do

- No Apple container command is called.
- No Apple container observation is implemented.
- No Apple container mutation is implemented.
- No `apply` command is implemented.
- No SQLite state is implemented.
- No cleanup, restart policy execution, DNS, tunnel, cloud, GPU/ANE, privileged helper, or installer behavior is implemented.

## Why This Design

Runtime behavior is the highest-risk boundary in Hostwright. Phase 4 makes the boundary explicit and testable without touching the runtime. That lets Phase 5 add read-only observation later with clear contracts for command classification, timeout, output capture, cancellation, and redaction.

## Verification

Run:

```bash
swift build
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

## Risks

- The process-runner abstraction could grow too large before real Apple container behavior is observed.
- Fake tests can prove boundaries but not Apple container semantics.
- Redaction rules are conservative but not complete; they must be expanded when real output formats are known.
- Smoke/precondition tests remain weaker than XCTest or Swift Testing.

## Next Action

Phase 5 should implement read-only Apple container observation behind `RuntimeAdapter`, using fixture-backed tests first and live local checks only after command semantics are reviewed.
