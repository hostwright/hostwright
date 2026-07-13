# Install and Upgrade

Status: source development workflow only for `0.0.2-dev`. The `v0.0.2` release has not passed its distribution gate.

## Package Manager Truth

`brew install hostwright` does not exist today. Do not publish or repeat that command as an available installation path.

Phase 02 owns:

- a Hostwright-maintained Homebrew tap and formula;
- signed and notarized Apple-silicon archives;
- a signed/notarized `.pkg`;
- secure Application Support paths;
- install, upgrade, rollback, repair, and uninstall;
- checksums, SBOM, provenance, and local verification.

The intended guaranteed package-manager command, after Phase 02 evidence passes, is:

```bash
brew install hostwright/tap/hostwright
```

That command is a roadmap target, not available current behavior. Phase 15 submits an unqualified Homebrew-core formula. Literal `brew install hostwright` remains contingent on Homebrew acceptance; the vendor tap is the fallback Hostwright controls.

## Current Source Build

Requirements:

- Apple silicon;
- macOS 26 or later;
- Xcode command-line tools with a Swift 6.2-compatible toolchain;
- network access only to clone dependencies/source;
- Apple `container` installed only for live runtime commands.

```bash
git clone https://github.com/hostwright/hostwright.git
cd hostwright
swift build
swift test
scripts/integration.sh
swift run hostwright --version
swift run hostwright capabilities --json
```

Expected development version:

```text
0.0.2-dev
```

Do not check out or tag `v0.0.2` until the Phase 15 GA gate has passed. Historical `v0.1.0-alpha.1` documentation is retained as an immutable project record and is not the current installation target.

## Development Executables

SwiftPM builds:

- `hostwright`
- `hostwright-control`
- `hostwrightd`
- `hostwright-dist`

Locate them with:

```bash
swift build --show-bin-path
```

`hostwright-dist` currently provides unsigned developer evidence only. Its output is not a trusted release artifact and does not satisfy signing, notarization, Gatekeeper, installer, package-manager, or clean-upgrade qualification.

## State and Uninstall Reality

Current commands require explicit state paths. There is no production default under `~/Library/Application Support`, no installed LaunchAgent, and no package receipt to remove. A source checkout can be removed only after the operator has separately stopped workloads and preserved or cleaned explicitly managed runtime/state resources.

Do not treat deletion of the checkout as a Hostwright uninstall. Phase 02 implements a real ownership-aware uninstall that:

1. stops installed Hostwright processes;
2. preserves or explicitly removes managed data according to the operator choice;
3. removes only files recorded in the signed install manifest/receipt;
4. leaves unmanaged runtime and filesystem resources untouched;
5. verifies PATH, launch service, state, and artifact cleanup;
6. supports rollback to the recorded previous compatible build.

## Gate Before Package Claims

No package channel is called supported until clean-Mac evidence covers Gatekeeper, reboot, upgrade, rollback, repair, uninstall, corruption, disk full, PATH hijack, symlink attacks, cancellation, and owned process-tree cleanup. Final requirements are in the [v0.0.2 implementation plan](../roadmap/v0.0.2/IMPLEMENTATION_PLAN.md) and [distribution evidence rules](testing-evidence.md).

All production installer, distribution, extension, tool-inspection, and Apple-runtime subprocesses must use the [secure process execution boundary](process-execution.md). Phase 02 issue #116 implements that shared boundary; it does not by itself make the still-unsigned developer distribution a trusted install channel.
