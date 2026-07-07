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
swift run hostwright cleanup --state-db /tmp/hostwright.sqlite --dry-run
```

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
