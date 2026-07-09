# Distribution Readiness

Status: Phase 35 fail-closed distribution readiness gate. No binary artifacts are produced by Phase 35.

Hostwright remains source-only until a later maintainer-approved release run has signing identities, notarization credentials, artifact verification, install smoke tests, and release-channel approval.

## Artifact Matrix

| Artifact | Current decision | Required evidence before publishing |
| --- | --- | --- |
| Source archive from `v*` tag | Allowed for source-only releases | Clean `main`, annotated `v*` tag, full local gate, CI pass, release notes, limitations review. |
| CLI binary archive | Blocked | Release build from clean `v*` tag, Developer ID Application signing, signature verification, checksum, SBOM, provenance, install smoke test, uninstall instructions. |
| `hostwrightd` binary archive | Blocked | Same binary evidence as CLI plus daemon foreground-boundary review and no launch agent claim. |
| `.pkg` installer | Blocked | Signed package, notarization, stapling, installer smoke test, uninstaller, upgrade/downgrade notes, rollback instructions. |
| Launch agent installer | Blocked | Separate launchd design, threat model, maintainer approval, unattended-mutation review, install/upgrade/uninstall tests. |
| Homebrew formula or tap | Deferred | Package-channel decision, checksum policy, bottle/source policy, support boundary, upgrade/uninstall proof. |
| Install script | Blocked | Human-reviewed script, checksum verification, signature verification, no profile mutation, no privileged helper, rollback and uninstall path. |
| SBOM | Required before binary artifacts | Tool choice, deterministic output, dependency scope, validation command, publication path. |
| Provenance statement | Required before binary artifacts | Build environment record, source tag, commit, artifact digests, signer identity, reproducible command log. |

## Clean Tag Checklist

The future binary or installer release run must start from a clean public release tag:

1. Check out `main` and fast-forward.
2. Verify the annotated `v*` tag points at the intended commit.
3. Verify the working tree is clean.
4. Run the full local gate and confirm hosted CI is green.
5. Build release binaries from the clean tag.
6. Sign binaries with a reviewed Developer ID Application identity.
7. Verify signatures locally.
8. Build installer packages only after installer, uninstaller, upgrade, downgrade, and rollback behavior are reviewed.
9. Sign installer packages with a reviewed Developer ID Installer identity.
10. Submit packages for notarization and wait for success.
11. Staple notarization tickets and verify Gatekeeper assessment.
12. Generate checksums for every published artifact.
13. Generate SBOM and provenance records.
14. Run install, upgrade, downgrade, and uninstall smoke tests on supported macOS.
15. Review release notes, install docs, limitations, and security notes for current-support language.
16. Publish artifacts only after maintainer approval.

## Install And Upgrade Policy

Until this gate is satisfied, installation is source-only through SwiftPM.

A future installer must:

- install only reviewed Hostwright binaries and docs;
- avoid privileged helpers unless a later threat model proves they are required;
- avoid shell profile mutation;
- avoid creating default state database paths;
- avoid installing a background daemon unless launchd behavior is separately approved;
- include an uninstaller that removes only installer-owned files;
- leave user manifests, explicit state databases, diagnostics bundles, and logs untouched unless the operator explicitly removes them;
- document upgrade, downgrade, and rollback behavior before release.

## Trust Model

Checksums detect accidental or malicious artifact changes after publication, but they do not prove source integrity by themselves.

Code signing identifies the signing certificate used for a binary or installer, but it does not prove the code is safe.

Notarization shows Apple accepted the submitted artifact for distribution checks, but it is not a security review.

SBOM and provenance records improve reviewability, but Hostwright must not claim vulnerability-free, reproducible, or supply-chain-safe artifacts until matching tooling and verification exist.

## Blocked Evidence

Phase 35 does not have:

- Developer ID Application signing proof;
- Developer ID Installer signing proof;
- notarization submission proof;
- stapling or Gatekeeper verification proof;
- SBOM generation or validation tooling;
- provenance generation tooling;
- installer, uninstaller, upgrade, downgrade, or rollback smoke tests;
- Homebrew or other package-channel approval.

Those blockers prevent binary or installer publication claims.
