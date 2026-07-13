---
name: Engineering task
about: Track a scoped Hostwright engineering task
title: ""
labels: ""
assignees: ""
---

## Outcome And User Workflows

What must a user or operator be able to do when this closes?

## Current Evidence And Gaps

What exists today, what is partial/research-only, and what proof is missing?

## Child Implementation Issues

List linked slices, or `None` for an atomic workstream. Work sequenced elsewhere must link its owning issue; do not hide product limitations as non-goals.

## Public Contracts And Migrations

List API, manifest, provider, state, plugin, compatibility, and migration effects.

## Dependencies And Sequencing

List prerequisite issues and parallel-safe work.

## Threat And Failure Model

List trust boundaries, abuse cases, expected faults, and fail-closed behavior.

## Verification Evidence

Required evidence classes:

- [ ] `unit-contract`
- [ ] `local-integration`
- [ ] `live-runtime`
- [ ] `hardware-benchmark`
- [ ] `distribution-artifact`
- [ ] `migration-upgrade`
- [ ] `security-assessment`
- [ ] `resilience-chaos`
- [ ] `multi-host`
- [ ] `interop-conformance`
- [ ] `ux-accessibility`

Keep only the classes this issue requires. The final evidence comment must name every retained class with its result or artifact.

Required normal, boundary, failure, recovery, migration, performance, compatibility, and exact-cleanup cases:

## Recovery And Rollback

Describe checkpoints, compensation, operator recovery, and rollback.

## Documentation Changes

List reference docs, compatibility matrix, examples, migration guides, release notes, and website work.

## Strict Closure Rules

- [ ] User-visible behavior is implemented and runnable; a model, mock, document, or blocked report is insufficient.
- [ ] Existing behavior and every changed normal, boundary, failure, recovery, migration, and cleanup path pass.
- [ ] Required evidence is from a clean exact commit with no blockers, skips, fixture-only substitution, or cleanup failure.
- [ ] Public claims match the exact tested platform/version scope.
- [ ] The final evidence comment includes `<!-- hostwright-evidence-gate:v1 -->` and all required environment and raw-result fields.
- [ ] Intermediate PRs use `Refs`; only the final `status:verification` PR uses `Closes`.

## Acceptance criteria

- [ ] Tests cover changed behavior.
- [ ] Docs are updated if public behavior changes.
- [ ] Runtime mutation, if any, goes through `RuntimeAdapter`.
- [ ] Destructive behavior, if any, has dry-run and confirmation design.
- [ ] Unsupported behavior remains explicit, has an owning roadmap destination or documented technical constraint, and no public support claim was added without implementation.
- [ ] Security/governance review triggers are listed when risky areas are touched.

## Verification

Commands to run:

```bash
swift build
swift test list || swift test --list-tests
swift test
scripts/grep-orchard.sh .
scripts/test.sh
scripts/lint.sh
```
