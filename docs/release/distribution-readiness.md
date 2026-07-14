# Distribution Readiness

> **Historical Phase 35 record:** this describes the earlier unsigned developer lane. The active trusted-install work is v0.0.2 Phase 02, recorded in [devlog 0044](../devlog/0044-trusted-release-and-homebrew-foundation.md), and final artifact qualification is Phase 15. Nothing in this historical record authorizes a current binary, installer, signing, notarization, or package-channel claim.

Status: Phase 35 operational unsigned artifact lane; public distribution remains blocked.

Hostwright public releases remain source-only. The developer-only `hostwright-dist` tool can build and verify a local unsigned macOS ARM64 archive and exercise an exact temporary-prefix lifecycle. Its reports remain `blocked` until Developer ID signing, notarization, stapling, Gatekeeper, and installer publication stages run with real credentials and approval.

## Artifact Matrix

| Artifact | Current decision | Evidence |
| --- | --- | --- |
| Source archive from `v*` tag | Allowed for source-only releases | Clean `main`, annotated `v*` tag, full local gate, CI pass, release notes, and limitations review. |
| Local unsigned CLI and `hostwrightd` archive | Operational for developer evidence; not publishable | Clean or explicitly dirty source binding, exact file manifest, macOS ARM64 slice checks, SHA-256 sidecars, SPDX artifact-content inventory, unsigned provenance, archive verification, and temp-prefix lifecycle. |
| Signed binary archive | Blocked | Developer ID Application signing and independent signature verification have not run. |
| `.pkg` installer | Blocked | Developer ID Installer signing, notarization, stapling, Gatekeeper, and system install evidence have not run. |
| Launch agent installer | Blocked | Separate launchd design, threat model, maintainer approval, unattended-mutation review, and install/upgrade/uninstall tests are required. |
| Homebrew formula or tap | Deferred | Package-channel decision, checksum policy, bottle/source policy, support boundary, and upgrade/uninstall proof are required. |
| Install script | Blocked | No system installer or shell-profile mutation path is implemented. |
| SPDX SBOM sidecar | Operational for local archive contents | Covers the four archived payload files and archive digest. It is not an image SBOM, vulnerability report, dependency attestation, or publication approval. |
| Provenance sidecar | Operational but unsigned and untrusted | Binds the source commit, dirty state, local builder shape, artifact parameters, and archive digest. It is not signed builder attestation or a SLSA level claim. |

## Local Evidence Commands

The clean build path requires an explicit source root, new output directory, and exact commit. It verifies tracked, untracked, and ignored source inventory; rejects ignored inputs other than the unused `.build/` containing the tool itself; rejects external SwiftPM dependencies; builds both release products in a unique scratch directory; records exact scratch cleanup; and intentionally exits `69` because trust stages remain blocked:

```bash
swift run hostwright-dist build \
  --source-root "$PWD" \
  --output-dir /tmp/hostwright-dist-candidate \
  --expected-commit "$(git rev-parse HEAD)"
```

The verifier checks the exact top-level inventory, every SHA-256 line, file modes, manifest binding, SPDX relationships, provenance binding, tar entry paths and types, post-extraction symlinks, and payload hash/size/mode values:

```bash
swift run hostwright-dist verify \
  --distribution-dir /tmp/hostwright-dist-candidate
```

Lifecycle evidence requires two distinct artifact commits and an existing explicit `hostwright-dist-*` directory under a temporary root:

```bash
swift run hostwright-dist lifecycle \
  --baseline-dir /tmp/hostwright-dist-baseline \
  --candidate-dir /tmp/hostwright-dist-candidate \
  --prefix /tmp/hostwright-dist-prefix.example \
  --report /tmp/hostwright-dist-lifecycle.json
```

`assemble` exists only for dirty local-integration runs against explicit prebuilt binaries. It requires `--source-dirty true`; clean evidence must use `build`.

## Archive Contract

The archive contains only:

- `bin/hostwright`;
- `bin/hostwrightd`;
- `share/doc/hostwright/LICENSE`;
- `share/doc/hostwright/README.md`;
- the internal `manifest.json` copy.

The output directory also contains the archive, external `manifest.json`, `SHA256SUMS`, `sbom.spdx.json`, `provenance.intoto.json`, and mode-`0600` `distribution-evidence.json`. No raw machine report or artifact is committed by the normal repository gate.

## Install And Upgrade Policy

The lifecycle runner is not a system installer. It:

- accepts only an explicit `hostwright-dist-*` temporary prefix;
- refuses symlink prefixes and pre-existing unowned payload paths;
- validates archives before extraction;
- records which payload directories it created;
- atomically replaces exact owned files from same-filesystem staging;
- keeps exact backups and rolls back applied files in reverse order on failure;
- executes installed `hostwright --version` and `hostwrightd --help` after install, upgrade, and downgrade;
- refuses update or uninstall when an owned file no longer matches its checksum/mode/size;
- removes only exact installer-owned files and installer-created empty directories;
- compares the final prefix snapshot with its initial unrelated content.

It never uses sudo, `/usr/local`, a launch agent, a privileged helper, shell-profile mutation, or a default state path.

## Future Public Release Checklist

The public binary or installer release run must still:

1. Start from a clean approved `v*` tag and pass the full local and hosted gates.
2. Re-run the clean `hostwright-dist build` and two-revision lifecycle evidence on supported macOS.
3. Sign both binaries with an approved Developer ID Application identity.
4. Verify signatures and designated requirements independently.
5. Build an installer only after installer ownership and rollback scope are approved.
6. Sign the package with an approved Developer ID Installer identity.
7. Submit the exact package for notarization with approved credentials.
8. Staple the accepted ticket and run Gatekeeper assessment on the exact artifact.
9. Regenerate and verify checksums, SBOM, and signed provenance for the published bytes.
10. Review install, upgrade, downgrade, uninstall, rollback, release notes, limitations, and security language.
11. Publish only after maintainer and package-channel approval.

## Trust Model

Checksums detect byte changes after generation but do not prove source integrity. The local SPDX sidecar inventories archive contents but does not scan vulnerabilities or describe container images. The provenance sidecar is unsigned and therefore does not establish a trusted builder identity. Ad hoc or locally verifiable signatures are not Developer ID distribution proof. Notarization is an Apple distribution check, not a security review.

## Hard Blockers

Current evidence records:

- zero installed Developer ID signing identities on the reviewed machine;
- no signing operation;
- no notarization credentials or submission;
- no stapling or Gatekeeper acceptance;
- no signed `.pkg` installer or system-prefix lifecycle;
- no Homebrew or other package-channel approval;
- no public binary-artifact approval.

Those blockers keep every distribution-artifact report `blocked` and prevent binary or installer publication claims.
