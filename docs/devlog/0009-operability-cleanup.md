# Phase 9: Operability, Restart, Logs, And Safe Cleanup

## Goal

Add practical local operation features after create-only apply: live status, bounded logs, event rendering, one restart-policy-gated managed start, and ownership-based cleanup.

## What Changed

- Added `hostwright status [path] --state-db <path>`.
- Added `hostwright logs <service> [path] [--tail <n>] [--state-db <path>]`.
- Added `hostwright events --state-db <path> [--project <name>]`.
- Added `hostwright cleanup [path] --state-db <path> --dry-run`.
- Added `hostwright cleanup [path] --state-db <path> --confirm-cleanup <token>`.
- Extended `hostwright apply` to execute exactly one `startManagedService` action when restart policy allows it.
- Added RuntimeAdapter log support and strict start/delete command classification.
- Added XCTest coverage for status, logs, events, cleanup, managed start, and forbidden command rejection.

## Safety Boundaries

- Runtime behavior still goes through `RuntimeAdapter`.
- `apply` still requires explicit `--state-db` and matching `--confirm-plan`.
- `apply` still executes exactly one action.
- Cleanup requires dry-run, ownership records, live observation, exact resource IDs, non-running lifecycle, and matching confirmation token.
- Cleanup never deletes images, volumes, networks, unmanaged containers, or broad resource sets.
- Logs do not follow, attach, exec, or run interactively.

## Gaps

- No daemon loop.
- No restart backoff loop.
- No stop/restart command.
- No image replacement.
- No port or mount mutation.
- No image cleanup.
- No volume cleanup.
- No DNS, tunnels, cloud, GPU/ANE, or privileged helper behavior.
- No production readiness claim.

## Verification

- `swift build`
- `swift test list`
- `swift test`

At the time this devlog was written, `swift test list` listed 82 XCTest cases and `swift test` executed 82 tests with 0 failures.

## Live Proof

The Phase 9 live proof used one disposable Hostwright-owned container:

- manifest project: `phase9proof`;
- service: `web`;
- image: existing local `docker.io/library/python:alpine`;
- command: `python3 --version`;
- container: `hostwright-phase9proof-web`.

The proof verified:

- create through `hostwright apply`;
- live `status --state-db`;
- managed start through `hostwright apply`;
- bounded `logs --tail 20`, returning `Python 3.14.6`;
- event ledger rendering;
- cleanup dry-run token `cleanup-8ecbbdd9ef3cdd74`;
- exact cleanup through `hostwright cleanup --confirm-cleanup`;
- no proof container remained after cleanup.

## Next Action

Phase 10 should harden the first supported release contract: docs, examples, compatibility checks, release review, benchmark baseline, CI review, and final safety audit.
