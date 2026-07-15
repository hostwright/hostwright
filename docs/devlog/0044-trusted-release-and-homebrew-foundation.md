# Phase 02: Trusted Release and Homebrew Foundation

Issues #111, #112, and #119 now have an executable trusted-distribution foundation on the shared Phase 02 branch. The issues remain open because code-level proof is not a substitute for real Developer ID, Apple notarization, public-channel, and clean-Mac lifecycle evidence.

## Implemented flow

```text
clean exact commit
  -> two isolated SwiftPM release builds
  -> byte-identical unsigned payload check
  -> sign hostwright, hostwright-control, hostwright-dist, and hostwrightd
  -> exact signed ZIP + signed flat pkg
  -> notarize both; staple pkg; assess with Gatekeeper
  -> per-artifact SPDX + source/digest-bound provenance
  -> sorted SHA256SUMS + detached CMS signatures, including release evidence
  -> independent ZIP/pkg/signer/evidence verification
  -> atomic local release directory publication
  -> digest-bound Homebrew formula generation
```

The unsigned developer archive now includes all four shipped executables plus the maintained example manifest. Issue #118 added the shipped `hostwright-dist` lifecycle tool to the payload after the initial trusted-release foundation. Existing unsigned commands stay fail-closed and cannot be mistaken for trusted release evidence.

## Trust and failure contract

- Application and Installer identities are selected by exact uppercase SHA-1 fingerprint, exact Developer ID kind, one non-ambiguous common name, and one team identifier.
- The release CLI accepts only a nonsecret Keychain profile name. Passwords, API keys, issuers, private keys, certificate bytes, and tokens are not command arguments.
- Every spawned command uses the shared secure subprocess boundary. One cancellation token reaches identity lookup, both builds, ZIP/package work, notarization, Gatekeeper, CMS, extraction/expansion, install verification, and lifecycle cleanup. SIGINT/SIGTERM enter that same path.
- The ZIP is online-ticket notarized because Apple does not staple bare ZIP archives. The signed flat `.pkg` is notarized, stapled, and staple-validated.
- Verification requires one exact CMS signer certificate fingerprint rather than trusting display text or common-name matching alone.
- The verifier rejects extra entries, symlinks, hard links, special files, wrong modes, unsafe paths, checksum drift, manifest drift, package payload drift, signer/team drift, rejected/missing ticket state, SBOM/provenance drift, unsigned evidence, and evidence-report drift.
- Output is staged beside the requested destination and moved into place only after a complete passing verification. Owned temporary roots are removed on success, failure, or cancellation.
- Signed provenance records an empty external SwiftPM dependency inventory, the Apache-2.0 package license, two isolated builds, byte-identical unsigned payloads, and the matching observed Swift, Git, tar, and notarytool versions. Both clean builds independently reject any external SwiftPM dependency or tool-version drift before producing release bytes; macOS system frameworks are platform prerequisites, not vendored packages.
- `release`, `verify-release`, and `homebrew-formula` preserve text output by default and provide schema-1 success/error JSON through `--format json`. The formula destination remains the separate `--output` path.

## Release workflow

`.github/workflows/trusted-release.yml` is manual-only and uses the protected `release` environment plus a dedicated Apple-silicon self-hosted runner label.

The build/sign/notarize job has read-only repository contents permission and no OIDC or publication authority. It validates an exact commit already merged to `main`, an absent immutable tag, exact identity/profile variables, a clean checkout, Apple-silicon hardware, and working notary credentials. It runs the complete repository gate before building twice and retaining the release bundle.

The verified workflow bundle is retained for 90 days. Published prerelease assets and their release evidence set use indefinite retention and are never replaced in place; any exceptional removal requires a separate reviewed repository action.

A GitHub-hosted attestation job does not check out or execute repository source. It downloads the retained signed artifacts and receives only the OIDC and attestation permissions needed for pinned GitHub provenance and SBOM attestation actions.

A separate publication job receives repository write permission but does not check out or execute repository source. It rechecks tag/release absence after the long build, downloads the retained bundle, verifies its checksums and all four detached CMS signatures, creates the annotated tag and prerelease, downloads every public asset, compares every byte and exact filename, and verifies GitHub attestations. Failure or cancellation compensation acts only when the annotated tag contains this run's pre-mutation ownership marker and resolves to the exact release commit; mismatched state is left untouched and fails closed.

## Homebrew contract

The formula accepts only the immutable Hostwright GitHub release URL named by the verified manifest. It installs `hostwright`, `hostwright-control`, `hostwright-dist`, `hostwrightd`, documentation, and the example manifest; checks all four signatures before install; declares Apple silicon/macOS 26; exposes an explicit non-autostart service definition; and tests versions plus machine-readable capabilities.

Focused tests render the formula into a unique temporary tap and run real Homebrew Ruby syntax and formula style. The test untaps the exact temporary repository afterward. This proves formula structure, not public tap availability or artifact installation.

## Evidence achieved

- Swift build succeeds with the trusted release models, builder, verifier, CLI, and workflow contract.
- Focused distribution tests cover manifest/provenance binding, SPDX licenses/inventory, immutable formula URLs, real Homebrew syntax/style, malformed notarization output, malformed CMS, pre-cancel behavior, SIGTERM cancellation, unsigned archive verification, atomic rollback, ownership refusal, symlink rejection, and lifecycle cleanup.
- The workflow YAML parses and actionlint reports no issue after accounting for the intentional custom `hostwright-release` runner label.
- The local machine has `notarytool` and Homebrew but reports zero usable Developer ID identities. No fake signature, mock notarization, or passing distribution report was substituted.

## Gates still open

1. Configure reviewed Developer ID Application and Installer identities and a noninteractive notary Keychain profile on a hardened release runner.
2. Run the protected workflow from an exact clean `main` commit and retain raw Apple/Gatekeeper/artifact evidence.
3. Obtain explicit approval before creating the public `hostwright/homebrew-tap` repository, then publish the generated digest-bound formula through a reviewed tap commit.
4. Install from the real vendor tap on clean supported Macs; cover Gatekeeper, reboot, upgrades, rollback, repair, uninstall, disk-full, corruption, PATH/symlink attacks, cancellation, and exact cleanup.
5. Qualify issues #115, #117, and #118 together so SQLite hardening, readiness diagnostics, and installed lifecycle share the same Phase 02 evidence gate.
6. Close #111, #112, #119, and epic #120 only through the one Phase 02 PR after every required evidence class passes.
