# ADR 0015: Reduce v0.0.2 to local CLI, desktop, and Compose import

Status: accepted by the maintainer on 2026-09-07; Phase 14 acceptance amended on 2026-10-05; official Homebrew distribution requested on 2026-10-08. Final release qualification remains pending.

## Decision

Ship the single-Mac CLI, deterministic local resource admission, a native desktop
console with confirmed up/down/restart, and the existing narrow Compose conversion
workflow. Keep Manifest v3, Control API 2.2, and SQLite schema v24. Desktop mutations
use the authenticated Control API and the same plan confirmation, authorization,
fencing, and lifecycle coordinator as the CLI.

The available lab is one physical M4 Pro Mac and one macOS VM. Live runtime evidence
comes from the physical host; the VM supplies clean installation and recovery
evidence. Neither establishes independent hardware or multi-Mac availability.

Defer cross-project fairness guarantees, topology optimization, automatic
preemption, VM reclamation, accelerators, multi-Mac operations, Kubernetes,
Docker-client compatibility, IDE integrations, team/MDM/cloud services, automatic
desktop updates, and Homebrew-core submission. Preserve development code and tests;
unsupported requests must fail before effects and deferred tools are excluded from
supported release packaging.

## Issue authority

Preserve all 183 identities and historical evidence. The issue manifest records
`releaseDisposition` as `required` or `deferred`, with this document as its
`scopeDecision`. Originally 50 issues were deferred; the October 8 amendment
returns #282 to required work, leaving 49 deferred. Deferred issues may close only as `not_planned`, with a
scope-decision link, and after their children have the same recorded disposition
and closure reason. Required issues still close through clean final evidence.
A deferred issue never counts as completed implementation. The 105 previously
closed issues retain their evidence; the original scope decision retained 28 of
the then-open issues. The October 8 amendment adds one required workstream.

Retained workstreams receive explicit acceptance criteria and evidence classes in
the manifest. GitHub bodies and the generated index mirror that authority. Scope
changes must merge before issue closure so the default-branch governance workflow
can enforce the decision. The old July daily schedule is historical; current
delivery follows scope reset, Phase 10, Phase 13, Phase 14, then Phase 15.

## Qualification

### Official Homebrew availability (2026-10-08)

The maintainer requested `brew install hostwright` on a fresh Homebrew installation
alongside GA. Return #282 to required Phase 15 work as official Homebrew cask
distribution of the signed native app and CLI package. The core source-build
formula remains a separate deferred approach. Preserve the original issue identity
and its historical not-planned closure; the new local ledger records the requested
reopening and must be synchronized with GitHub through the reviewed scope change.

Generate the cask only from a trusted, verified package, qualify its real install,
launch, upgrade and preserve-data uninstall, then submit it using immutable public
release bytes. Official repository acceptance and a fresh-machine short-name
installation are required before closing #282 or announcing the requested
Homebrew-available GA launch. A vendor tap or local trust setting does not satisfy
that result. Homebrew decides eligibility and acceptance; no acceptance date is
promised. Track its current platform and public-interest requirements explicitly.

Continue all existing product qualification while this work proceeds. The signed
stable artifact must be published before Homebrew can audit its public download;
this dependency does not permit announcing that the complete Homebrew launch gate
has passed early. Keep #282 and the release parents open until the official
channel is verified, or the maintainer explicitly changes the launch requirement.

See [Homebrew distribution](../reference/homebrew-distribution.md) for the generator,
test procedure and current external prerequisites.

### Phase 14 implementation acceptance (2026-10-05)

The maintainer reduced Phase 14 to the implemented local desktop and signed RC
packaging boundary. Close #258 and #262 with the authenticated rc.2 runtime,
successful signed/notarized two-build stage, current-source regression and
ownership contracts, and retained physical desktop/accessibility observations.
Retain each result's original source and artifact binding. Unchanged desktop,
authentication and lifecycle observation inputs permit reuse of the ten physical
cycles (40 actions) and 15 GUI checks recorded on `994cf93c`; source comparison
is support for reuse, not a claim that rc.2 ran those device checks.

The incomplete clean-VM upgrade, rollback, re-upgrade, repair and uninstall matrix
is transferred to #278 under Phase 15 (#283). It remains a prerequisite for final
v0.0.2 promotion. Historical VM successes and failures remain recorded; no failed,
unfinished or unexecuted case becomes a pass through this scope decision. The
compensation/recovery repair in #363 has current regression coverage, but its
signed VM reproduction remains unqualified. Phase 14 closure authorizes no GA
release, tag publication or statement that the entire release gate passed.

The rc.2 trusted stage passed and all nine executable hashes matched between
the retained builds. One intermediate `SystemPackage` object differed; retain
that diagnostic under Phase 15 #275 rather than claim all-object reproducibility.

This amendment changes the Phase 14 acceptance boundary only. Preserve the
existing evidence gate and all final-release security and qualification checks.

### Final release qualification

Run ten live lifecycle cycles per supported provider and a checkpointed 30-minute
single-host soak; replay retained corpora and fuzz each shipped critical parser or
protocol for five minutes. Preserve supported sanitizer, security, dependency,
license, recovery, ownership, documentation, and signed-distribution checks.
One clean RC qualification plus independent signed-artifact install, reboot,
upgrade, rollback, repair, and uninstall verification replaces the two-RC and
multi-day requirements. Qualify final-version artifacts before promotion.

## Alternatives and tests

The former all-in release requires unavailable physical lab capacity and substantial
unshipped products. Merely shortening its tests would leave its claims unsupported.
Deleting or replacing every issue would lose useful traceability. Explicit scoped
deferrals preserve both a deliverable release and the original work history.

Test required/deferred closure decisions, missing decision links, mismatched closure
reasons, open/deferred child handling, and unchanged dirty/missing-evidence refusal.
Verify the local lifecycle, Compose conversion-to-execution, desktop confirmation
and disconnect paths, and release artifact lifecycle on their actual environments.
