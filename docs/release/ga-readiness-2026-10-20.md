# GA readiness — October 20, 2026

Candidate `0.0.2-rc.13` is frozen at
`c0f63020f1c4187623d48d9c0770679b8b0de0d1`. Its exact-source runtime
producer passed and its archive is authenticated and independently verified.
Signed staging attempt 2 passed. Installed-artifact qualification remains required.
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

The [runtime-pin and evidence correction](https://github.com/hostwright/hostwright/pull/407)
is merged. Its reviewed tree matches the frozen candidate tree. The
[exact-candidate runtime producer](https://github.com/hostwright/hostwright/actions/runs/39171521610),
attempt 1, passed. Its retained runtime archive has SHA-256
`6fcbc4a5f1dccb187e3bb3d0b22f18299e66dc4b5fa25b7380faa2a5e2ba9a2a`.
Independent verification checked the authenticated archive and its payloads.

As of October 19, the full ordinary source matrix passed 3,556 unique tests,
zero failures and zero skips, including all ten routed live selectors. Its frozen
matrix verifier and independent outcome review passed.

The [derived RC.13 evidence summary](../evidence/phase15-rc13-c0f63020/README.md)
publishes the matrix, gate and independent-review hashes. The complete raw
qualification packet remains retained separately.

Each sanitizer has 3,546 base passes and all ten unique routed live tests now
passed separately. The actual Local Network allowed, denied and restored controls
passed for both lanes, and all 48 original host permission entries were restored.
Each VM stopped naturally with unchanged configuration. The restored control is
an extra execution, not an eleventh unique selector. The frozen matrix verifier
and final independent outcome review accepted each complete sanitizer suite:
3,556 passed, zero failures and zero skips. This covers the compiled instrumented
host tests; complete helper child at-exit diagnostics remain unclaimed.

Hosted macOS 26 and 27 qualification and the six-target fuzz campaign also passed.
The fuzz campaign recorded 5,080,658 timed executions and no crash artifacts;
hosted live skips provide no live-runtime credit. Original fixture failures and
additive recovery records remain retained under their actual attempts.

The exact [RC.13 staging run](https://github.com/hostwright/hostwright/actions/runs/39294412896), attempt 2, passed native regression, build equality, signing, notarization, trust checks, corresponding-source verification and hosted attestation. Its immutable inputs use frozen commit `c0f63020f1c4187623d48d9c0770679b8b0de0d1`, version `0.0.2-rc.13`, planned tag `v0.0.2-rc.13` and runtime producer `39171521610`. Attempt 1 remains recorded as cancelled during the operator-requested pause.

Independent verification checked seven hosted provenance subjects and both exact SPDX 2.3 predicates. The native signed-release verifier passed on a byte-identical projection with the documented sidecar modes; the original mode-rejection attempt remains retained and uncredited. The [supply-chain evidence](../evidence/phase15-rc13-c0f63020/supply-chain.md) records the signed-byte hashes, security assessment scope and retained limitations. Individual signed-artifact, license/SBOM, secret-policy and dependency-security gate receipts pass the unchanged frozen validator. The current-byte vulnerability assessment retains explicit exceptions and its advisory-data dates. Issue #275 closure additionally requires the reviewed verification PR and final evidence record.

Installed lifecycle, provider conformance, physical-host soak, backup/recovery, executed quickstarts, protected aggregate acceptance and final release publication remain required. No RC or GA acceptance is claimed by these individual checks.

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
