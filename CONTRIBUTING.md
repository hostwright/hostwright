# Contributing

Hostwright changes should be small, testable, and honest about runtime boundaries.

## Ground Rules

- Keep the first supported release local and single-host.
- Use Swift and Swift Package Manager unless a design record approves another tool.
- Keep dependencies minimal.
- Add or update tests for changed behavior.
- Do not add runtime mutation before dry-run planning and adapter boundaries exist.
- Do not add destructive behavior without explicit confirmation design.
- Do not add unsupported compatibility claims.

## Local Checks

```bash
swift build
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

## Runtime Boundaries

All runtime behavior must go through `RuntimeAdapter`. CLI, daemon, state, reconciler, and health modules must not shell out directly to Apple container or any other runtime.

