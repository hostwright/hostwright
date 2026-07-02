# Devlog 0007: Real Planning And Drift

## Goal

Implement deterministic desired-vs-observed planning without runtime mutation.

## What Changed

- Added typed drift, issue, action, and plan models.
- Added manifest-to-runtime desired-state mapping outside the CLI.
- Added planning policy checks for unsafe desired state.
- Added deterministic drift detection.
- Added deterministic plan hash generation.
- Updated `hostwright plan` to render the Phase 7 non-mutating plan.
- Added XCTest coverage for drift, policy, determinism, redaction, and boundaries.

## Concepts Learned

- A plan is not an apply operation.
- Desired state and observed state must remain separate inputs.
- Runtime observation is optional planner input in Phase 7.
- CLI planning does not perform live Apple container observation by default.
- Planned actions carry execution-unavailable metadata until Phase 8.

## Commands To Run

```bash
swift build
swift test list || swift test --list-tests
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

## Risks

- Planned action names could be misread as runtime behavior.
- Env drift is limited until observed runtime env fingerprints exist.
- Port exposure policy is limited by the current manifest model.
- Plan hash stability depends on preserving sorted, redacted inputs.

## Unknowns

- Exact Phase 8 mutation semantics remain unimplemented.
- Persisted observed-state CLI input remains deferred.
- Live runtime observation remains behind the adapter and is not used by CLI plan by default.

## What Maintainers Must Understand

- Phase 7 is judgment, not action.
- No Apple container mutation was added.
- No `apply` command was added.
- No cleanup or daemon loop was added.
- State does not call `RuntimeAdapter`.

## Next Action

Review Phase 7 as a non-mutating planning PR. Phase 8 should begin only after this plan engine is merged and the maintainer can explain every drift/action boundary.
