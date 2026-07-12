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

A clean-source two-commit release-build lifecycle proof is still required. Public distribution additionally requires real Developer ID Application and Installer identities, signature verification, notarization credentials and submission, stapling, Gatekeeper assessment, signed installer review, package-channel approval, and explicit maintainer approval.
