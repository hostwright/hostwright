# Release Process

The active release target is `v0.0.2`. The working binary reports `0.0.2-dev` until release qualification is complete.

## Tag Policy

- `phase-*` tags are optional internal engineering checkpoints and never receive GitHub Releases.
- `v*` tags are public releases or explicitly marked release candidates.
- Phase 02 may create one immutable `v0.0.2-dev` GitHub prerelease through the protected trusted-release workflow solely to qualify signed public bytes and the vendor-tap install path. It remains unsupported, cannot be moved or replaced, and does not advance the release ladder.
- Do not create `v0.0.2`, publish a supported package/channel claim, or change the binary to `0.0.2` before the Phase 15 gate.
- Never tag from a dirty tree, an unreviewed commit, or a commit whose required evidence is blocked.
- Never force-move a public release tag.

## Release Ladder

1. `0.0.2-dev` throughout implementation;
2. `v0.0.2-rc.1` only after all 15 phase epics and child issues reach verification;
3. `v0.0.2-rc.2` or later after every defect from the prior clean RC run is fixed and the entire qualification run is repeated;
4. `v0.0.2` only after two clean complete RC qualification runs and final maintainer approval.

An RC tag is a pre-release, not a partial implementation escape hatch. It uses the same supported-scope contract as GA and may differ only by resolved defects and repeated evidence.

The one Phase 02 `v0.0.2-dev` qualification artifact is not an RC or beta and is never promoted in place. Its only purpose is to prove the real distribution path that Phase 02 must close; later implementation continues on `0.0.2-dev`, and Phase 15 produces new immutable RC/GA artifacts from their exact qualified commits.

## Active Roadmap Authority

- [v0.0.2 implementation plan](../roadmap/v0.0.2/IMPLEMENTATION_PLAN.md)
- [machine-readable issue manifest](../roadmap/v0.0.2/issues.json)
- [testing and evidence contract](../reference/testing-evidence.md)
- [evidence JSON schema](../../schemas/hostwright-evidence.schema.json)
- [master release issue #284](https://github.com/hostwright/hostwright/issues/284)

Every child issue, phase epic, and master gate closes through a final `status:verification` PR and clean evidence comment. Intermediate implementation, research, design, and documentation PRs use `Refs #NN`; only the final evidence PR uses `Closes #NN`.

## Baseline Gate for Every Phase and RC

```bash
swift build
swift test list || swift test --list-tests
swift test
scripts/integration.sh
scripts/grep-orchard.sh .
scripts/test.sh
scripts/lint.sh
```

The owning phase adds its required live, migration, security, resilience, multi-host, interoperability, accessibility, distribution, and performance lanes. A command that is unavailable, skipped, blocked, fixture-only, mock-only, dirty, or cleanup-failed is recorded honestly and fails that implementation/release gate.

## Governance Gate

Roadmap manifest validation, issue-parent/label/assignee checks, final-PR evidence enforcement, child closure, security review triggers, and exact public claims must pass. The executable workflow reopens a roadmap issue closed without valid evidence.

## Distribution Readiness Gate

Phase 02 turns the former unsigned developer lane into signed/notarized archives, a `.pkg`, vendor tap, secure install state, and the [strict reversible installed lifecycle](../reference/installed-lifecycle.md). The trusted builder/verifier, Homebrew formula renderer, protected release workflow, and explicit-prefix lifecycle are implemented, but this gate remains open until a credentialed run and public-channel/clean-Mac lifecycle evidence pass. Phase 15 repeats those checks from the final clean tag. The historical `distribution-readiness.md` does not satisfy this gate.

## Benchmark Gate

Phase 10 implements scheduling, pressure, energy, and accelerator measurement; Phase 15 qualifies performance/density/energy budgets on physical hardware. No benchmark, capacity, efficiency, or comparison claim is published from a dirty, incomplete, blocked, scripted, or cleanup-failed report.

## Public Education Gate

Current core docs and `hostwright capabilities --json` are the product-truth source. The separate website must typecheck, build, pass internal-link checks, execute every documented quickstart, and agree on version, install, limitation, compatibility, and roadmap claims.

## Beta Readiness Gate

The former beta checklist is historical. The active pre-GA gate is a complete `v0.0.2-rc.*` qualification run over the same intended GA scope; an RC cannot omit an unimplemented phase or downgrade a blocker into a known limitation.

## v0.0.2 GA Gate

All of the following are required:

- all 167 workstreams, 15 phase epics, and the master issue are complete;
- zero unresolved P0/P1 defects;
- exact current/previous supported macOS, Apple `container`, Kubernetes, Docker API, and client-family matrices are frozen from passing evidence;
- Apple CLI and pinned Containerization providers pass declared-capability conformance;
- 10,000 lifecycle cycles and a 72-hour single-host soak pass without duplicate resources, unmanaged mutation, or monotonic leaks;
- physical three- and five-Mac fault matrices and a seven-day mixed-fault soak pass, including safe read-only behavior without quorum;
- every critical parser/protocol receives at least 24 aggregate fuzz CPU-hours;
- supported ASan and TSan lanes pass;
- independent security assessment findings required for release are remediated and retested;
- dependency, license, secret, SAST, SBOM, signature, vulnerability, and provenance gates pass;
- performance, density, energy, upgrade lineage, rollback, disaster recovery, compatibility, and accessibility gates pass;
- every documentation quickstart executes and website typecheck/build/link checks pass;
- signed/notarized archives and `.pkg` pass checksum, stapling, Gatekeeper, clean install, reboot, upgrade, rollback, repair, and uninstall;
- the vendor Homebrew tap installs those exact verified artifacts;
- two complete clean RC qualification runs pass.

## Artifact and Package Policy

The release publishes only artifacts produced from the final clean tag by the reviewed release workflow:

- signed/notarized Apple-silicon archive;
- signed/notarized `.pkg`;
- checksums;
- SPDX SBOM;
- signed provenance/attestation;
- verification instructions and compatibility manifest;
- vendor-tap formula bound to the released digest.

Unsigned developer `hostwright-dist` output is useful local integration evidence, not a public release artifact.

The protected workflow retains its exact verified bundle for 90 days. Published release assets and the corresponding checksums, SBOMs, provenance, manifest, detached signatures, and evidence are retained indefinitely and are not replaced in place. Exceptional removal is a separate reviewed repository action; it is never an automatic workflow cleanup step.

`brew install hostwright` depends on Homebrew-core acceptance. Phase 15 submits the formula after GA artifact evidence passes. The Hostwright-controlled fallback is the vendor tap; documentation must not claim the unqualified command before core acceptance.

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
7. submit the Homebrew-core formula separately and report its external acceptance state exactly;
8. run the post-release canary/support checks and retain release evidence according to policy.

## Immutable Historical Releases

Historical release notes keep their original text and claims. `docs/release/IMMUTABLE_RELEASES.json` records their SHA-256. They may be annotated through separate index/current docs but are not rewritten to make history resemble the current roadmap. The former alpha plan and development logs are historical evidence, not active release instructions.
