# ADR 0015: Reduce v0.0.2 to local CLI, desktop, and Compose import

Status: accepted by the maintainer on 2026-09-07; implementation and release qualification remain pending.

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
`scopeDecision`. The 50 deferred issues may close only as `not_planned`, with a
scope-decision link, and after their children have the same recorded disposition
and closure reason. Required issues still close through clean final evidence.
A deferred issue never counts as completed implementation. The 105 previously
closed issues retain their evidence; 28 open issues remain required for release.

Retained workstreams receive explicit acceptance criteria and evidence classes in
the manifest. GitHub bodies and the generated index mirror that authority. Scope
changes must merge before issue closure so the default-branch governance workflow
can enforce the decision. The old July daily schedule is historical; current
delivery follows scope reset, Phase 10, Phase 13, Phase 14, then Phase 15.

## Qualification

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
