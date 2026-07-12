# Phase 35: Packaging Signing Notarization And Distribution

## Summary

Phase 35 now has an operational local unsigned distribution lane. Public binary and installer distribution remains blocked.

## What Changed

- Added the developer-only `hostwright-dist` executable and isolated `HostwrightDistribution` module.
- Added clean-source `build`, dirty prebuilt `assemble`, strict `verify`, and temp-prefix `lifecycle` commands.
- Added exact archive manifests for the two Hostwright binaries, LICENSE, and README.
- Added SHA-256 sidecars covering archive, manifest, SPDX, provenance, and evidence files.
- Added an SPDX 2.3 artifact-content inventory and unsigned in-toto/SLSA-shaped provenance bound to source and archive digests.
- Added strict hidden-file, symlink, tar-entry, path, checksum, size, mode, source, and cross-document validation.
- Added atomic same-filesystem payload replacement, exact backups, reverse-order rollback, modified-owned-file refusal, installer-created-directory tracking, and exact uninstall.
- Added real installed-binary execution for install, distinct-revision upgrade, downgrade, and uninstall stages.
- Added real filesystem permission failure, archive tamper, symlink, dirty Git, subprocess, and unrelated-prefix preservation tests.

## Development Evidence

Dirty prebuilt local-integration runs used the actual debug `hostwright`, `hostwrightd`, and `hostwright-dist` executables. Archive assembly and verification completed, the four-stage lifecycle completed, exact cleanup succeeded, and unrelated prefix content remained byte-for-byte unchanged. Reports remained blocked for dirty source and absent distribution trust stages. These runs are local-integration evidence, not release artifacts.

## Clean Local Evidence

A detached two-commit proof used baseline `5b6e7914c93a9a994c7404d7ed0b4c6c72bfd3c3` and implementation commit `8bc05054c3a1cb7b4f1dff884c66fd7e4aaed787`. Both worktrees were clean before and after their release builds. The reports record macOS 26.5 build 25F71, Mac16,8, arm64, 24 GiB memory, Swift 6.3.3, Apple Git 2.50.1, bsdtar 3.5.3, and notarytool 1.1.2.

- Both exact commits built `hostwright` and `hostwrightd` in release mode with an empty SwiftPM external-dependency inventory.
- Both artifacts recorded `sourceDirty: false`, one ARM64 slice per executable, exact payload hashes/sizes/modes, five passed artifact stages, zero failures, and three blocked trust stages.
- Independent verification passed the exact sidecar inventory, all SHA-256 entries, manifest, SPDX relationships, unsigned provenance binding, tar entry types/paths, extracted tree, and payload metadata.
- The lifecycle installed and executed the baseline, upgraded and executed the candidate, downgraded and executed the baseline, then uninstalled: four passed stages, zero failures, and three blocked trust stages.
- Cleanup removed every recorded installer-owned file and created directory, removed transaction/extraction directories, and restored the explicit temporary prefix to its initial unrelated sentinel only.
- `security find-identity -v -p codesigning` reported zero valid identities. Signing, notarization, stapling, Gatekeeper, `.pkg`, and publication therefore remained blocked rather than passed.

The raw artifacts and machine reports remained outside the repository and were not staged.

## Safety Boundaries

- No sudo or system prefix.
- No launch agent, privileged helper, shell-profile mutation, or default state path.
- No unowned overwrite or cleanup.
- No Apple container command or runtime mutation.
- No SQLite access.
- No third-party dependency.
- No signed or notarized artifact.
- No `.pkg`, Homebrew formula, install script, package-channel support, upload, release tag, or GitHub Release.
- No trusted provenance, vulnerability-free, reproducible-build, or production-readiness claim.

## Remaining Evidence

Public distribution still requires real Developer ID Application and Installer identities, signature verification, notarization credentials and submission, stapling, Gatekeeper assessment, signed installer review, package-channel approval, and explicit maintainer approval.
