# GA readiness — October 9, 2026

RC.7 at `31e7c58c99fcd3747fbf04c4e72d4d6a85db2842` was rejected before
staging. Its macOS 27 build failed at the Docker proxy entry point. A traced
integration rerun also found that macOS Bash 3.2 did not stop after failed
standalone compound assertions. [PR #377](https://github.com/hostwright/hostwright/pull/377)
corrects both problems, validates the precise unsigned source-build doctor result,
and adds regression coverage. A new candidate requires fresh applicable qualification.

No supported RC or GA has been published. The older signed dev.12 vendor-tap
release remains unsupported. Official `brew install hostwright` is unavailable
until the signed package qualifies and Homebrew accepts the cask.

## Completed preparation

- The executable ACL correction is merged and independently reviewed.
- [PR #375](https://github.com/hostwright/hostwright/pull/375) fixes the macOS 27
  qualification launcher and records the actual checked-out source and environment.
- [PR #376](https://github.com/hostwright/hostwright/pull/376) overlaps SDK download
  with independent Linux setup and waits before authenticated verification and use.
  The pinned SDK compilation recipe remains unchanged.
- The website Workers build is repaired and deployed through
  [website PR #18](https://github.com/hostwright/hostwright.dev/pull/18).
  Production checks, public content, redirects and the 404 page passed verification.

## Issue gates

| Issue | Required completion |
| --- | --- |
| [#271](https://github.com/hostwright/hostwright/issues/271) | Corrected-candidate compatibility, supported sanitizers, timed fuzz targets, physical/VM cells and provider lifecycle evidence. |
| [#272](https://github.com/hostwright/hostwright/issues/272) | Source-security assessment passed: 344 focused Swift tests, 96 supporting Python tests, five process cases and corrected integration. See the [independent assessment](../evidence/phase15-security-7bd3575f/issue272-public-final-assessment.md). |
| [#275](https://github.com/hostwright/hostwright/issues/275) | Assess the signed inventory, SBOM, dependency findings, signatures, provenance and retained object variance. |
| [#277](https://github.com/hostwright/hostwright/issues/277) | Complete backup and interruption recovery evidence. |
| [#278](https://github.com/hostwright/hostwright/issues/278) | Complete all twelve signed VM lifecycle operations, including historical upgrades, rollback, repair and uninstall. |
| [#279](https://github.com/hostwright/hostwright/issues/279) | Execute signed CLI, Compose and desktop quickstarts and synchronize their published claims. |
| [#281](https://github.com/hostwright/hostwright/issues/281) | Qualify the RC and final-version bytes, obtain independent signed-lifecycle verification, accept all eighteen release gates and verify protected publication/vendor-tap installation. |
| [#282](https://github.com/hostwright/hostwright/issues/282) | Qualify the signed cask on the latest major macOS, obtain official acceptance and verify a fresh no-tap installation. |

Source-security assessment is separate from signed-artifact security and live
qualification. Each issue closes only on its applicable evidence. The phase and
master gates remain open until all required children pass.

## Retained qualification history

The first RC.7 source run reported 3,527 passes, six failures and ten attended
cases skipped. All six failures came from checkout-derived Unix socket paths
that exceeded the listener limit. The same frozen source in a shorter checkout
reported 3,533 passes, no failures and ten attended cases skipped. Those attended
cases still require applicable live execution; these results do not qualify a release.

The [macOS 26 run](https://github.com/hostwright/hostwright/actions/runs/37949972894)
passed 37 release and 54 distribution tests; its six live cases did not execute.
The [macOS 27 run](https://github.com/hostwright/hostwright/actions/runs/37958753352)
failed compilation. Failed runs and the ineffective historical shell assertions
remain recorded. Their results are not transferred to a corrected candidate.

## Timing

There is no confirmed GA date. Automated candidate checks, signed Mac/VM lifecycle
and desktop checks, provider cycles, recovery and the physical-host soak remain.
Final `0.0.2` artifacts need their own qualification. Homebrew review is external
and has no guaranteed completion date.

See the [release promotion contract](../reference/release-promotion.md) and
[Homebrew distribution requirements](../reference/homebrew-distribution.md).
