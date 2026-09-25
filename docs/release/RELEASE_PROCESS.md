# Release process

The active target is `v0.0.2`. Development builds remain on the `0.0.2-dev` line until candidate qualification. Immutable `v0.0.2-dev.11` and `v0.0.2-dev.12` prereleases supply upgrade baselines; they remain unsupported and are not promoted in place.

## Tag Policy

Public releases and candidates use `v*` tags. Optional `phase-*` checkpoints have no GitHub Release. Create a public tag only for a reviewed, clean commit with the required evidence. Published tags and assets must not be moved or replaced.

## Release Ladder

1. Finish required implementation and prepare the qualification lanes on the development line.
2. Qualify `v0.0.2-rc.1` against the intended GA scope. Fix defects and repeat affected checks on the corrected candidate.
3. After one complete RC qualification and independent artifact lifecycle verification, prepare the final `0.0.2` version change.
4. Qualify the final-version bytes, obtain maintainer approval, and publish through protected promotion. Close release-artifact and parent issues after public-byte and installation verification.

## Active Roadmap Authority

The [release plan](../roadmap/v0.0.2/IMPLEMENTATION_PLAN.md), [issue manifest](../roadmap/v0.0.2/issues.json), [testing contract](../reference/testing-evidence.md), and [evidence schema](../../schemas/hostwright-evidence.schema.json) define the requirements for [master issue #284](https://github.com/hostwright/hostwright/issues/284).

Required issues close through a final `status:verification` PR and clean evidence comment. Intermediate PRs use `Refs #NN`; final evidence PRs use `Closes #NN`. Deferred issues close as `not_planned` under [ADR 0015](../design/adr-0015-reduced-local-release.md). Parents require completed required children and correctly deferred children. Governance checks enforce these rules.

## Baseline Gate for Every Phase and RC

```bash
scripts/test.sh pr
```

Run the owning workstream's required lanes as well. Trusted staging runs the full regression suite. Unavailable, skipped, blocked, simulated, dirty-source, or cleanup-failed results cannot satisfy a required release gate.

## v0.0.2 GA Gate

All of the following are required:

- every required implementation workstream is verified, and all deferred issues are explicitly closed as not planned; release-artifact, Phase 15 and master issues close after publication verification;
- zero unresolved P0/P1 defects;
- macOS 26 arm64, Apple `container` 1.0.0/1.1.0 and Containerization 0.35.0 declared capabilities are frozen from passing evidence with exact OS builds and hardware;
- Apple CLI and pinned Containerization providers pass declared-capability conformance;
- ten live lifecycle cycles per provider and a checkpointed 30-minute physical-host soak pass without duplicate resources, unmanaged mutation, leaked reservations, or monotonic leaks; gaps do not count;
- the physical M4 Pro provides live runtime evidence and one macOS VM provides independent clean-environment artifact lifecycle evidence; neither implies independent-hardware or HA qualification;
- every shipped critical parser/protocol receives five minutes of fuzzing plus retained corpus replay;
- supported ASan and TSan lanes pass;
- focused independent security review of shipped boundaries is complete and release-blocking findings are remediated and retested;
- dependency, license, secret, SAST, SBOM, signature, vulnerability, and provenance gates pass;
- bounded local performance, upgrade lineage, rollback, local backup/recovery, compatibility, and desktop accessibility gates pass;
- every documentation quickstart executes and website typecheck/build/link checks pass;
- signed/notarized archives and `.pkg` pass checksum, stapling, Gatekeeper, clean install, reboot, upgrade, rollback, repair, and uninstall;
- the vendor Homebrew tap installs those exact verified artifacts;
- one complete clean RC qualification and independent signed-artifact install/reboot/upgrade/rollback/repair/uninstall verification pass; final-version bytes qualify before promotion.

## Artifact and Package Policy

The reviewed staging workflow builds from an exact clean commit already merged to `main`. It produces signed/notarized Apple-silicon archive and package payloads, checksums, SPDX SBOMs, signed provenance, corresponding source, verification metadata, and a vendor-tap formula bound to the archive digest.

Staging requires an authenticated runtime-provenance archive from the exact source commit. It verifies the `hostwright.corresponding-source.new-runtime.v1` manifest and payloads against the shipped runtime bytes. Ingredient-only runs and legacy source bundles cannot satisfy this input.

The protected workflow retains staged bundles for 90 days. Published assets, signatures, provenance, inventories, checksums, and release evidence are retained indefinitely. Exceptional removal requires a separate reviewed action.

Homebrew-core submission is deferred. Publish only the verified `brew install hostwright/tap/hostwright` channel; do not claim `brew install hostwright` before core acceptance.

## Final Evidence Record

Include this marker in the final evidence comment:

```text
<!-- hostwright-evidence-gate:v1 -->
```

Record the full commit, `Dirty: false`, OS build, architecture, hardware, runtime and tool versions, commands and raw outcomes, failures, blockers, cleanup identities, artifact links, and documentation changes. Redact secrets and private details while preserving auditable results.

Gate receipts bind the source commit, version, clean state, and hashed raw attachments. Artifact-dependent gates also bind the staged inventory. Keep complete inventories and their referenced files together. See [staged release promotion](../reference/release-promotion.md) for the exact receipt and attestation contracts.

## Promotion Steps

1. Verify the reviewed candidate or final-version commit is on protected `main` and matches its clean qualification source.
2. Run the complete authenticated runtime producer for that commit and verify its archive.
3. Dispatch trusted staging with the commit, version, unused tag, and producer run ID. Staging builds twice, signs, notarizes, staples, verifies, and retains the exact bytes without publishing a tag or release.
4. Qualify those staged artifacts, including the independent macOS VM lifecycle, and retain the complete evidence export. Obtain protected acceptance of the exact inventory and independent review report.
5. After maintainer approval, promote the accepted bytes without rebuilding. Verify the public downloads against staging, publish the matching vendor-tap formula, and test installation and upgrade from the public channel.
6. Retain post-release canary/support results and close the publication and parent issues when their evidence passes.

RC receipts cannot promote GA: the final version requires its own source, staged bytes, and qualification.

## Immutable Historical Releases

`docs/release/IMMUTABLE_RELEASES.json` records the hashes of historical release notes. Preserve their original bytes. Current references can explain their status; Git history retains superseded planning and development narratives.
