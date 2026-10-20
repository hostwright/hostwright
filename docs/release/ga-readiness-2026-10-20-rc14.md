# GA readiness — RC.14 preparation, October 20, 2026

Current source prepares `0.0.2-rc.14`. No supported RC or GA has been
published. Official `brew install hostwright` remains unavailable until stable
signed artifacts, upstream cask acceptance and fresh-machine installation pass.

## Completed work

Issue [#275](https://github.com/hostwright/hostwright/issues/275) is closed through
reviewed [PR #413](https://github.com/hostwright/hostwright/pull/413) and its
[final evidence record](https://github.com/hostwright/hostwright/issues/275#issuecomment-6295663012).
The [RC.13 supply-chain record](../evidence/phase15-rc13-c0f63020/supply-chain.md)
retains its exact source, artifact hashes, advisory dates and limitations.

[PR #414](https://github.com/hostwright/hostwright/pull/414) fixes a managed
daemon that repeatedly re-executed before opening its authenticated socket.
Foundation adds `__CF_USER_TEXT_ENCODING` before Swift starts; the corrected
exact environment pins that value to the real user's UID. Unexpected entries
and changed encoding values still require sanitation.

Validation passed 256 daemon tests, lint, documentation checks and three rebuilt
managed-entry cases. The exact reviewed commit passed CI, including native
CodeQL. A private Developer ID signed build then passed supported pending-upgrade
repair, managed startup, two authenticated integrity reports with all nine checks
healthy at state schema 24, and supported service stop/uninstall in the task VM.
The installed RC.13 payload remains unchanged. This development regression does
not qualify a new signed release artifact or complete a provider/lifecycle gate.

## Candidate binding

RC.14 needs a clean reviewed source freeze, its own exact-source runtime
producer, signed staging and required source/artifact qualification. The
[retained RC.13 record](ga-readiness-2026-10-20.md) remains bound to
`c0f63020f1c4187623d48d9c0770679b8b0de0d1` and its original version and bytes.
Its successful source, sanitizer, fuzz and staging checks do not establish
RC.14 acceptance. Raw failures and later recovery results remain separate.

## Eight remaining issues

| Issue | Required result |
| --- | --- |
| [#271](https://github.com/hostwright/hostwright/issues/271) | Physical/VM compatibility, provider conformance, ten lifecycle cycles per provider and a checkpointed 30-minute physical-host soak. |
| [#277](https://github.com/hostwright/hostwright/issues/277) | Actual backup/restore, interruption recovery, cancellation and owned-resource cleanup. |
| [#278](https://github.com/hostwright/hostwright/issues/278) | Signed dev.11/dev.12 upgrade, rollback, interruption, downgrade refusal, repair and uninstall routes. |
| [#279](https://github.com/hostwright/hostwright/issues/279) | Executed CLI, Compose and desktop quickstarts, accessibility checks and synchronized README/website. |
| [#281](https://github.com/hostwright/hostwright/issues/281) | Complete accepted RC, independent signed-artifact lifecycle review, final-version qualification, stable publication and verified vendor-tap installation. |
| [#282](https://github.com/hostwright/hostwright/issues/282) | Stable signed-package cask audits, official Homebrew acceptance and fresh-machine no-tap installation. |
| [#283](https://github.com/hostwright/hostwright/issues/283) | All required Phase 15 children and publication checks. |
| [#284](https://github.com/hostwright/hostwright/issues/284) | All required release children and final publication checks. |

Homebrew acceptance is an external maintainer review. No acceptance date is
promised. The [release process](RELEASE_PROCESS.md) defines the remaining order.
