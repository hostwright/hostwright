# GA readiness snapshot — October 8, 2026

Product qualification estimate: **October 10–12, 2026**, conditional on RC.6 passing without
another product correction and timely access to the Mac, privileged installation,
independent review and protected release approvals. October 11 is the stretch
target for this week; October 12 is the safer working date. This is an engineering
estimate, not release evidence or a publication commitment. The subsequent
October 8 request adds official Homebrew acceptance to the launch goal; the
combined GA/Homebrew launch date is unconfirmed because maintainers control
acceptance. The local scope change returns #282 to required work, pending GitHub
synchronization and reviewed merge.

## Current candidate

[PR #369](https://github.com/hostwright/hostwright/pull/369) merged as
`e8bc8a3dfa9f1f8d9caf6cab82d0712dd8cdc68d`, with version `0.0.2-rc.6`.
Its clean qualification checkout is separate from the older developer checkout.
Required CI passed at the reviewed head; that does not complete the release matrix.

At the 15:56 UTC snapshot, the exact-source
[runtime producer](https://github.com/hostwright/hostwright/actions/runs/37795746430)
is running. The release
[qualification shards](https://github.com/hostwright/hostwright/actions/runs/37795756601)
job succeeded; the distribution shard is still running. The live job is green,
but its log reports six tests and six skips. It provides no passing live-runtime
qualification. No signed RC.6 stage, protected acceptance, RC publication or GA
publication is established by this snapshot.

The first local full-source attempt failed during compilation, before tests ran.
Swift reported that `SwiftShims` precompiled modules were created under the
`phase15-scheduler-qualification` module-cache path but loaded from `phase15-rc6`.
The runner then failed its compiled-inventory assertion because no test binary
existed. The active qualification chat preserved that attempt separately and
started a fresh-module-cache retry at 15:04 UTC. The retry remains in progress;
neither this diagnosis nor the retry launch establishes a passing run. That chat
owns the qualification checkout and its serialized build queue.

## Remaining closure work

Seven Phase 15 child issues remain open on GitHub, plus the phase and master gates.
Closed workstreams retain historical evidence; final acceptance still requires
the exact candidate and then the exact GA version.

| Work | Required completion |
| --- | --- |
| Compatibility/current-source qualification, #271 | Recover the build; complete source identity coverage, both sanitizer suites, six five-minute fuzz targets, attended cells, provider conformance and ten cycles for each declared provider/version. |
| Security/supply chain, #272 and #275 | Assess scanner findings and the historical object variance; verify final SBOM/source/signatures/provenance; obtain independent review with zero unresolved P0/P1 findings. |
| Recovery/upgrade lineage, #277 and #278 | Complete state/data backup and interruption recovery plus all twelve signed VM operations, including baseline upgrades, rollback, re-upgrade, repair and uninstall. |
| Public education, #279 | Execute CLI, Compose and desktop quickstarts against the artifacts; bind six website checks to a clean website commit and synchronize published claims. |
| Signed release, #281 | Qualify a complete RC, qualify final-version artifacts, assemble/accept eighteen gates, publish through protected promotion, verify public bytes and vendor-tap installation. |
| Phase/master, #283 and #284 | Close after required children and publication verification are complete. |

The current source-security receipt says `requires-assessment`, with sixteen
redacted secret-scanner findings and thirteen dependency advisory groups. These
are scanner findings, not confirmed exploitable defects. Source call analysis
does not replace artifact assessment or independent review.

The eighteen gate keys and fields are authoritative in
[staged-release.py](../../scripts/release/staged-release.py) and
[accept-qualification.py](../../scripts/release/accept-qualification.py). The
[promotion contract](../reference/release-promotion.md) specifies artifact bindings,
attachments, VM/recovery operations and cleanup evidence.

## Critical path and forecast

| Window | Target |
| --- | --- |
| October 8–9 | Recover the source build; finish serialized source/sanitizer/fuzz execution and authenticated runtime ingredients; produce the signed RC stage. |
| October 9–10 | Complete attended provider/desktop/Compose/recovery/VM checks, thirty-minute soak, security assessment and independent review; accept complete RC evidence. |
| October 10–12 | Qualify final-version bytes; obtain protected acceptance; publish and verify archive/package/vendor tap; close the release gates. |

The lab runs one heavy Swift process at a time. Builds, repeated artifact
qualification and attended VM operations dominate; nominal fuzz/soak durations
are not total release effort. A new source defect, missing independent review,
unavailable privileged/GUI access or failed upgrade route moves the forecast.
RC evidence cannot be relabelled as GA evidence.

The [Homebrew guide](../reference/homebrew-distribution.md) separates the vendor
channel from official submission and documents the added launch requirement.
The seven-open-child count above records GitHub before #282 is reopened; the
amended local plan has eight unfinished required child workstreams.
