# Phase 17: Managed Restart

Phase 17 adds one narrow managed restart path without adding broad lifecycle management.

## What changed

- Reconciliation can plan `restartManagedService` for an unhealthy running service when restart policy state allows managed recovery.
- `hostwright apply` requires an explicit state database path, current plan hash, exact Hostwright ownership, live observed running state, and a fresh persisted unhealthy health result before mutation.
- Runtime execution goes through `RuntimeAdapter` as an internal `container stop <id>` followed by `container start <id>` for the exact Hostwright-managed container identifier.
- SQLite schema v3 adds append-only restart recovery records with redacted manual recovery hints and completed-step metadata.
- Apply records operation intent, success/failure operation status, restart recovery records, restart policy state, and redacted events for managed restart attempts.

## Safety boundary

Phase 17 does not add a user-facing stop command, user-facing restart command, daemon-enforced restart loop, image replacement, image cleanup, volume cleanup, unmanaged cleanup, release tag, or GitHub Release.

## Verification

- Managed restart planner gates are covered by reconciler XCTest cases.
- Ownership refusal, fresh/stale persisted health handling, status/apply plan-hash parity, successful restart, failed restart recovery hints, backoff, partial stop-success/start-failure records, and redaction are covered by CLI XCTest cases.
- Internal stop-then-start command policy, partial start-failure reporting, and fake-runner sequencing are covered by runtime XCTest cases.
- Restart recovery persistence is covered by state XCTest cases.
