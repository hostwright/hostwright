# GA readiness snapshot — October 8, 2026

The source prepares **0.0.2-rc.7**. Freeze its exact merged source only after
[the executable ACL correction](https://github.com/hostwright/hostwright/pull/372)
is merged and required checks pass. RC.6 exposed that correction during independent
source review, so its results cannot qualify RC.7 or GA. No supported RC or GA
has been published.

The earlier October 10–12 engineering estimate assumed no further product
correction. That condition no longer holds. Reassess the product date after the
corrected candidate passes source, sanitizer and staging checks and the attended
lab is available. The requested combined GA and official Homebrew launch date
remains unconfirmed: Homebrew maintainers control acceptance, and latest-major
macOS qualification and adoption requirements remain open.

## Retained RC.6 results

RC.6 remains frozen at `e8bc8a3dfa9f1f8d9caf6cab82d0712dd8cdc68d` with version
`0.0.2-rc.6`. The following observations describe those exact bytes, not RC.7:

- The full source base passed 3,527 cases, with ten attended cases skipped. Four
  separate source supplements passed; six attended cases remain unqualified.
- The ASan base executed and passed 3,527 cases with ten explicitly routed cases.
  [PR #371](https://github.com/hostwright/hostwright/pull/371) corrected the collector's
  handling of the filtered XCTest header. The original receipt and logs remain
  preserved alongside the derived accounting. Four ASan supplements passed;
  complete ASan coverage and a fresh TSan suite remain outstanding.
- All six fuzz targets passed at least 301 seconds each, including retained-corpus
  replays. All 12,136 recorded raw attachment hashes were verified.
- The [runtime producer](https://github.com/hostwright/hostwright/actions/runs/37795746430)
  completed and its exact authenticated archive was verified locally.
- The [hosted qualification run](https://github.com/hostwright/hostwright/actions/runs/37795756601)
  passed 54 distribution and 37 release tests. Its live job skipped all six cases.
- The [first trusted stage](https://github.com/hostwright/hostwright/actions/runs/37826192731)
  failed its host-trust preflight because the default keychain was locked. It
  produced no signed candidate or publication.
- Independent source review found a pre-existing allow ACL could bypass the Unix
  owner/mode checks for external tools and credential helpers. The correction
  reuses the existing ACL policy and passes 38 focused tests. Final candidate
  and artifact review remain required; no root escalation was established.

Historical scanner observations include sixteen redacted secret-pattern contexts
and thirteen dependency advisory groups. The reviewed contexts did not establish
credential exposure. Dependency call analysis does not replace assessment of the
actual shipped artifacts. Retain original findings, corrections and failed runs.

## Remaining closure work

Eight required Phase 15 child issues remain open, plus the phase and master gates.
No issue is closed by preparation or partial qualification.

| Work | Required completion |
| --- | --- |
| Compatibility/current-source qualification, #271 | Freeze the corrected candidate; complete source identity coverage, both sanitizer suites, six five-minute fuzz targets, attended cells, provider conformance and ten cycles for each declared provider/version. |
| Security/supply chain, #272 and #275 | Verify the ACL correction in the candidate; assess dependency findings and historical object variance; verify final SBOM/source/signatures/provenance and obtain independent artifact review. |
| Recovery/upgrade lineage, #277 and #278 | Complete state/data backup and interruption recovery plus all twelve signed VM operations, including baseline upgrades, rollback, re-upgrade, repair and uninstall. |
| Public education, #279 | Execute CLI, Compose and desktop quickstarts against the artifacts; bind six website checks to a clean website commit and synchronize published claims. |
| Signed release, #281 | Qualify a complete RC, qualify final-version artifacts, assemble/accept eighteen gates, publish through protected promotion, and verify public bytes and vendor-tap installation. |
| Official Homebrew, #282 | Qualify the signed package cask, including latest-major macOS; satisfy submission requirements, obtain official acceptance and verify a fresh no-tap `brew install hostwright`. |
| Phase/master, #283 and #284 | Close after required children and publication verification are complete. |

The eighteen gate keys and fields are authoritative in
[staged-release.py](../../scripts/release/staged-release.py) and
[accept-qualification.py](../../scripts/release/accept-qualification.py). The
[promotion contract](../reference/release-promotion.md) specifies artifact bindings,
attachments, VM/recovery operations and cleanup evidence. The
[Homebrew guide](../reference/homebrew-distribution.md) documents the additional
official-channel launch requirement.

## Critical path

1. Merge the reviewed ACL correction and candidate version change, then freeze the
   exact clean source. Verify keychain access before the next protected stage.
2. Run fresh source, sanitizer, fuzz and authenticated runtime production for that
   source. Retain previous corpora as inputs only; do not relabel prior results.
3. Qualify signed bytes through provider, desktop, Compose, recovery, VM lifecycle,
   thirty-minute soak, security and independent-review gates.
4. After a complete RC, qualify the final `0.0.2` source and artifacts, obtain
   protected acceptance, promote those bytes and verify public installation.
5. Complete official Homebrew acceptance and the no-tap installation check before
   claiming the combined launch goal is met.

The lab runs one heavy Swift process at a time. Keychain/privileged access,
attended permission and VM operations, macOS 27 availability and upstream
Homebrew acceptance are unresolved dependencies. Keep the original developer
checkout and release evidence; remove disposable task build caches and archive
completed managed worktrees once no active qualification depends on them.
