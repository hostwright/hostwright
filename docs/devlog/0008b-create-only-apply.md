# Devlog 0008B: Create-Only Apply Gate

## Goal

Add the first Hostwright runtime mutation path while keeping the scope limited to one confirmed create-missing-service action.

## What Changed

- Added `hostwright apply [path] --state-db <path> --confirm-plan <hash>`.
- Required explicit state database paths; no default or hidden state path was added.
- Recomputed the current plan before mutation and refused mismatched plan hashes.
- Persisted desired state, observed state, operation intent, and `apply.started` before runtime execution.
- Added success, failure, and ownership persistence after runtime execution.
- Added `AppleContainerApplyAdapter` behind `RuntimeAdapter`.
- Added a Phase 8B mutation policy that accepts only `createMissingService`.
- Added local image availability checking before create.
- Added XCTest coverage for plan-hash mismatch, intent persistence, success, failure, redaction, unsupported create subsets, and mutation policy.

## What Did Not Change

- No multi-action apply.
- No stop, delete, restart, remove, cleanup, prune, pull, push, build, exec, or run behavior.
- No default state database path.
- No daemon loop.
- No volume or mount support in apply.
- No broad bind-address support in apply.
- No sensitive environment value support in apply.
- No live create proof yet because the local Apple container image list is empty.

## Commands Run

```bash
container system status
container create --help
container image list --format json
swift build
swift test list
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

## Risks

- The create path is covered by fake process runners, but live create is not complete until a local image source is approved.
- Non-empty real Apple container image list output is not supported yet.
- The plan-confirmation workflow is usable but still rough; a future apply preview flow may be needed.
- The existence of `apply` can be overread as full lifecycle support unless docs keep saying create-only.

## Unknowns

- Exact non-empty Apple container image-list JSON shape.
- Exact successful `container create` output shape for a disposable local image.
- Whether Apple container create semantics change across 1.0.x releases.

## What I Need To Understand

- Runtime mutation is allowed only through `RuntimeAdapter`.
- State intent is persisted before mutation to make failures auditable.
- `--confirm-plan` protects against applying a stale or unreviewed plan.
- Phase 8B is not cleanup, rollback, restart policy, health execution, or daemon reconciliation.

## Next Action

Approve a local image source and run one disposable create-only apply proof. If that passes, Phase 8 can be marked complete and tagged. If it fails, keep the code path but document the blocker before Phase 9 planning.
