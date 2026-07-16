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

The two preserved Phase 02 qualification commits report these exact versions:

```text
0.0.2-dev.1
0.0.2-dev.2
```

The current exact value is also recorded in `contracts/v0.0.2/versions.json`.
Do not check out or tag `v0.0.2` until the Phase 15 GA gate has passed. Phase 02 may publish the two immutable unsupported `v0.0.2-dev.1` and `v0.0.2-dev.2` qualification prereleases solely for real signed-byte and vendor-tap upgrade evidence; neither is promoted or presented as a supported release. Historical `v0.1.0-alpha.1` documentation is retained as an immutable project record and is not the current installation target.

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

`hostwright-dist build`, `assemble`, `verify`, and `lifecycle` remain unsigned developer-evidence commands. Their output is not a trusted release artifact and does not satisfy signing, notarization, Gatekeeper, installer, package-manager, or clean-upgrade qualification.

Phase 02 now also implements the fail-closed trusted path:

```text
hostwright-dist release ...
hostwright-dist verify-release ...
hostwright-dist homebrew-formula ...
```

`release` accepts exact Developer ID Application and Installer certificate fingerprints plus the name of a preconfigured `notarytool` Keychain profile. It does not accept a password, API private key, issuer, token, or certificate bytes in argv. It performs two isolated clean builds, rejects observed Swift/Git/tar/notarytool version drift, signs all four shipped executables with hardened runtime and secure timestamps, creates an exact ZIP, submits the ZIP and signed flat `.pkg` to Apple, staples the package, runs Gatekeeper, generates per-artifact SPDX plus digest-bound provenance, signs the manifest/checksums/provenance/release evidence with detached CMS, and independently re-verifies the completed directory before publishing it locally.

The generated Homebrew formula is accepted only for the exact immutable `https://github.com/hostwright/hostwright/releases/download/<tag>/<archive>` URL from the verified release manifest. Local tests run the rendered formula through real Homebrew Ruby and formula-style checks.

That machinery is implemented, but the supported channel is still unavailable: this repository has no credentialed passing trusted-release run or published signed artifact. The `hostwright/homebrew-tap` repository exists but cannot publish a qualified formula until those immutable artifacts exist. The current machine reports no usable Developer ID identities. Those are failed gate prerequisites, not skipped successes. Issues #111, #112, and #119 remain open until real signing/notarization, published-byte verification, vendor-tap install, and clean-Mac lifecycle evidence pass.

## State and Installed Lifecycle Reality

State-backed commands now use `~/Library/Application Support/Hostwright/state/state.sqlite` when no `--state-db` or `HOSTWRIGHT_STATE_DB` override is present. State-writing commands create the documented Application Support, cache, and log roots with private permissions. A compatible legacy `~/.hostwright/state.sqlite` is moved through a synchronized, identity-bound, resumable journal; unknown legacy files are preserved.

Inspect the selected paths without creating them:

```bash
swift run hostwright paths --json
swift run hostwright doctor --output json
```

The complete precedence, `0700`/`0600` policy, migration failure behavior, and recovery procedure are in [Local Paths, Permissions, and Legacy Migration](local-paths.md).

`hostwright-dist` now implements install, strict upgrade, same-generation repair, status, explicit legacy adoption, interrupted-operation recovery, one-generation verified rollback, and ownership-scoped uninstall for a verifier-produced artifact at an explicit existing prefix. Every lifecycle command uses structured JSON. Upgrade snapshots and migrates a bound compatible state database; rollback restores the exact pre-upgrade snapshot when one was retained.

This is installed-lifecycle behavior, not an available package channel. The prefix is always explicit; no published Homebrew formula, public signed archive, or supported `.pkg` install is available yet. The `.pkg` implementation stages its payload only in the private root-owned `/Library/Application Support/Hostwright/InstallerPayload` directory. Its `postinstall` entrypoint runs elevated `hostwright-dist package-apply`, which verifies the exact `dev.hostwright.cli` receipt/version, staged manifest and digests, executable signatures against the trusted release's exact Team ID, package-origin status, and `/usr/local` prefix before using the existing durable install/upgrade/repair lifecycle. It does not create/register/autostart a LaunchAgent, edit `PATH` or shell profiles, or mutate Apple container workloads. It stops and restores only an exact existing Homebrew launchd record bound to this prefix; an unmanaged installed `hostwrightd` is refused instead of killed or adopted.

Generic explicitly bound installs offer two exact choices:

1. `preserve` removes verified payload and lifecycle ownership metadata while leaving the bound state database untouched;
2. `remove` requires a current plan token and removes the verified bound SQLite database and existing SQLite sidecars after taking a recovery snapshot.

Neither choice removes backup catalogs, configuration, caches, logs, unrelated prefix content, or Apple container resources. Modified, linked, symlinked, wrong-owner, or otherwise ambiguous owned paths fail closed. See [Installed Distribution Lifecycle](installed-lifecycle.md) for commands, checkpoints, recovery, rollback, legacy adoption, service limitations, and troubleshooting.

A package-owned installation uses elevated `hostwright-dist package-uninstall --prefix /usr/local --data-policy preserve --output json`. It re-verifies lifecycle ownership, the receipt, and the staged payload; after the uninstall transaction commits, it forgets only `dev.hostwright.cli` and removes only verified staging content. Package remove-data planning and uninstall are refused before mutation because the system-wide package lifecycle does not infer or search for a per-user state database. A bounded pending-cleanup marker lets `hostwright-dist recover --prefix /usr/local --output json` finish an interrupted receipt cleanup. Generic archive upgrade or uninstall is refused for a package-owned generation.

A source checkout remains separate from an installed prefix. Deleting the checkout does not run `hostwright-dist uninstall` and does not remove Application Support data or runtime resources.

## Gate Before Package Claims

No package channel is called supported until clean-Mac evidence covers Gatekeeper, reboot, upgrade, rollback, repair, uninstall, corruption, disk full, PATH hijack, symlink attacks, cancellation, and owned process-tree cleanup. Final requirements are in the [v0.0.2 implementation plan](../roadmap/v0.0.2/IMPLEMENTATION_PLAN.md) and [distribution evidence rules](testing-evidence.md).

All production installer, distribution, extension, tool-inspection, and Apple-runtime subprocesses use the [secure process execution boundary](process-execution.md). The trusted distribution tool propagates one cancellation token through identity lookup, both clean builds, archive/package operations, notarization, verification, install lifecycle, and cleanup; SIGINT/SIGTERM enter the same path. Phase 02 issue #116 implements that shared boundary, but the release pipeline still needs credentialed live evidence before any install channel is supported.

Phase 02 issue #113 implements secure local defaults and legacy-state migration. Issue #114 adds managed integrity, online backup, catalog verification, confirmation-bound restore, projection-only repair, fencing, and recovery. Issue #118 adds the explicit-prefix and Apple Installer lifecycle documented above. The trusted artifact/formula implementation is recorded in [devlog 0044](../devlog/0044-trusted-release-and-homebrew-foundation.md). Real credentials, vendor-tap publication, signed Apple Installer/reboot execution, and clean-Mac package-channel qualification remain open evidence; issues #111, #112, and #119 are not satisfied by developer-artifact lifecycle tests.
