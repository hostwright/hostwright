# Hostwright v0.0.2 release process

The active target is signed downloads and `brew install hostwright/tap/hostwright`.
Official Homebrew acceptance is deferred under [ADR 0017](../design/adr-0017-focused-v002-qualification.md).
The [issue manifest](../roadmap/v0.0.2/issues.json) records release dispositions.

## Prepare and verify

1. Preserve unique local work and use one clean reviewed source commit on main.
2. Resolve demonstrated product defects with targeted regressions. Run the complete
   existing suite once in trusted staging; reuse its output rather than rerun it.
3. Build signed/notarized final-version archive/package artifacts through the
   reviewed workflow. Verify runtime provenance and corresponding source; reuse
   native ingredients only through authenticated supported checkpoints.
4. Complete the five [focused qualification groups](../design/adr-0017-focused-v002-qualification.md):
   source, artifact integrity, installation, working product and documentation.
   One lifecycle per declared provider is sufficient. No separate timed soak,
   full sanitizer/fuzz campaign or agent-review receipt is required.
5. Retain raw results, actual source/version/environment, exact inventory bindings
   and verified owned-resource cleanup. Failures and skipped work are not passes.

## Accept and publish

Use [staged promotion](../reference/release-promotion.md) to retain the evidence,
obtain protected acceptance and promote the exact accepted bytes without rebuilding.
Verify public downloads against staging, publish the matching vendor-tap formula
and exercise installation/upgrade from that public channel.

Close #271 after provider compatibility checks, #277 after state/workload recovery,
#279 after signed quickstarts and documentation, and #281 after publication verification.
Close deferred #282 as not planned. Close #283 and #284 after their required children.
Required closures retain the existing `<!-- hostwright-evidence-gate:v1 -->` record
and `status:verification`; deferrals reference the merged scope decision.

## Artifact policy

Retain signed/notarized archives and package, checksums, SPDX SBOMs, provenance,
corresponding source, verification metadata and digest-bound vendor formula.
Published releases and evidence are immutable. Protected staging retention is
90 days; retain the final release's necessary source/evidence permanently.
Never advertise fresh-machine `brew install hostwright` as an official channel.

## Immutable Historical Releases

`docs/release/IMMUTABLE_RELEASES.json` records the hashes of historical release notes. Preserve their original bytes. Current references can explain their status; Git history retains superseded planning and development narratives.
