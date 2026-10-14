# GA readiness — October 14, 2026

The frozen candidate is `0.0.2-rc.11`, source
[`0b894d2e0fe84a8c57dde8af31b8dd3f1bff23a2`](https://github.com/hostwright/hostwright/commit/0b894d2e0fe84a8c57dde8af31b8dd3f1bff23a2).
Its supported source, sanitizer and timed fuzz checks have completed. Signed
staging and installed-artifact qualification remain pending. No supported RC or
GA has been published; the signed dev.12 vendor-tap build remains unsupported.
Official `brew install hostwright` is still a launch requirement.

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

The protected staging run has not retained an accepted signed bundle. A prior
build/sign/notarize/verify step passed, but subsequent source binding failed.
That run cannot supply signed installation or lifecycle evidence.

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
| [#275](https://github.com/hostwright/hostwright/issues/275) | Final signed inventory, accurate SBOM, dependency and license assessment, signatures, checksums, provenance and retained object-variance assessment. |
| [#277](https://github.com/hostwright/hostwright/issues/277) | Signed backup, restore and interruption-recovery execution with cleanup and unmanaged-data preservation. |
| [#278](https://github.com/hostwright/hostwright/issues/278) | Independent signed VM install, historical upgrades, rollback, repair, interruption recovery and uninstall. |
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
availability.

See the [release promotion contract](../reference/release-promotion.md),
[Homebrew distribution requirements](../reference/homebrew-distribution.md), and
[October 9 historical snapshot](ga-readiness-2026-10-09.md).
