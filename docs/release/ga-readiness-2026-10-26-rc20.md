# GA readiness — RC.20 preparation, October 26, 2026

Current source prepares `0.0.2-rc.20`. No supported RC or GA has been published. Manifest v3, Control API 2.2, state schema v24 and the single-Mac CLI, desktop and narrow Compose scope remain unchanged.

## Closing repair and retained evidence

[PR #423](https://github.com/hostwright/hostwright/pull/423) adds the upstream perf kernel-callchain permission fix for CVE-2026-98937 and inode xarray cleanup for CVE-2026-99080. Two independent Linux arm64 builds produced matching kernel images and configurations. The replacement image is 16,151,040 bytes with SHA-256 `d6bfd6eeaf5b4f8af446159df8a00aea5f4c04e3be9222082664f17980d7d607`. All nine patches and the embedded configuration were reviewed. These are verified runtime inputs, not complete release qualification.

The [correction on #281](https://github.com/hostwright/hostwright/issues/281#issuecomment-6423790678) records that CVE-2026-98983 does not apply to the exact Linux 6.18.55 source: the affected newer namespace active-reference machinery is absent. No namespace patch or policy exception was added.

RC.19 internal signing/staging was cancelled during its mandatory regression step after the kernel advisory review; no completed signed RC.19 artifacts or release acceptance exist. Its separate ordinary source-test base passed with ten routed skips, and six routed source cases subsequently passed; four attended network cases remained unfinished. Both full sanitizer matrices, artifact-bound provider, recovery, lifecycle, desktop and quickstart gates remain required for the replacement candidate. Earlier source, fuzz, hosted macOS and security results retain their original bindings.

The replacement retains the port-reservation and SQLite repairs, isolated TLS qualification fixture, managed-daemon correction and optional preferences-only Homebrew cleanup. The passing RC.19 macOS distribution shards remain historical evidence; they do not establish RC.20 payload reproducibility. Strict executable equality remains required.

[Website PR #33](https://github.com/hostwright/hostwright.dev/pull/33) passed both packages' typecheck, build and link checks, both high-severity audits, deployment and five public-page checks. That evidence remains bound to its website commit. Updated candidate-status copy requires its own checks, and signed CLI, Compose and desktop quickstarts remain open.

The [RC.19 preparation record](ga-readiness-2026-10-25-rc19.md) and original raw results remain unchanged.

## Bounded closing sequence

1. Review and merge the actual runtime-pin and candidate-version changes after current-head checks pass. Freeze one exact clean candidate before qualification.
2. Run each missing mandatory qualification once against that candidate. Reuse passing evidence only under its valid source, version, artifact, environment or unchanged-input binding. Retain failed and interrupted runs. Overlap independent hosted work with local checks and run only one heavy Swift process on the physical Mac.
3. Obtain protected RC acceptance after all eighteen gates pass, including both full sanitizers, six timed fuzz targets, security, three provider lanes with ten cycles each, the thirty-minute soak, eight recovery and twelve signed VM lifecycle operations, quickstarts, accessibility and independent review.
4. After RC acceptance, make one reviewed final `0.0.2` version change. Qualify, accept and promote the exact final signed bytes, then verify public downloads and vendor-tap installation before closing #281.
5. Qualify and submit the official cask against those stable public bytes. Close #282, #283 and #284 only after official acceptance and a fresh-machine `brew install hostwright` pass.

Start no new repair round after 8 p.m. Eastern. Stop at 11:59 p.m. Eastern on October 26 with completed GA or a precise unfinished-gate report. Missing credentials, lab capacity, signing or external review remain blockers and trigger no automatic retries or scope expansion. If only Homebrew review remains, retain the qualified published artifacts and stop testing while awaiting actionable feedback.

See the [acceptance contract](../reference/release-promotion.md).
