# Devlog 0008A: Apple Container Preflight

## Goal

Prove Hostwright can understand the first verified real Apple container read-only observation shape before implementing `apply`.

## What Changed

- Verified Apple container 1.0.0 locally.
- Verified the Apple container system service reports `running`.
- Verified `container list --all --format json` returns `[]` for an empty runtime.
- Added a fixture for the real empty JSON output.
- Updated the Apple container read-only command descriptor to request JSON list output.
- Updated the parser to accept only the verified empty real JSON array shape.
- Added XCTest coverage for real empty JSON and unsupported real JSON shapes.

## What Did Not Change

- No `hostwright apply`.
- No runtime mutation.
- No create, run, start, stop, delete, restart, remove, pull, build, exec, prune, or cleanup behavior.
- No CLI live runtime observation by default.
- No non-empty real Apple container parsing claim.

## Commands Run

```bash
container system status
container list --all --format json
swift build
swift test list
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

## Risks

- Real non-empty Apple container JSON output is still unverified.
- Apple container CLI output can change across versions.
- The adapter remains defensive and incomplete by design.

## Next Action

Review and merge this fixture/parser support before planning Phase 8B. Phase 8B may plan create-only `apply`, but only after this read-only observation foundation is accepted.
