# GA readiness — October 18, 2026

Current source prepares `0.0.2-rc.13`. A fresh freeze, exact-source runtime
producer, signed staging and installed-artifact qualification remain required.
No supported RC or GA has been published. Official `brew install hostwright`
remains unavailable pending the accepted stable release and Homebrew review.

## RC.13 preparation

Three reviewed corrections are merged:

- [#401](https://github.com/hostwright/hostwright/pull/401) applies the complete
  IPVS inner-header validation and serial registration cleanup fixes to Linux
  6.18.55.
- [#402](https://github.com/hostwright/hostwright/pull/402) derives guest dependency
  inventory and license metadata from the authenticated patched source closure.
- [#403](https://github.com/hostwright/hostwright/pull/403) updates the guest
  SwiftNIO pin to 2.101.3 and its reviewed source revision.

The [ingredient producer](https://github.com/hostwright/hostwright/actions/runs/38944254249),
attempt 1, passed on source
`bd8f154f278cb650493c2813d4ecc07cd90838d8`. Its native artifact is
`12070778699`, 6,958,937,411 bytes, SHA-256
`e9cac586a1e51130e4943b1de28d70175b6d3cc6392095109f01cd2617809b28`.
Local intake matched the complete ZIP digest, checked all 26,329 listed files
and authenticated its three hosted subjects against that exact run. The
verified native fragment and sidecars contain 9,345 files totaling
5,738,623,455 bytes. The loader closure was retained and independently reviewed
separately.

This ingredient-only run supplies reviewed input for the runtime-pin update.
It does not supply the final candidate's authenticated runtime archive, signed
artifacts or release acceptance. The original intake's file-count rejection is
retained separately; its successful download was verified and reused without
replacing the failure record.

The pending [repository security update](https://github.com/hostwright/hostwright/pull/405)
also changes the guest networking dependency closure. Before freezing RC.13,
that update needs review and passing checks, followed by fresh loader bytes and
matching runtime, source and license pins. The retained ingredient loader does
not qualify those newer dependencies.

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
