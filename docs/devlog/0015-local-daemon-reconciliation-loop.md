# Phase 15: Local Daemon Reconciliation Loop

## Summary

Phase 15 turns `hostwrightd` from a scaffold into a foreground development loop that observes, plans, and records reconciliation attempts with explicit paths.

## What Changed

- Added `HostwrightDaemonCore` for testable daemon loop behavior.
- Added `hostwrightd --foreground --config <path> --state-db <path>`.
- Added cadence, deterministic jitter, repeated-error backoff, shutdown token, and sleep/wake resume handling.
- Added a non-blocking single-instance file lock.
- Persisted daemon lifecycle, success, failure, backoff, sleep/wake, and stopped events.
- Persisted daemon reconciliation operation records.

## Rejected Paths

- No launch agent installation.
- No default config or state database path.
- No unattended runtime mutation.
- No privileged helper.
- No restart loop enforcement.
- No image, volume, unmanaged, or broad cleanup.

## Verification

Phase 15 adds XCTest coverage for daemon argument parsing, foreground loop persistence, no `RuntimeAdapter.execute` call, repeated-error backoff with jitter, shutdown handling, single-instance lock refusal, and sleep/wake resume event persistence. Full local verification is required before PR.
