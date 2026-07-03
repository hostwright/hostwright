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
- No general lifecycle management beyond the single create-missing-service proof.

## Commands Run

```bash
container system status
container create --help
container image list --format json
container build --tag hostwright-proof-web:phase8b --file Dockerfile .
swift run hostwright apply /tmp/hostwright-phase8b-live-proof/hostwright.yaml --state-db /tmp/hostwright-phase8b-live-proof/hostwright.sqlite --confirm-plan bogus
swift run hostwright apply /tmp/hostwright-phase8b-live-proof/hostwright.yaml --state-db /tmp/hostwright-phase8b-live-proof/hostwright.sqlite --confirm-plan 747c4fc317324046
container list --all --format json
container inspect hostwright-proof-web
container delete hostwright-proof-web
container image delete hostwright-proof-web:phase8b
swift build
swift test list
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

## Live Proof

The approved proof built one disposable local image, `hostwright-proof-web:phase8b`, outside the repository in `/tmp/hostwright-phase8b-live-proof`.

The first `hostwright apply` used a bogus confirmation hash and refused mutation while printing the expected plan hash, `747c4fc317324046`. The confirmed apply then created exactly one Apple container named `hostwright-proof-web` through `RuntimeAdapter`.

After creation, `container list --all --format json` and `container inspect hostwright-proof-web` showed the proof container in Apple container output. Re-running `hostwright apply` with the old hash failed before mutation because observed state changed and the recomputed plan hash was different. Cleanup deleted only `hostwright-proof-web` and `hostwright-proof-web:phase8b`.

## Risks

- The create path is proven only for the approved disposable image and one missing service.
- The live proof left Apple-managed builder state and the downloaded base image outside Hostwright ownership; Hostwright must not clean those up without explicit ownership design.
- The plan-confirmation workflow is usable but still rough; a future apply preview flow may be needed.
- The existence of `apply` can be overread as full lifecycle support unless docs keep saying create-only.

## Unknowns

- Broader non-empty Apple container image-list JSON shapes beyond the verified object form.
- Broader non-empty container-list JSON shapes beyond the verified builder and proof-container forms.
- Whether Apple container create semantics change across 1.0.x releases.

## What I Need To Understand

- Runtime mutation is allowed only through `RuntimeAdapter`.
- State intent is persisted before mutation to make failures auditable.
- `--confirm-plan` protects against applying a stale or unreviewed plan.
- Phase 8B is not cleanup, rollback, restart policy, health execution, or daemon reconciliation.

## Next Action

Review the Phase 8B live proof diff, then commit, push, open a PR, and merge if CI and review stay clean. After merge, tag Phase 8 and plan Phase 9 health/restart/status/logs/cleanup gates without widening mutation semantics casually.
