# Release Process

The active release target is `v0.0.2`. The working binary remains on the
`0.0.2-dev` line until release qualification is complete. Phase 02 preserves
immutable `v0.0.2-dev.11` (`7d97d6c9ff878ec567c88e6993d4543ab8f0ad95`)
and `v0.0.2-dev.12` (`71414005104933d8ee3591e8c91bc831bce2e2a2`)
qualification builds for upgrade evidence.

## Tag Policy

- `phase-*` tags are optional internal engineering checkpoints and never receive GitHub Releases.
- `v*` tags are public releases or explicitly marked release candidates.
- Phase 02 created the immutable `v0.0.2-dev.11` and `v0.0.2-dev.12` GitHub prereleases through the protected trusted-release workflow solely to qualify signed public bytes and the vendor-tap upgrade path. They remain unsupported, cannot be moved or replaced, and do not advance the release ladder.
- Do not create `v0.0.2`, publish a supported package/channel claim, or change the binary to `0.0.2` before the Phase 15 gate.
- Never tag from a dirty tree, an unreviewed commit, or a commit whose required evidence is blocked.
- Never force-move a public release tag.

## Release Ladder

1. the `0.0.2-dev` line throughout implementation, including the preserved Phase 02 dev.11 and dev.12 qualification builds;
2. `v0.0.2-rc.1` after required local implementation issues reach verification and the Phase 15 lanes are ready;
3. fix RC defects and repeat affected qualification on the corrected candidate;
4. `v0.0.2` after one clean complete RC qualification, independent signed-artifact lifecycle verification, final-version qualification and maintainer approval. Release artifact and master issues close after publication verification.

An RC tag is a pre-release, not a partial implementation escape hatch. It uses the same supported-scope contract as GA and may differ only by resolved defects and repeated evidence.

The two Phase 02 `v0.0.2-dev.11` and `v0.0.2-dev.12` qualification artifacts are not RCs or betas and are never promoted in place. Their only purpose is to prove the real installation and upgrade path required for Phase 02 qualification; later implementation continues on the `0.0.2-dev` line, and Phase 15 produces new immutable RC/GA artifacts from its exact qualified commits.

## Active Roadmap Authority

- [v0.0.2 implementation plan](../roadmap/v0.0.2/IMPLEMENTATION_PLAN.md)
- [machine-readable issue manifest](../roadmap/v0.0.2/issues.json)
- [testing and evidence contract](../reference/testing-evidence.md)
- [evidence JSON schema](../../schemas/hostwright-evidence.schema.json)
- [master release issue #284](https://github.com/hostwright/hostwright/issues/284)

Every required child issue, phase epic, and master gate closes through a final `status:verification` PR and clean evidence comment. Deferred issues close explicitly as `not_planned` under the merged [ADR 0015](../design/adr-0015-reduced-local-release.md), with matching child dispositions; they are not completed implementation. Intermediate implementation, research, design, and documentation PRs use `Refs #NN`; only the final evidence PR uses `Closes #NN`.

## Baseline Gate for Every Phase and RC

```bash
scripts/test.sh pr
```

The owning phase adds its required live, migration, security, resilience, declared interoperability, accessibility, distribution, and performance lanes. A command that is unavailable, skipped, blocked, fixture-only, mock-only, dirty, or cleanup-failed is recorded honestly and fails that implementation/release gate.

## Governance Gate

Roadmap manifest validation, issue-parent/label/assignee checks, final-PR evidence enforcement, child closure, security review triggers, and exact public claims must pass. The executable workflow reopens required issues without valid evidence and deferred issues without an explicit recorded not-planned scope decision. Required parents require completed required children and correctly deferred children.

## Distribution Readiness Gate

Phase 02 turned the former unsigned developer lane into signed/notarized archives, a `.pkg`, vendor tap, secure install state, and the [strict reversible installed lifecycle](../reference/installed-lifecycle.md). Its credentialed dev.11/dev.12 releases, public-byte verification, vendor-tap install/upgrade, clean macOS 26 lifecycle, state, doctor, abrupt-power, and exact-cleanup gates passed. Phase 15 repeats those checks from the final clean tag. The historical `distribution-readiness.md` does not satisfy the GA gate.

## Benchmark Gate

Phase 10 qualifies local admission and safe pressure deferral; Phase 15 records bounded local timings and resource stability on the M4 Pro. Broad density, energy, accelerator and cluster-scale claims are deferred. No benchmark, capacity, efficiency, or comparison claim is published from a dirty, incomplete, blocked, scripted, or cleanup-failed report.

## Public Education Gate

Current core docs and `hostwright capabilities --json` are the product-truth source. The separate website must typecheck, build, pass internal-link checks, execute every documented quickstart, and agree on version, install, limitation, compatibility, and roadmap claims.

## Beta Readiness Gate

The former beta checklist is historical. The active pre-GA gate is a complete `v0.0.2-rc.*` qualification run over the same intended GA scope; an RC cannot omit a retained requirement or downgrade a blocker into a known limitation. Deferred requirements are explicitly recorded in the issue manifest.

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

The release publishes only artifacts produced from the final clean tag by the reviewed release workflow:

- signed/notarized Apple-silicon archive containing the local CLI, desktop app and required helpers;
- signed/notarized `.pkg`;
- checksums;
- SPDX SBOM;
- signed provenance/attestation;
- verification instructions and compatibility manifest;
- vendor-tap formula bound to the released digest.

Unsigned developer `hostwright-dist` output is useful local integration evidence, not a public release artifact.

The protected workflow retains its exact verified bundle for 90 days. Published release assets and the corresponding checksums, SBOMs, provenance, manifest, detached signatures, and evidence are retained indefinitely and are not replaced in place. Exceptional removal is a separate reviewed repository action; it is never an automatic workflow cleanup step.

`brew install hostwright` depends on Homebrew-core acceptance. Homebrew-core submission is deferred from v0.0.2. The Hostwright-controlled qualification channel is available now as `brew install hostwright/tap/hostwright`; documentation must not claim the unqualified command before core acceptance.

## Final Evidence Record

The final evidence comment contains:

```text
<!-- hostwright-evidence-gate:v1 -->
```

It records the full commit, `Dirty: false`, OS/build/architecture/hardware, runtime/framework/tool versions, every command and raw outcome, failures, blockers, cleanup and exact resource identifiers, artifact links, and documentation/compatibility updates. Public logs are redacted without removing result counts or the ability to audit the claim.

## Promotion Steps

Only after the final RC evidence and approval:

1. verify the release commit is on protected `main`, clean, signed according to policy, and identical to the qualified commit;
2. set the product version from `0.0.2-dev` to `0.0.2` in a reviewed release PR and rerun the complete release gate;
3. dispatch the protected trusted-release workflow for the exact qualified commit/version/tag;
4. let that workflow build, sign, notarize, staple, verify, create the immutable annotated tag, publish, download, compare, and attest the exact bytes;
5. verify clean installation, upgrade, rollback, and uninstall from the published channel;
6. publish the GitHub Release and vendor-tap formula only after artifact verification;
7. retain the explicit Homebrew-core deferral and publish only the verified vendor-tap installation claim;
8. run the post-release canary/support checks and retain release evidence according to policy.

## Immutable Historical Releases

Historical release notes keep their original text and claims. `docs/release/IMMUTABLE_RELEASES.json` records their SHA-256. They may be annotated through separate index/current docs but are not rewritten to make history resemble the current roadmap. The former alpha plan and development logs are historical evidence, not active release instructions.
