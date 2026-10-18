# GA readiness — October 18, 2026

Current source prepares `0.0.2-rc.13`. A fresh freeze, exact-source runtime
producer, signed staging and installed-artifact qualification remain required.
No supported RC or GA has been published. Official `brew install hostwright`
remains unavailable pending the accepted stable release and Homebrew review.

## RC.13 preparation

Four reviewed corrections are merged:

- [#401](https://github.com/hostwright/hostwright/pull/401) applies the complete
  IPVS inner-header validation and serial registration cleanup fixes to Linux
  6.18.55.
- [#402](https://github.com/hostwright/hostwright/pull/402) derives guest dependency
  inventory and license metadata from the authenticated patched source closure.
- [#403](https://github.com/hostwright/hostwright/pull/403) updates the guest
  SwiftNIO pin to 2.101.3 and its reviewed source revision.
- [#406](https://github.com/hostwright/hostwright/pull/406) synchronizes the
  RC.13 preparation identity, native runtime pins, license inventory and public
  readiness documentation.

The [security ingredient producer](https://github.com/hostwright/hostwright/actions/runs/39148502792),
attempt 1, passed on preparation branch source
`68e436dcd3d53d0844eb7f536e8357332eb6520e`. Its native artifact is
`12146988208`, 6,961,108,728 bytes, SHA-256
`9ae0c75d0dc212562faad944761ecede15b9f15fa57058e399c116472341ef14`.
Local intake matched the complete ZIP digest, checked all 26,329 listed files
and authenticated its three hosted subjects against that exact branch run.
The independently verified native fragment and sidecars contain 9,345 files
totaling 5,738,623,455 bytes.

The matching loader artifact, `12144770740`, supplies the freshly rebuilt
`hostwright-netfilter`: 2,949,246 bytes, SHA-256
`eec0f5c4528f87cf89724474c48dc69fa1bec1511f42e06b3ad9e400b19a2fda`.
Its six hosted subjects and extracted source closure passed independent review.
The loader uses Go 1.26.5, `golang.org/x/net` 0.61.0 and `golang.org/x/sys`
0.49.0. Inventory regeneration binds the actual binary, all twenty retained
loader source files, the seven declared Go dependency tuples and corresponding
license texts. Six linked modules have captured source/license coverage; the
resolved-only `go-cmp` tuple retains its existing exact license receipt.

This preparation integrates the
[repository security update](https://github.com/hostwright/hostwright/pull/405)
with matching rebuilt loader and generated inventories. The earlier CI rejection
of mismatched Go source checksums remains a failed result; passing checks on the
complete updated source are required before freeze.

These ingredient-only results are preparation evidence from the exact branch.
They do not authenticate a final main-branch runtime archive or qualify signed
RC.13 artifacts. The final merged candidate still requires its own exact-source
producer and protected signed staging. No older source or artifact result is
relabelled as RC.13 qualification.

The earlier [native ingredient run](https://github.com/hostwright/hostwright/actions/runs/38944254249)
on `bd8f154f278cb650493c2813d4ecc07cd90838d8` remains retained under its
original source binding. Its initial file-count rejection and subsequent
successful intake remain separate records.

## Remaining issue gates

| Issue | Evidence required before closure |
| --- | --- |
| [#275](https://github.com/hostwright/hostwright/issues/275) | Fresh final source and signed-artifact security, accurate dependency/license inventories, SBOM, signatures, checksums, provenance and current vulnerability assessment. |
| [#271](https://github.com/hostwright/hostwright/issues/271) | Exact physical/VM compatibility results, declared provider conformance, ten installed lifecycle cycles per provider and the checkpointed 30-minute physical-host soak. |
| [#277](https://github.com/hostwright/hostwright/issues/277) | Actual local backup/restore, interrupted-operation recovery, cancellation and owned-resource cleanup. |
| [#278](https://github.com/hostwright/hostwright/issues/278) | Signed dev.11/dev.12 upgrade routes, downgrade refusal, rollback, interruption recovery, repair and uninstall in the clean VM. |
| [#279](https://github.com/hostwright/hostwright/issues/279) | Executed CLI, Compose and desktop quickstarts; synchronized README, references, examples and website; website build, links and accessibility results. |
| [#281](https://github.com/hostwright/hostwright/issues/281) | One complete clean RC, independent signed-artifact lifecycle verification, final-version qualification, immutable stable publication and verified vendor-tap installation. |
| [#282](https://github.com/hostwright/hostwright/issues/282) | Stable signed-package cask audits and lifecycle tests, latest-major macOS installation, official Homebrew acceptance and fresh-machine `brew install hostwright`. |

The [Phase 15](https://github.com/hostwright/hostwright/issues/283) and
[release](https://github.com/hostwright/hostwright/issues/284) parents remain open
until their required children and publication checks pass. Homebrew acceptance
is an external review dependency; no acceptance date is promised.

## Retained RC.12 results

Frozen `0.0.2-rc.12`, source
`aa8586a1ccc7887f7ae09dcccdc32bf13c27c705`, remains unchanged and unaccepted.
Its [source and sanitizer results](../evidence/phase15-rc12-aa8586a1/README.md),
[runtime and fuzz results](../evidence/phase15-rc12-aa8586a1/runtime-and-fuzz-summary.json)
and [October 15–16 readiness record](ga-readiness-2026-10-15.md) retain the
passing checks, raw failures and limitations under their original bindings.
Those results do not qualify RC.13 source or artifacts.

RC.12 signed staging passed build equality, signing, notarization, Gatekeeper,
corresponding-source and attestation checks. Independent inspection then found
incorrect guest dependency revisions in the inventory, and advisory review
identified compiled kernel vulnerabilities and the guest SwiftNIO assessment.
The merged source corrections above require fresh built and signed evidence.
