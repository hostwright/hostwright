# Phase 12: CLI And Developer Workflow Hardening

Phase 12 makes the CLI easier to use from scripts and tests without widening Hostwright's runtime behavior.

## What Changed

- Added stable process exit categories for usage, validation, state unavailable, runtime unavailable, confirmation mismatch, unsafe operation, and partial failure.
- Added `--output text|json` for `plan`, `status`, `events`, and `doctor`.
- Added JSON error envelopes when a command requests JSON mode and the CLI can classify the failure.
- Expanded help and reference docs with output-mode examples and explicit state-path reminders.
- Added XCTest coverage for JSON plan/status/events/doctor output, JSON errors, output-mode parsing, event ordering, exit codes, and redaction.

## What Stayed Out

- No new runtime mutation.
- No default state database path.
- No shell completion installer or shell-profile mutation.
- No background behavior, release tags, or GitHub Releases.
- No Kubernetes, CRI, Docker API, Compose, DNS, tunnels, cloud, GPU, ANE, GUI, image cleanup, volume cleanup, or unmanaged cleanup work.

## Verification

Required Phase 12 gate:

```bash
swift build
swift test list || swift test --list-tests
swift test
scripts/grep-orchard.sh .
scripts/test.sh
scripts/lint.sh
```
