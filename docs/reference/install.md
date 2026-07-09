# Install And Build

Hostwright `v0.1.0-alpha.1` is a source-only alpha. It is not production ready.

## Requirements

- Apple silicon Mac.
- macOS 26 or newer.
- Full Xcode developer tools or a Swift toolchain capable of SwiftPM builds.
- Apple container CLI for runtime observation and mutation behavior.
- Git.

## Build From Source

```bash
git clone https://github.com/hostwright/hostwright.git
cd hostwright
git checkout v0.1.0-alpha.1
swift build
swift test
```

Run the CLI from SwiftPM:

```bash
swift run hostwright --version
swift run hostwright doctor
swift run hostwright validate
swift run hostwright plan
swift run hostwright plan --output json
```

Runtime-backed commands require Apple container and explicit state paths:

```bash
swift run hostwright status --state-db /tmp/hostwright.sqlite
swift run hostwright status --state-db /tmp/hostwright.sqlite --output json
swift run hostwright logs api --state-db /tmp/hostwright.sqlite
swift run hostwright events --state-db /tmp/hostwright.sqlite
swift run hostwright events --state-db /tmp/hostwright.sqlite --output json
swift run hostwright diagnostics --state-db /tmp/hostwright.sqlite --bundle /tmp/hostwright-diagnostics.json
swift run hostwright cleanup --state-db /tmp/hostwright.sqlite --dry-run
swift run hostwrightd --foreground --config hostwright.yaml --state-db /tmp/hostwright.sqlite --max-iterations 1
```

State databases are never chosen implicitly. `status`, `logs --state-db`, `apply`, `cleanup`, and `hostwrightd --foreground` can run explicit migrations before writing state. `events` and `diagnostics` read an already-migrated state database and fail rather than creating or migrating one as a side effect.

`hostwrightd` requires explicit `--config` and `--state-db` paths. It observes, plans, and records daemon loop events only; it does not install a launch agent or perform unattended runtime mutation.

For backup or restore, stop Hostwright commands using the database and copy the explicit SQLite file plus sidecar files such as `state.sqlite-wal` and `state.sqlite-shm` if they exist. `hostwright diagnostics` can write a local redacted JSON bundle for review, but Hostwright does not provide online backup, restore, repair, hosted diagnostics, or automatic upload commands in this phase.

JSON output is also available for safe diagnostics:

```bash
swift run hostwright doctor --output json
```

## Artifact Policy

This alpha provides source only.

Hostwright does not provide:

- binary downloads;
- installer packages;
- Homebrew formula;
- signed binary artifacts;
- notarized artifacts;
- packaged launch agents or privileged helpers.

Those require separate signing, notarization, checksum, SBOM, provenance, and installer decisions.

Phase 35 defines the future distribution readiness gate in `docs/release/distribution-readiness.md`. That gate is documentation and review policy only in the current tree; it does not publish binaries, create installers, install launch agents, add an install script, or approve a package channel.

Phase 39 defines the beta readiness gate in `docs/release/beta-readiness.md`. That gate requires clean-checkout source install proof, docs alignment, current limitations review, state upgrade evidence, telemetry/support policy review, and maintainer approval before any beta tag. It does not create a beta release or change the source-only artifact policy by itself.
