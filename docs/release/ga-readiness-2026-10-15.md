# GA readiness — October 15, 2026

The frozen candidate is `0.0.2-rc.11`, source
[`0b894d2e0fe84a8c57dde8af31b8dd3f1bff23a2`](https://github.com/hostwright/hostwright/commit/0b894d2e0fe84a8c57dde8af31b8dd3f1bff23a2).
Its supported source, sanitizer and timed fuzz checks have completed. Signed
staging passed on attempt 9, and the authenticated package installed successfully
over dev.11 in the qualification VM. The subsequent rollback failed; this is not
a clean RC. No supported RC or GA has been published; the signed dev.12
vendor-tap build remains unsupported.
Official `brew install hostwright` is still a launch requirement.
Current source prepares `0.0.2-rc.12` with the rollback corrections. It requires
a fresh source freeze, runtime producer and candidate qualification; prior
RC.11 results do not qualify RC.12.

## Completed candidate checks

- The supported source matrix passed **3,544 unique cases, zero failures and zero
  skips**, including the ten separately executed live/platform cases. See the
  [source execution and independent review](https://github.com/hostwright/hostwright/issues/271#issuecomment-6135202733).
- ASan and TSan each passed **3,544 unique cases, zero failures and zero skips**.
  Independent review verified their exact instrumented binaries, receipt bindings
  and 326 raw attachments. See the
  [sanitizer results](https://github.com/hostwright/hostwright/issues/271#issuecomment-6148896686).
- Six critical fuzz targets each completed five minutes of fresh fuzzing and
  retained corpus replay. The source-bound completion record has SHA-256
  `37edcf2a56540472484ea5be3816bf6f3ac6bf7a2ac91778e8d700b94e23801d`;
  its raw packet remains retained locally for the release evidence export.
- The exact-source [runtime producer](https://github.com/hostwright/hostwright/actions/runs/38315128694)
  completed. Its authenticated archive was independently verified for staging;
  this does not establish installed-artifact acceptance.
- Both [macOS 26](https://github.com/hostwright/hostwright/actions/runs/38315136313)
  and [macOS 27](https://github.com/hostwright/hostwright/actions/runs/38315143089)
  hosted qualification passed. Their skipped live cells remain separate from
  the attended source evidence above.

## Signed staging and the installed rollback failure

[Trusted staging run 38342055036](https://github.com/hostwright/hostwright/actions/runs/38342055036),
attempt 9, completed native regression, two release builds, signing,
notarization, source binding, hosted attestation and inventory verification. The
native regression executed 3,483 XCTest cases with ten skips and zero failures,
plus 61 passing Swift Testing cases. The ten skipped cells are covered by the
separate supported source matrix above; the native base run itself is not
reported as skip-free.

All 13 native trust stages passed. Those stages are part of qualification and do
not replace the complete 18-gate release contract. Independent review verified
the authenticated artifact bindings, four CMS signatures, payload hashes,
paired dependency inventories and 2,851 nonempty license/notice slices. The
actual signed schema-3 SBOMs retain one P2 file-type finding affecting four
non-text payload paths; subsequent schema-4 artifacts require their own review.

The signed package installed over dev.11 in the owned macOS 26.6.2 / 25G83 VM,
and all 24 installed files matched the expected bytes, modes and ownership.
The owner-state probe reported schema 24. Rollback then failed with exit 72:
the current executable check rejected the historical observation-only daemon,
and compensation also failed. The raw failed cycle, protected journals and
paired state snapshots are retained unchanged. See the
[public failure record](https://github.com/hostwright/hostwright/issues/278#issuecomment-6185484144).
Source corrections and regression tests are under review; the frozen RC.11
source and signed bytes remain unchanged. No re-upgrade or complete installed
lifecycle result is claimed.

## Reviewed release corrections

[PR #388](https://github.com/hostwright/hostwright/pull/388) prevents Python bytecode
caches from dirtying strict source checks.
[PR #389](https://github.com/hostwright/hostwright/pull/389) corrects SPDX file types
and propagates schema 4 through new release manifests and provenance.
[PR #390](https://github.com/hostwright/hostwright/pull/390) reports bounded child
stderr when corresponding-source verification fails. All three are merged after
independent review and applicable CI. The frozen RC.11 source remains unchanged;
new artifact metadata requires verification against the subsequent build bytes.

## Remaining issue gates

| Issue | Required evidence still pending |
| --- | --- |
| [#271](https://github.com/hostwright/hostwright/issues/271) | Ten signed-artifact lifecycle cycles per supported provider and the checkpointed 30-minute physical-host soak. |
| [#275](https://github.com/hostwright/hostwright/issues/275) | Final evidence assembly with the authenticated artifact/security review, explicit schema-3 P2 disposition and independently verified subsequent schema-4 bytes. |
| [#277](https://github.com/hostwright/hostwright/issues/277) | Signed backup, restore and interruption-recovery execution with cleanup and unmanaged-data preservation. |
| [#278](https://github.com/hostwright/hostwright/issues/278) | Resolve the genuine dev.11 rollback/compensation failure, then complete historical upgrades, rollback, repair, interruption recovery and uninstall on a subsequent signed candidate. |
| [#279](https://github.com/hostwright/hostwright/issues/279) | Signed CLI, Compose and desktop quickstarts, then synchronization of README, capability output, references, website, examples and supported matrix. |
| [#281](https://github.com/hostwright/hostwright/issues/281) | Complete clean RC acceptance, qualify final-version bytes, obtain protected promotion approval, publish immutable v0.0.2 and verify the vendor tap. |
| [#282](https://github.com/hostwright/hostwright/issues/282) | Signed cask audits and clean-machine lifecycle on the latest major macOS, official acceptance and a fresh `brew install hostwright`. |

Source-built suite coverage does not replace these installed-artifact checks.
Issues close only on their applicable clean evidence; Phase 15 and the master
issue remain open until their required children complete.

## Timing and distribution

There is no confirmed GA date. Final `0.0.2` bytes require their own qualification.
Official Homebrew acceptance depends on upstream maintainer review and has no
guaranteed completion date. The vendor tap does not establish official short-name
availability. The [current Homebrew package acceptance policy](https://docs.brew.sh/Package-Acceptance-Policy)
sets a higher notability threshold for owner submissions: 90 forks, 90 watchers
or 225 stars, unless maintainers grant an exception. The repository observation
on October 15 was two stars, zero forks and zero watchers. Stable signed bytes,
cask audits and fresh-machine checks therefore do not by themselves establish
upstream eligibility. See the [tracked Homebrew prerequisite](https://github.com/hostwright/hostwright/issues/282#issuecomment-6183829827).

See the [release promotion contract](../reference/release-promotion.md),
[Homebrew distribution requirements](../reference/homebrew-distribution.md), and
[October 14 historical snapshot](ga-readiness-2026-10-14.md).
