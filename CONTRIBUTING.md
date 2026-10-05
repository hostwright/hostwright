# Contributing

Use the current [release plan](docs/roadmap/v0.0.2/IMPLEMENTATION_PLAN.md) and the issue's acceptance criteria to scope a change. The first release targets one Mac, local CLI and desktop operation, and narrow Compose import.

## Build and test

```bash
swift build --jobs 1
scripts/test.sh pr
scripts/check-docs.sh
```

`scripts/test.sh full` runs the full suite and integration checks. Expensive or attended checks also have `qualification distribution`, `qualification release`, and `qualification live` shards. Run the lanes relevant to the changed behavior; record unavailable or skipped environments as such. See [testing and evidence](docs/reference/testing-evidence.md) for release requirements.

## Code changes

Follow the existing SwiftPM modules. Route runtime access through `RuntimeAdapter`, SQLite access through `HostwrightState`, and child processes through the reviewed process runner. Validate external inputs where they enter the system. Preserve ownership, confirmation, and recovery checks when changing mutations.

Keep fixes focused. Add regression coverage for defects and update command examples when behavior changes. Keep generated output, private state, local evidence, credentials, and personal notes outside commits.

## Pull requests

Describe the problem, the resulting behavior, and the checks run. Link the relevant issue and state any remaining limitation. Use `Refs #NN` while work is incomplete. A final roadmap closure requires `status:verification`, clean evidence, and `Closes #NN`; see the [release process](docs/release/RELEASE_PROCESS.md).

Maintainer review covers changes to dependencies, public contracts, state migrations, secrets, runtime authority, destructive operations, and distribution. Changes to release scope or architecture belong in a short design record. See [governance](GOVERNANCE.md) for release authority and [the security policy](SECURITY.md) for private reporting.
