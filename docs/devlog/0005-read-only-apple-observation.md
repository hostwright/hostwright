# Devlog 0005: Read-Only Apple Container Observation

## Goal

Begin Apple container integration with read-only observation infrastructure only.

## What Changed

- Added `AppleContainerReadOnlyAdapter` behind `RuntimeAdapter`.
- Added `AppleContainerCommand` to isolate Apple container command shapes.
- Added `RuntimeExecutableResolver` so runtime commands use resolved executables.
- Added `FoundationRuntimeProcessRunner` for policy-approved read-only command specs.
- Added `AppleContainerObservationParser` for the Phase 5 fixture-defined observation schema.
- Added empty, running, and redaction fixtures.
- Extended runtime smoke checks for missing executables, command-policy rejection, parser behavior, redaction, mutation-unavailable behavior, and runtime-boundary isolation.

## What Phase 5 Does Not Do

- No runtime mutation.
- No `apply`.
- No create, start, stop, delete, restart, remove, or cleanup.
- No SQLite state.
- No daemon loop.
- No DNS, tunnels, cloud, GPU/ANE, privileged helper, or installer behavior.
- No CLI status based on observed runtime state.

## Design Notes

The live process runner is not a general shell-out API. It accepts only typed `RuntimeCommandSpec` values that are classified as read-only and resolved by `RuntimeExecutableResolver`. Mutating, forbidden, unknown, and unresolved specs fail before execution.

The parser accepts only the fixture-defined `hostwright.apple-container.observation.v1` schema. This is intentionally conservative: if actual local Apple container output differs, Hostwright reports a parse failure instead of inventing observed state.

## Risks

- The Phase 5 fixture schema may not match real Apple container output.
- Local observation remains unavailable when `container` is missing.
- Smoke/precondition tests remain weaker than XCTest or Swift Testing.
- Read-only command semantics need manual verification before public compatibility claims.

## Verification

```bash
swift build
swift test
scripts/grep-orchard.sh .
scripts/test.sh
git status --short
git diff --stat
git diff --name-only
```

## Next Action

After maintainer review, Phase 5 can be committed. Phase 6 must stay focused on SQLite state and event ledger foundations; it must not add runtime mutation.
