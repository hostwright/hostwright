# GA readiness — RC.19 preparation, October 25, 2026

Current source prepares `0.0.2-rc.19`. No supported RC or GA has been published. Manifest v3, Control API 2.2, state schema v24 and the single-Mac CLI, desktop and narrow Compose scope remain unchanged.

## Closing repairs and retained evidence

[PR #421](https://github.com/hostwright/hostwright/pull/421) isolates each positive TLS request's backend from the expected unauthenticated TLS rejection timeout. All 25 focused ingress tests passed. The authentication and fail-closed assertions remain in place; no production TLS code changed. Required current-head CI passed before merge. Its optional Swift/C security scan does not establish this replacement candidate's security qualification.

The Homebrew cask declares optional trashing of only the desktop preferences plist. Its normal managed uninstall still preserves workload state and user data. All ten renderer boundary tests and independent review passed; real signed-package installation and Homebrew acceptance remain required.

RC.18's full source run failed one ingress case. Its macOS 26 distribution shard also found differing final executable bytes between isolated release builds. The original macOS 27 qualification and exact-source runtime producer passed. All results retain their original source and version bindings; they do not qualify this replacement. One exact-source payload diagnostic is investigating the macOS 26 failure. Strict executable hash equality remains required.

[Website PR #33](https://github.com/hostwright/hostwright.dev/pull/33) passed both packages' typecheck, build and link checks, both high-severity audits, production deployment and five public-page checks. That evidence remains bound to its website commit. Candidate-status edits need their own checks, and signed CLI, Compose and desktop quickstarts remain open.

The [RC.18 record](ga-readiness-2026-10-25-rc18.md) and earlier evidence remain unchanged. Clean macOS 27 lab readiness establishes available capacity, not installation or signed-artifact qualification.

## Bounded closing sequence

1. Finish the current repair round, review the complete diff and merge only after current-head checks pass. Freeze one exact clean candidate; start no qualification against changing source.
2. Run each missing mandatory qualification once against that candidate. Preserve valid input and website evidence under its existing bindings. New source, version and artifact bindings require their own results. Overlap hosted jobs with local work and run only one heavy Swift process on the physical Mac.
3. Obtain protected RC acceptance after all eighteen gates pass, including both full sanitizers, fuzzing, security, three provider lanes with ten cycles each, the thirty-minute soak, eight recovery and twelve signed VM lifecycle operations, quickstarts, accessibility and independent review.
4. Make one reviewed final `0.0.2` version change after RC acceptance. Qualify, accept and promote the exact final signed bytes, then verify public downloads and vendor-tap installation before closing #281.
5. Qualify and submit the official cask against those stable public bytes. Close #282, #283 and #284 only after official acceptance and a fresh-machine `brew install hostwright` pass.

Start no new repair round after 8 p.m. Eastern. Stop at 11:59 p.m. Eastern on October 25 with completed GA or a precise unfinished-gate report. Missing credentials, lab capacity, signing or external review are blockers; they trigger no automatic retries or scope expansion. If only Homebrew review remains, retain the qualified published artifacts and stop testing while awaiting actionable feedback.

See the [acceptance contract](../reference/release-promotion.md).
