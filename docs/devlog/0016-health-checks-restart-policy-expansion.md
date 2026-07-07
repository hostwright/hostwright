# Phase 16: Health Checks And Restart Policy Expansion

## Summary

Phase 16 adds in-process loopback health checks and persisted restart policy state without adding unattended daemon mutation.

## What Changed

- Added desired runtime health-check specs mapped from `health.command` and `health.interval`.
- Added bounded health execution through allowlisted command-shape parsing: local HTTP(S) `curl`-shaped checks, `wget --spider`-shaped checks, and argument-free `true`/`false`. Hostwright does not execute host `curl` or `wget` binaries.
- Added SQLite schema v2 tables for append-only health results and current restart policy state.
- Added restart-state-aware planning for max attempts, backoff, preexisting operator hold, manual-disable, and crash-loop blocking.
- Wired `hostwrightd` to persist redacted health results, restart policy state, and health/restart events while continuing to avoid `RuntimeAdapter.execute`.
- Wired `hostwright apply` to honor persisted restart-state blocking before the existing narrow managed-start path and reset the attempt budget after successful managed starts.

## Verification

- `swift build`
- `swift test list`
- `swift test` — 141 XCTest tests

## Boundaries

- No broad restart command.
- No unattended daemon restart loop.
- No container `exec` health checks.
- No stop/delete behavior beyond existing approved paths.
- No release tags or GitHub Releases.
