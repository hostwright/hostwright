# Phase 18 Devlog: Rollback And Partial Failure Recovery

## Scope

Phase 18 adds recoverability metadata for the existing single-action apply path. It does not add automatic rollback, inverse runtime mutation, broad lifecycle management, multi-action apply, unattended daemon mutation, image cleanup, volume cleanup, unmanaged cleanup, release tags, or GitHub Releases.

## Changes

- Added SQLite schema v4 for operation recovery groups and operation group steps.
- Added operation group acquisition before apply runtime mutation.
- Added stale active operation group lease interruption before reacquire.
- Added forward runtime step records and rollback-unsupported step records.
- Added succeeded, failed, and interrupted operation group completion states.
- Added redacted manual recovery hints and checkpoint metadata.
- Added `hostwright recovery --state-db <path> [--project <name>] [--output text|json]`.
- Added legacy managed-restart recovery rendering when no Phase 18 operation group exists for the same operation.

## Verification Focus

- Operation group acquisition is idempotent while an operation is active.
- Expired active operation groups are marked interrupted before a new operation group is acquired.
- Failed and interrupted apply attempts preserve manual recovery guidance.
- Managed restart stop-success/start-failure cases record the completed stop step.
- Recovery output is read-only and redacted.
- Rollback remains explicitly unavailable unless a future phase proves a safe inverse operation.
