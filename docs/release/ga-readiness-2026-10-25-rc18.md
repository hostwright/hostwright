# GA readiness — RC.18 preparation, October 25, 2026

Current source prepares `0.0.2-rc.18`. No supported RC or GA has been published.
Manifest v3, Control API 2.2, state schema v24 and the single-Mac CLI, desktop and narrow Compose scope remain unchanged.

## Repairs landed

[PR #418](https://github.com/hostwright/hostwright/pull/418) repaired ownership-safe port-reservation handoff and rollback. [PR #419](https://github.com/hostwright/hostwright/pull/419) repaired the SQLite symlink qualification fixture with atomic exchanges and added deterministic missing-database validation coverage. Its ten hardening cases passed normally and under ThreadSanitizer; current-head regression, build, documentation and security checks passed before merge. Production SQLite code was unchanged. The earlier `EEXIST` path creator remains unconfirmed.

[Website PR #32](https://github.com/hostwright/hostwright.dev/pull/32) merged the readiness copy and two audited dependency patches. Both packages passed check, build, links and high-severity audit; merged-main deployment and five public pages were verified. Zero high or critical findings were reported; lower-severity findings remain. Signed CLI, Compose and desktop quickstarts remain required.

The [RC.17 record](ga-readiness-2026-10-24-rc17.md) and its failed full ThreadSanitizer result retain their original source bindings. Focused repair checks do not qualify RC.18 or either full sanitizer suite.

## Fixed closing sequence

1. Merge this version/readiness change after review and current-head checks, then freeze the exact clean merged source. Start no qualification on a moving candidate.
2. Run each missing required source and artifact gate once against that candidate. Preserve reusable input evidence under its existing bindings; source/version/artifact-bound results require exact qualification. Overlap independent hosted work with local work and run only one heavy Swift process on the physical Mac.
3. Obtain protected RC acceptance only after all eighteen gates pass, including full source regression, both full sanitizers, parser fuzzing, security/source/license checks, declared provider conformance and ten cycles per lane, the thirty-minute soak, all eight recovery and twelve signed VM lifecycle operations, quickstarts, accessibility and independent review.
4. After RC acceptance, make one reviewed final `0.0.2` version change, qualify the final signed bytes once, accept and promote those exact bytes, and verify public downloads and the vendor tap before closing #281.
5. Submit and qualify the official Homebrew cask against the stable public bytes. Keep #282, #283 and #284 open until official acceptance and fresh-machine `brew install hostwright` succeed.

No additional product repair round is authorized. A blocking qualification failure ends this attempt with its exact evidence retained. Stop at 11:59 p.m. Eastern on October 25 with completed GA or a precise unfinished-gate report. Do not start work that cannot finish and clean up before that cutoff. Missing credentials, lab capacity, signing, publication authority or Homebrew acceptance remain explicit blockers and trigger no automatic retesting or scope expansion.

See the [acceptance contract](../reference/release-promotion.md).
